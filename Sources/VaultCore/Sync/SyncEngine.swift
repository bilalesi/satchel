import Foundation

public struct SyncReport: Sendable, Equatable {
    public var pulled = 0
    public var pushed = 0
    public var conflicts = 0
    public var generation: UInt64 = 0
    public init() {}
}

/// Counts what moved, across retried rounds.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SyncReport()
    var snapshot: SyncReport { lock.withLock { value } }
    func bump(_ change: (inout SyncReport) -> Void) { lock.withLock { change(&value) } }
}

/// Sync state shared by the rounds of one `sync()` call. A round that fails after pulling an item
/// has already written the file; without its etag record the next round would treat identical
/// bytes as a change on both sides and fabricate a merge (opaque etags cannot prove equality).
private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SyncState?
    var state: SyncState? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

/// The §7.3 algorithm. Optimistic concurrency: every remote write carries the etag it
/// expects; a mismatch restarts the round (max 3). Items first, manifest last, so a
/// crash between the two is repaired by the next round.
///
/// A round only talks to the remote and writes pulled items; the local manifest and sync
/// state are committed by `run` after the remote accepted everything. With a batching
/// backend (Git) that means after the push, so a rejected push never leaves this Mac
/// believing it is ahead of the remote.
public final class SyncEngine: Sendable {
    public static let maxRounds = 3

    private let store: VaultStore
    private let remote: RemoteStore
    private let filter: SyncFilter

    public init(store: VaultStore, remote: RemoteStore, filter: SyncFilter = SyncEverything()) {
        self.store = store
        self.remote = remote
        self.filter = filter
    }

    public func sync() async throws -> SyncReport {
        guard store.isUnlocked else { throw VaultError.locked }
        let tally = Tally() // accumulates over rounds: a retry only moves what is still missing
        let box = StateBox()
        var last: Error = SyncError.conflict(RemotePaths.manifest)
        do {
            for _ in 0..<Self.maxRounds {
                do { return try await run(tally, box) } catch let e as SyncError {
                    guard case .conflict = e else { throw e }
                    last = e
                }
            }
            throw last
        } catch {
            // Keep the etag records of what this call already moved (see StateBox).
            if let state = box.state { try? store.saveSyncState(state) }
            throw error
        }
    }

    private struct Outcome: Sendable {
        var report: SyncReport
        var manifest: Manifest // what this device stores (remote view plus local-only items)
        var state: SyncState
    }

    private func run(_ tally: Tally, _ box: StateBox) async throws -> SyncReport {
        let outcome: Outcome
        if let batching = remote as? BatchingRemoteStore {
            outcome = try await batching.withBatch { try await self.round(tally, box) }
        } else {
            outcome = try await round(tally, box)
        }
        try store.replaceManifest(outcome.manifest)
        try store.saveSyncState(outcome.state)
        return outcome.report
    }

    // MARK: One round

    private func round(_ tally: Tally, _ box: StateBox) async throws -> Outcome {
        let prior = tally.snapshot
        var state = try box.state ?? store.loadSyncState()
        defer { box.state = state }
        if state.filterFingerprint != filter.fingerprint {
            state.skipped = [:] // the selection changed: look at skipped items again
            state.filterFingerprint = filter.fingerprint
        }
        let localManifest = store.manifest

        guard let remoteManifestObj = try await remote.get(RemotePaths.manifest) else {
            // A remote that synced before and now has no manifest was wiped, rolled back or is hiding
            // it. Re-uploading from here would overwrite newer objects, so stop instead. Starting over
            // on purpose means switching sync off and on (that resets this state).
            if state.lastGeneration > 0 { throw VaultError.rollbackDetected(local: state.lastGeneration, remote: 0) }
            return try await initialPush(tally: tally, state: state)
        }
        let remoteManifest = try store.decodeRemoteManifest(remoteManifestObj.data)
        try remoteManifest.checkNotRolledBack(against: state.lastGeneration)

        // Header: fetched only when the remote manifest says it differs (saves a request).
        var headerPush: (Data, String?)?
        let localHeader = try store.headerData()
        if remoteManifest.headerHash != ManifestFile.sha256(localHeader) {
            guard let rh = try await remote.get(RemotePaths.header) else { throw SyncError.notFound(RemotePaths.header) }
            guard ManifestFile.sha256(rh.data) == remoteManifest.headerHash else { throw VaultError.corruptHeader }
            let remoteHeader = try VaultHeader.decode(rh.data)
            if remoteHeader.updatedAt > store.header.updatedAt {
                try store.applyRemoteHeader(rh.data)
            } else {
                headerPush = (localHeader, rh.etag)
            }
        }

        // Items: one list call, then only what differs moves.
        let remoteList = try await remote.list(prefix: RemotePaths.itemsPrefix)
        var merged: [String: UInt64] = [:]     // the remote's view after this round
        var localOnly: [String: UInt64] = [:]  // excluded here: kept in the local manifest only
        let ids = Set(localManifest.itemIDs).union(remoteManifest.itemIDs).union(try store.itemIDsOnDisk())
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let key = id.uuidString
            let path = RemotePaths.item(id)
            let rawLocal = try store.itemData(id)
            // A local file that cannot be read as an item is junk (a hostile remote can plant one
            // through the first download). It never blocks a sync: the remote copy replaces it,
            // or it is ignored when there is none.
            let local = rawLocal.flatMap { raw in (try? store.overview(of: raw)).map { (data: raw, header: $0.header, overview: $0.overview) } }
            // The file is the truth for the local version: a crash may have left a newer file than
            // the manifest says, and a file older than the manifest is a rollback that must be
            // pulled over, never pushed.
            let lv = local?.header.version ?? 0
            let rv = remoteManifest.version(of: id) ?? 0
            let remoteEtag = remoteList[path]

            guard let localData = local?.data else {
                // Nothing local. If the remote has it, selective sync decides whether to store it.
                if rv > 0 {
                    if state.skipped[key] == rv { merged[key] = rv; continue }
                    let obj = try await fetchItem(id, path: path, expectedVersion: rv)
                    if !filter.includes(try store.overview(of: obj.data).overview) {
                        state.skipped[key] = rv
                        merged[key] = rv
                        continue
                    }
                    try store.writeRawItem(obj.data, ifCurrentIs: rawLocal)
                    state.record(path: path, etag: obj.etag, data: obj.data)
                    tally.bump { $0.pulled += 1 }
                    merged[key] = rv
                }
                // else: neither side has a readable copy. Never advertise it in the remote manifest:
                // every other device would fail with "missing" on it.
                continue
            }

            // Local copy exists. Excluded items stay on this Mac, except the deletion of
            // something already on the remote, which always propagates.
            let localHeaderInfo = local!.header, localOverview = local!.overview
            if !(localHeaderInfo.deleted && rv > 0) && !filter.includes(localOverview) {
                localOnly[key] = lv
                if rv > 0 { merged[key] = rv }
                continue
            }

            let localSha = GitBlob.sha(localData)
            let sameBytes = state.isSame(path: path, remoteEtag: remoteEtag, localSha: localSha)
            let base = state.baseVersion(of: id)

            if lv > base && rv > base && !sameBytes {
                // Changed on both sides: merge, keep every value, push the result.
                let remoteObj = try await fetchItem(id, path: path, expectedVersion: rv)
                let mergedData = try store.mergeConflict(local: localData, remote: remoteObj.data)
                try store.writeRawItem(mergedData, ifCurrentIs: localData)
                let etag = try await remote.put(path, data: mergedData, ifMatch: remoteEtag)
                state.record(path: path, etag: etag, data: mergedData)
                merged[key] = try ItemFile.decodeHeader(mergedData).version
                tally.bump { $0.conflicts += 1 }
                tally.bump { $0.pushed += 1 }
            } else if rv > lv {
                // The remote manifest promises a newer version. Serving our own bytes for it means
                // the remote is inconsistent (or withholding an update): never record a version we do not hold.
                guard !sameBytes else { throw VaultError.corruptItemData }
                let obj = try await fetchItem(id, path: path, expectedVersion: rv)
                try store.writeRawItem(obj.data, ifCurrentIs: localData)
                state.record(path: path, etag: obj.etag, data: obj.data)
                tally.bump { $0.pulled += 1 }
                merged[key] = rv
            } else {
                if !sameBytes {
                    let etag = try await remote.put(path, data: localData, ifMatch: remoteEtag)
                    state.record(path: path, etag: etag, data: localData)
                    tally.bump { $0.pushed += 1 }
                }
                merged[key] = lv
            }
        }

        if let (data, etag) = headerPush {
            _ = try await remote.put(RemotePaths.header, data: data, ifMatch: etag)
        }

        let currentHeaderHash = ManifestFile.sha256(try store.headerData())

        // Nothing moved in either direction and the remote manifest already describes exactly
        // this state: do not write it again. Reason: every manifest write is a commit/object
        // version on the remote; the 15-minute timer alone would add ~96 a day for no change.
        let unchanged = tally.snapshot == prior
            && headerPush == nil
            && merged == remoteManifest.versions
            && remoteManifest.headerHash == currentHeaderHash
        let remoteNext: Manifest
        if unchanged {
            remoteNext = Manifest(generation: remoteManifest.generation, deviceID: localManifest.deviceID,
                                  headerHash: currentHeaderHash, versions: merged)
        } else {
            remoteNext = Manifest(generation: max(localManifest.generation, remoteManifest.generation) + 1,
                                  deviceID: localManifest.deviceID, headerHash: currentHeaderHash, versions: merged)
            _ = try await remote.put(RemotePaths.manifest, data: try store.encodeManifest(remoteNext),
                                     ifMatch: remoteManifestObj.etag)
        }
        // This device additionally remembers the items it keeps to itself; the remote never sees them.
        let localNext = Manifest(generation: remoteNext.generation, deviceID: localManifest.deviceID,
                                 headerHash: currentHeaderHash,
                                 versions: merged.merging(localOnly) { _, local in local })

        state.lastGeneration = remoteNext.generation
        state.synced = merged
        state.lastSyncAt = Date()
        tally.bump { $0.generation = remoteNext.generation }
        return Outcome(report: tally.snapshot, manifest: localNext, state: state)
    }

    /// Remote has no manifest: upload everything this device syncs. Existing partial objects (a
    /// crashed first push) are overwritten using their current etags.
    private func initialPush(tally: Tally, state priorState: SyncState) async throws -> Outcome {
        var state = priorState
        let headerData = try store.headerData()
        let existingHeader = try await remote.get(RemotePaths.header)
        if existingHeader?.etag != GitBlob.sha(headerData) || existingHeader.map({ $0.data != headerData }) ?? true {
            let etag = try await remote.put(RemotePaths.header, data: headerData, ifMatch: existingHeader?.etag)
            state.record(path: RemotePaths.header, etag: etag, data: headerData)
        }
        let remoteList = try await remote.list(prefix: RemotePaths.itemsPrefix)
        var versions: [String: UInt64] = [:]
        var localOnly: [String: UInt64] = [:]
        for id in try store.itemIDsOnDisk() {
            guard let data = try store.itemData(id) else { continue }
            let path = RemotePaths.item(id)
            guard let (header, overview) = try? store.overview(of: data) else { continue } // junk: never uploaded
            if !filter.includes(overview) {
                localOnly[id.uuidString] = header.version
                continue
            }
            if !state.isSame(path: path, remoteEtag: remoteList[path], localSha: GitBlob.sha(data)) {
                let etag = try await remote.put(path, data: data, ifMatch: remoteList[path])
                state.record(path: path, etag: etag, data: data)
                tally.bump { $0.pushed += 1 }
            }
            versions[id.uuidString] = header.version
        }
        let generation = store.manifest.generation + 1
        let remoteManifest = Manifest(generation: generation, deviceID: store.manifest.deviceID,
                                      headerHash: ManifestFile.sha256(headerData), versions: versions)
        _ = try await remote.put(RemotePaths.manifest, data: try store.encodeManifest(remoteManifest), ifMatch: nil)
        let localManifest = Manifest(generation: generation, deviceID: store.manifest.deviceID,
                                     headerHash: remoteManifest.headerHash,
                                     versions: versions.merging(localOnly) { _, local in local })

        state.lastGeneration = generation
        state.synced = versions
        state.lastSyncAt = Date()
        tally.bump { $0.generation = generation }
        return Outcome(report: tally.snapshot, manifest: localManifest, state: state)
    }

    private func fetchItem(_ id: UUID, path: String, expectedVersion: UInt64) async throws -> RemoteObject {
        guard let obj = try await remote.get(path) else { throw SyncError.notFound(path) }
        let header = try store.verifyRemoteItem(obj.data, expectedVersion: expectedVersion)
        guard header.id == id else { throw VaultError.corruptItemData }
        return obj
    }

    // MARK: Second device

    private struct Download: Sendable {
        var header: RemoteObject
        var manifest: RemoteObject
        var items: [(UUID, String, RemoteObject)]
    }

    private static func downloadAll(_ remote: RemoteStore) async throws -> Download {
        guard let header = try await remote.get(RemotePaths.header) else { throw SyncError.notFound(RemotePaths.header) }
        guard let manifest = try await remote.get(RemotePaths.manifest) else { throw SyncError.notFound(RemotePaths.manifest) }
        var items: [(UUID, String, RemoteObject)] = []
        for (path, _) in try await remote.list(prefix: RemotePaths.itemsPrefix) {
            guard let id = RemotePaths.itemID(fromPath: path), let obj = try await remote.get(path) else { continue }
            items.append((id, path, obj))
        }
        return Download(header: header, manifest: manifest, items: items)
    }

    /// Downloads a remote vault into `url` and unlocks it. On any failure nothing is left behind.
    public static func bootstrap(remote: RemoteStore, into url: URL, password: SecureBytes,
                                 deviceID: UUID = DeviceID.current) async throws -> VaultStore {
        guard !VaultStore.exists(at: url) else { throw VaultError.io("A vault already exists at \(url.path)") }
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).bootstrap-\(UUID().uuidString)", isDirectory: true)
        var state = SyncState()
        do {
            try fm.createDirectory(at: staging.appendingPathComponent("items", isDirectory: true),
                                   withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let download: Download
            if let batching = remote as? BatchingRemoteStore {
                download = try await batching.withBatch { try await downloadAll(remote) }
            } else {
                download = try await downloadAll(remote)
            }
            try AtomicFile.write(download.header.data, to: staging.appendingPathComponent(RemotePaths.header))
            try AtomicFile.write(download.manifest.data, to: staging.appendingPathComponent(RemotePaths.manifest))
            for (id, path, obj) in download.items {
                try AtomicFile.write(obj.data, to: staging.appendingPathComponent(RemotePaths.item(id)))
                state.record(path: path, etag: obj.etag, data: obj.data) // so the first sync does not re-upload everything
            }
            guard rename(staging.path, url.path) == 0 else { throw VaultError.io("rename: \(String(cString: strerror(errno)))") }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        do {
            let store = try VaultStore.open(at: url, deviceID: deviceID)
            try store.unlock(password: password) // verifies manifest MAC and header hash
            state.lastGeneration = store.manifest.generation
            state.synced = store.manifest.versions
            state.lastSyncAt = Date()
            try store.saveSyncState(state)
            return store
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }
}
