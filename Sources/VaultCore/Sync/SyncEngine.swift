import Foundation

public struct SyncReport: Sendable, Equatable {
    public var pulled = 0
    public var pushed = 0
    public var conflicts = 0
    public var generation: UInt64 = 0
    public init() {}
}

/// The §7.3 algorithm. Optimistic concurrency: every remote write carries the etag it
/// expects; a mismatch restarts the round (max 3). Items first, manifest last, so a
/// crash between the two is repaired by the next round (blob ids match, no re-upload).
public final class SyncEngine: Sendable {
    public static let maxRounds = 3

    private let store: VaultStore
    private let remote: RemoteStore

    public init(store: VaultStore, remote: RemoteStore) {
        self.store = store
        self.remote = remote
    }

    public func sync() async throws -> SyncReport {
        guard store.isUnlocked else { throw VaultError.locked }
        var report = SyncReport() // accumulates over rounds: a retry only moves what is still missing
        var last: Error = SyncError.conflict(RemotePaths.manifest)
        for _ in 0..<Self.maxRounds {
            do { try await round(&report); return report } catch let e as SyncError {
                guard case .conflict = e else { throw e }
                last = e
            }
        }
        throw last
    }

    // MARK: One round

    private func round(_ report: inout SyncReport) async throws {
        let state = store.syncState
        let localManifest = store.manifest

        guard let remoteManifestObj = try await remote.get(RemotePaths.manifest) else {
            try await initialPush(&report)
            return
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
        var merged: [String: UInt64] = [:]
        let ids = Set(localManifest.itemIDs).union(remoteManifest.itemIDs).union(try store.itemIDsOnDisk())
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let path = RemotePaths.item(id)
            let localData = try store.itemData(id)
            // Trust the file over the manifest: a crash may have left a newer file.
            let lv = max(localManifest.version(of: id) ?? 0, localData.flatMap { try? ItemFile.decodeHeader($0).version } ?? 0)
            let rv = remoteManifest.version(of: id) ?? 0
            let base = state.baseVersion(of: id)
            let localSha = localData.map(GitBlob.sha)
            let remoteEtag = remoteList[path]
            let sameBytes = localSha != nil && localSha == remoteEtag

            let bothChanged = lv > base && rv > base && !sameBytes
            if bothChanged, let localData {
                let remoteData = try await fetchItem(id, path: path)
                let mergedData = try store.mergeConflict(local: localData, remote: remoteData)
                try store.writeRawItem(mergedData)
                _ = try await remote.put(path, data: mergedData, ifMatch: remoteEtag)
                merged[id.uuidString] = try ItemFile.decodeHeader(mergedData).version
                report.conflicts += 1
                report.pushed += 1
            } else if rv > lv || (localData == nil && remoteEtag != nil) {
                if !sameBytes {
                    let remoteData = try await fetchItem(id, path: path)
                    try store.writeRawItem(remoteData)
                    report.pulled += 1
                }
                merged[id.uuidString] = max(rv, lv)
            } else if let localData {
                if !sameBytes {
                    _ = try await remote.put(path, data: localData, ifMatch: remoteEtag)
                    report.pushed += 1
                }
                merged[id.uuidString] = lv
            } else {
                // Listed in a manifest but present nowhere: nothing to move, keep the version.
                merged[id.uuidString] = max(lv, rv)
            }
        }

        if let (data, etag) = headerPush {
            _ = try await remote.put(RemotePaths.header, data: data, ifMatch: etag)
        }

        var next = Manifest(generation: max(localManifest.generation, remoteManifest.generation) + 1,
                            deviceID: localManifest.deviceID,
                            headerHash: ManifestFile.sha256(try store.headerData()),
                            versions: merged)
        next.deviceID = localManifest.deviceID
        _ = try await remote.put(RemotePaths.manifest, data: try store.encodeManifest(next), ifMatch: remoteManifestObj.etag)
        try store.replaceManifest(next)

        var newState = state
        newState.lastGeneration = next.generation
        newState.synced = merged
        newState.lastSyncAt = Date()
        try store.saveSyncState(newState)
        report.generation = next.generation
    }

    /// Remote has no manifest: upload everything. Existing partial objects (a crashed
    /// first push) are overwritten using their current etags.
    private func initialPush(_ report: inout SyncReport) async throws {
        let existingHeader = try await remote.get(RemotePaths.header)?.etag
        let headerData = try store.headerData()
        if existingHeader != GitBlob.sha(headerData) {
            _ = try await remote.put(RemotePaths.header, data: headerData, ifMatch: existingHeader)
        }
        let remoteList = try await remote.list(prefix: RemotePaths.itemsPrefix)
        var versions: [String: UInt64] = [:]
        for id in try store.itemIDsOnDisk() {
            guard let data = try store.itemData(id) else { continue }
            let path = RemotePaths.item(id)
            if remoteList[path] != GitBlob.sha(data) {
                _ = try await remote.put(path, data: data, ifMatch: remoteList[path])
                report.pushed += 1
            }
            versions[id.uuidString] = try ItemFile.decodeHeader(data).version
        }
        var manifest = store.manifest
        manifest.versions = versions
        manifest.headerHash = ManifestFile.sha256(headerData)
        manifest.generation += 1
        _ = try await remote.put(RemotePaths.manifest, data: try store.encodeManifest(manifest), ifMatch: nil)
        try store.replaceManifest(manifest)

        var state = SyncState()
        state.lastGeneration = manifest.generation
        state.synced = versions
        state.lastSyncAt = Date()
        try store.saveSyncState(state)
        report.generation = manifest.generation
    }

    private func fetchItem(_ id: UUID, path: String) async throws -> Data {
        guard let obj = try await remote.get(path) else { throw SyncError.notFound(path) }
        let header = try store.verifyRemoteItem(obj.data)
        guard header.id == id else { throw VaultError.corruptItemData }
        return obj.data
    }

    // MARK: Second device

    /// Downloads a remote vault into `url` and unlocks it. On any failure nothing is left behind.
    public static func bootstrap(remote: RemoteStore, into url: URL, password: SecureBytes,
                                 deviceID: UUID = DeviceID.current) async throws -> VaultStore {
        guard !VaultStore.exists(at: url) else { throw VaultError.io("A vault already exists at \(url.path)") }
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).bootstrap-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging.appendingPathComponent("items", isDirectory: true),
                                   withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let header = try await remote.get(RemotePaths.header) else { throw SyncError.notFound(RemotePaths.header) }
            guard let manifest = try await remote.get(RemotePaths.manifest) else { throw SyncError.notFound(RemotePaths.manifest) }
            try AtomicFile.write(header.data, to: staging.appendingPathComponent(RemotePaths.header))
            try AtomicFile.write(manifest.data, to: staging.appendingPathComponent(RemotePaths.manifest))
            for (path, _) in try await remote.list(prefix: RemotePaths.itemsPrefix) {
                guard let id = RemotePaths.itemID(fromPath: path) else { continue }
                guard let obj = try await remote.get(path) else { continue }
                try AtomicFile.write(obj.data, to: staging.appendingPathComponent(RemotePaths.item(id)))
            }
            guard rename(staging.path, url.path) == 0 else { throw VaultError.io("rename: \(String(cString: strerror(errno)))") }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        do {
            let store = try VaultStore.open(at: url, deviceID: deviceID)
            try store.unlock(password: password) // verifies manifest MAC and header hash
            var state = SyncState()
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
