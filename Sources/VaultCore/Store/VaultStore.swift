import Foundation

/// Repository over one vault directory:
/// ```
/// <url>/vault.vhdr          header (plaintext, no secrets)
/// <url>/manifest.vman       MAC'd versions + generation + header hash
/// <url>/items/<uuid>.vitem  one encrypted item per file
/// ```
/// Write order is always item file first, then manifest, each atomically. On load the
/// directory is the truth for content and the manifest is the truth for integrity:
/// a file newer than the manifest is crash recovery (accepted, manifest repaired);
/// a file older than the manifest is a rollback (reported as corrupt).
public final class VaultStore: @unchecked Sendable {
    public let url: URL
    public private(set) var header: VaultHeader
    public private(set) var manifest: Manifest
    private var keys: VaultKeys?
    private var vaultKey: SecureBytes?
    private let deviceID: UUID
    /// Serialises the UI (saves) and the sync engine (pulls/pushes) on the same files.
    /// Reason: both touch items + manifest; a recursive lock is the smallest thing that
    /// keeps each public operation atomic on disk. Held for milliseconds (no network inside).
    private let mutex = NSRecursiveLock()
    /// Device-bound Touch ID slot, stored in `touchid.slot`, never synced.
    private var touchIDSlot: KeySlot?

    public static let touchIDSlotFileName = "touchid.slot"
    public var itemsURL: URL { url.appendingPathComponent("items", isDirectory: true) }
    private var headerURL: URL { url.appendingPathComponent(VaultHeader.fileName) }
    private var manifestURL: URL { url.appendingPathComponent(Manifest.fileName) }
    private var touchIDSlotURL: URL { url.appendingPathComponent(Self.touchIDSlotFileName) }

    private init(url: URL, header: VaultHeader, manifest: Manifest, deviceID: UUID) {
        self.url = url
        self.header = header
        self.manifest = manifest
        self.deviceID = deviceID
        if let data = try? Data(contentsOf: touchIDSlotURL),
           let slot = try? JSONCoding.decoder.decode(KeySlot.self, from: data), slot.isSecureEnclave {
            touchIDSlot = slot
        }
    }

    // MARK: Lifecycle

    public static func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(VaultHeader.fileName).path)
    }

    public static func create(at url: URL, password: SecureBytes, kdfParams: KDFParams = .fresh(),
                              deviceID: UUID = DeviceID.current) throws -> VaultStore {
        guard !exists(at: url) else { throw VaultError.io("A vault already exists at \(url.path)") }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.appendingPathComponent("items", isDirectory: true),
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { throw VaultError.io(error.localizedDescription) }

        let vk = VaultKey.generate()
        let slot = try KeySlot.makePassword(password, vaultKey: vk, params: kdfParams)
        let header = VaultHeader(slots: [slot])
        let headerData = try header.encoded()
        let manifest = Manifest(generation: 0, deviceID: deviceID, headerHash: ManifestFile.sha256(headerData))
        let store = VaultStore(url: url, header: header, manifest: manifest, deviceID: deviceID)
        try AtomicFile.write(headerData, to: store.headerURL)
        store.installKeys(vk)
        try store.writeManifest(bumpingGeneration: false)
        return store
    }

    public static func open(at url: URL, deviceID: UUID = DeviceID.current) throws -> VaultStore {
        let headerURL = url.appendingPathComponent(VaultHeader.fileName)
        let header = try VaultHeader.decode(AtomicFile.read(headerURL))
        // Manifest cannot be verified before unlock; placeholder until then.
        let placeholder = Manifest(generation: 0, deviceID: deviceID, headerHash: Data())
        return VaultStore(url: url, header: header, manifest: placeholder, deviceID: deviceID)
    }

    public var isUnlocked: Bool { keys != nil }

    public var hasSecureEnclaveSlot: Bool { touchIDSlot != nil }

    public var secureEnclaveSlot: KeySlot? { touchIDSlot }

    public func unlock(password: SecureBytes) throws {
        guard let slot = header.slots.first(where: { $0.isPassword }) else { throw VaultError.corruptHeader }
        try unlock(vaultKey: try slot.unwrap(password: password))
    }

    public func unlock(vaultKey vk: SecureBytes) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard vk.count == VaultKey.byteCount else { throw VaultError.authenticationFailed }
        let candidate = VaultKeys(vaultKey: vk)
        // Verify the manifest before accepting the key: a wrong key fails here, and a
        // tampered manifest or header is rejected before any item is read.
        let manifestData = try AtomicFile.read(manifestURL)
        let decoded = try ManifestFile.decode(manifestData, key: candidate.manifest)
        guard decoded.headerHash == ManifestFile.sha256(try AtomicFile.read(headerURL)) else {
            throw VaultError.corruptManifest
        }
        candidate.wipe()
        manifest = decoded
        installKeys(vk)
        try migrateLegacyTouchIDSlot()
    }

    /// Phase 1 stored the Secure Enclave slot inside the synced header. Move it out once.
    private func migrateLegacyTouchIDSlot() throws {
        guard header.slots.contains(where: { $0.isSecureEnclave }) else { return }
        if touchIDSlot == nil, let legacy = header.slots.first(where: { $0.isSecureEnclave }) {
            try writeTouchIDSlot(legacy)
        }
        var h = header
        h.slots.removeAll { $0.isSecureEnclave }
        try writeHeader(h)
    }

    public func lock() {
        mutex.lock(); defer { mutex.unlock() }
        keys?.wipe()
        vaultKey?.wipe()
        keys = nil
        vaultKey = nil
    }

    private func installKeys(_ vk: SecureBytes) {
        keys = VaultKeys(vaultKey: vk)
        vaultKey = vk
    }

    private func requireKeys() throws -> VaultKeys {
        guard let keys else { throw VaultError.locked }
        return keys
    }

    /// Runs `body` with the raw vault key (needed to wrap it into a new slot).
    public func withVaultKey<R>(_ body: (SecureBytes) throws -> R) throws -> R {
        mutex.lock(); defer { mutex.unlock() }
        guard let vaultKey else { throw VaultError.locked }
        return try body(vaultKey)
    }

    // MARK: Items

    private func itemURL(_ id: UUID) -> URL {
        itemsURL.appendingPathComponent(id.uuidString).appendingPathExtension(ItemFile.fileExtension)
    }

    public struct LoadResult: Sendable {
        public var items: [ItemOverview]
        public var corrupt: [UUID]
    }

    /// Reads every item file's overview. Tombstones are skipped. Corrupt or rolled-back
    /// files are reported, not thrown. Files newer than the manifest repair it.
    /// Reason: one small read per file (header + overview box, a few hundred bytes); the
    /// details box is never touched here.
    public func loadOverviews() throws -> LoadResult {
        mutex.lock(); defer { mutex.unlock() }
        let keys = try requireKeys()
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: itemsURL.path) }
        catch { throw VaultError.io(error.localizedDescription) }

        var result = LoadResult(items: [], corrupt: [])
        var repaired = false
        var seen = Set<UUID>()
        for name in names where name.hasSuffix("." + ItemFile.fileExtension) && !name.hasPrefix(".") {
            guard let id = UUID(uuidString: String(name.dropLast(ItemFile.fileExtension.count + 1))) else { continue }
            seen.insert(id)
            do {
                let data = try AtomicFile.read(itemURL(id))
                let (fileHeader, overview) = try ItemFile.decodeOverview(data, keys: keys)
                guard fileHeader.id == id else { throw VaultError.corruptItemData }
                let known = manifest.version(of: id) ?? 0
                if fileHeader.version < known {
                    result.corrupt.append(id) // rolled back on disk
                    continue
                }
                if fileHeader.version > known {
                    manifest.set(version: fileHeader.version, for: id)
                    repaired = true
                }
                if !fileHeader.deleted { result.items.append(overview) }
            } catch {
                result.corrupt.append(id)
            }
        }
        // Listed in the manifest but missing on disk: report, keep the manifest entry.
        for id in manifest.itemIDs where !seen.contains(id) {
            result.corrupt.append(id)
        }
        if repaired { try writeManifest(bumpingGeneration: true) }
        result.items.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    public func details(for id: UUID) throws -> ItemDetails {
        mutex.lock(); defer { mutex.unlock() }
        let keys = try requireKeys()
        do { return try ItemFile.decodeDetails(try AtomicFile.read(itemURL(id)), keys: keys) }
        catch VaultError.corruptItemData { throw VaultError.corruptItem(id) }
        catch VaultError.authenticationFailed { throw VaultError.corruptItem(id) }
    }

    /// Writes a new version of the item. Secret fields that changed are recorded in history.
    @discardableResult
    public func save(overview: ItemOverview, details: ItemDetails) throws -> ItemOverview {
        mutex.lock(); defer { mutex.unlock() }
        let keys = try requireKeys()
        var next = overview
        next.updatedAt = Date().millisecondPrecision
        let version = (manifest.version(of: overview.id) ?? 0) + 1
        var finalDetails = details
        if version > 1, let previous = try? self.details(for: overview.id) {
            finalDetails = details.recordingChanges(from: previous, at: next.updatedAt)
        }
        let data = try ItemFile.encode(overview: next, details: finalDetails, version: version,
                                       deleted: false, keys: keys)
        try AtomicFile.write(data, to: itemURL(overview.id))
        manifest.set(version: version, for: overview.id)
        try writeManifest(bumpingGeneration: true)
        return next
    }

    /// Replaces the item with a tombstone (overview kept for display, details dropped).
    public func delete(id: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        let keys = try requireKeys()
        let url = itemURL(id)
        var overview: ItemOverview
        if let data = try? AtomicFile.read(url), let decoded = try? ItemFile.decodeOverview(data, keys: keys) {
            overview = decoded.overview
        } else {
            overview = ItemOverview(id: id, type: .secureNote, title: "Deleted item")
        }
        overview.updatedAt = Date().millisecondPrecision
        let version = (manifest.version(of: id) ?? 0) + 1
        let data = try ItemFile.encode(overview: overview, details: nil, version: version, deleted: true, keys: keys)
        try AtomicFile.write(data, to: url)
        manifest.set(version: version, for: id)
        try writeManifest(bumpingGeneration: true)
    }

    // MARK: Key slots

    public func addSecureEnclaveSlot(_ slot: KeySlot) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard slot.isSecureEnclave else { throw VaultError.cryptoFailure }
        _ = try requireKeys()
        try writeTouchIDSlot(slot)
    }

    public func removeSecureEnclaveSlots() throws {
        mutex.lock(); defer { mutex.unlock() }
        touchIDSlot = nil
        do { try FileManager.default.removeItem(at: touchIDSlotURL) } catch CocoaError.fileNoSuchFile {
        } catch let e as NSError where e.code == NSFileNoSuchFileError {
        } catch { throw VaultError.io(error.localizedDescription) }
    }

    private func writeTouchIDSlot(_ slot: KeySlot) throws {
        try AtomicFile.write(try JSONCoding.encoder.encode(slot), to: touchIDSlotURL)
        touchIDSlot = slot
    }

    public func changePassword(old: SecureBytes, new: SecureBytes, kdfParams: KDFParams = .fresh()) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard let vaultKey else { throw VaultError.locked }
        guard let idx = header.slots.firstIndex(where: { $0.isPassword }) else { throw VaultError.corruptHeader }
        guard try header.slots[idx].unwrap(password: old) == vaultKey else { throw VaultError.authenticationFailed }
        var h = header
        h.slots[idx] = try KeySlot.makePassword(new, vaultKey: vaultKey, params: kdfParams)
        h.updatedAt = Date().millisecondPrecision
        try writeHeader(h)
    }

    // MARK: Local secrets (remote tokens): encrypted under the vault key, stored as
    // `<name>.local` next to the header, never part of sync. Reason: the login Keychain
    // prompts on every rebuild of an ad-hoc-signed app and blocks the main thread.

    private func localSecretURL(_ name: String) -> URL { url.appendingPathComponent(name + ".local") }

    public func localSecret(_ name: String) throws -> String? {
        mutex.lock(); defer { mutex.unlock() }
        let keys = try requireKeys()
        let u = localSecretURL(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try AEAD.open(try AtomicFile.read(u), key: keys.local, aad: Data(name.utf8)).utf8String()
    }

    /// `nil` removes the secret.
    public func setLocalSecret(_ name: String, _ value: String?) throws {
        mutex.lock(); defer { mutex.unlock() }
        let keys = try requireKeys()
        let u = localSecretURL(name)
        guard let value, !value.isEmpty else {
            try? FileManager.default.removeItem(at: u)
            return
        }
        try AtomicFile.write(try AEAD.seal(SecureBytes(utf8: value), key: keys.local, aad: Data(name.utf8)), to: u)
    }

    // MARK: Sync support (raw encrypted bytes; no plaintext leaves this class)

    private var syncStateURL: URL { url.appendingPathComponent(SyncState.fileName) }

    public var syncState: SyncState {
        mutex.lock(); defer { mutex.unlock() }
        guard let data = try? Data(contentsOf: syncStateURL),
              let s = try? JSONCoding.decoder.decode(SyncState.self, from: data) else { return SyncState() }
        return s
    }

    public func saveSyncState(_ state: SyncState) throws {
        mutex.lock(); defer { mutex.unlock() }
        try AtomicFile.write(try JSONCoding.encoder.encode(state), to: syncStateURL)
    }

    public func headerData() throws -> Data { try AtomicFile.read(headerURL) }

    public func manifestData() throws -> Data { try AtomicFile.read(manifestURL) }

    public func itemData(_ id: UUID) throws -> Data? {
        mutex.lock(); defer { mutex.unlock() }
        let u = itemURL(id)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try AtomicFile.read(u)
    }

    public func itemIDsOnDisk() throws -> [UUID] {
        mutex.lock(); defer { mutex.unlock() }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: itemsURL.path)
                .filter { $0.hasSuffix("." + ItemFile.fileExtension) && !$0.hasPrefix(".") }
                .compactMap { UUID(uuidString: String($0.dropLast(ItemFile.fileExtension.count + 1))) }
        } catch { throw VaultError.io(error.localizedDescription) }
    }

    public func decodeRemoteManifest(_ data: Data) throws -> Manifest {
        mutex.lock(); defer { mutex.unlock() }
        return try ManifestFile.decode(data, key: try requireKeys().manifest)
    }

    public func encodeManifest(_ m: Manifest) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        return try ManifestFile.encode(m, key: try requireKeys().manifest)
    }

    /// Proves remote bytes belong to this vault (overview box opens with our key) and are
    /// internally consistent. Throws `corruptItemData` or `authenticationFailed`.
    @discardableResult
    public func verifyRemoteItem(_ data: Data) throws -> ItemFileHeader {
        mutex.lock(); defer { mutex.unlock() }
        return try ItemFile.decodeOverview(data, keys: try requireKeys()).header
    }

    /// Stores verified remote bytes as-is (no re-encryption). Does not touch the manifest.
    public func writeRawItem(_ data: Data) throws {
        mutex.lock(); defer { mutex.unlock() }
        let header = try verifyRemoteItem(data)
        try AtomicFile.write(data, to: itemURL(header.id))
    }

    /// Same item changed on two devices. Newer `updatedAt` wins; the loser's secret fields
    /// go into history (deduplicated, capped); the winner is tagged `conflict`.
    /// Deterministic given the same inputs, so both devices converge.
    public func mergeConflict(local: Data, remote: Data) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        let keys = try requireKeys()
        let l = try ItemFile.decodeOverview(local, keys: keys)
        let r = try ItemFile.decodeOverview(remote, keys: keys)
        guard l.header.id == r.header.id else { throw VaultError.corruptItemData }
        let lDetails = l.header.deleted ? ItemDetails() : try ItemFile.decodeDetails(local, keys: keys)
        let rDetails = r.header.deleted ? ItemDetails() : try ItemFile.decodeDetails(remote, keys: keys)

        let localWins = l.overview.updatedAt > r.overview.updatedAt
            || (l.overview.updatedAt == r.overview.updatedAt && GitBlob.sha(local) > GitBlob.sha(remote))
        let (win, lose) = localWins ? (l, r) : (r, l)
        var winDetails = localWins ? lDetails : rDetails
        let loseDetails = localWins ? rDetails : lDetails

        var additions: [SecretRevision] = []
        for key in ItemType.secretFieldKeys {
            guard let v = loseDetails.fields[key], !v.isEmpty, v != winDetails.fields[key],
                  !winDetails.history.contains(where: { $0.field == key && $0.value == v }) else { continue }
            additions.append(SecretRevision(field: key, value: v, changedAt: lose.overview.updatedAt))
        }
        winDetails.history = Array((additions + winDetails.history).prefix(ItemDetails.historyCap))

        var overview = win.overview
        if !overview.tags.contains("conflict") { overview.tags.append("conflict") }
        overview.updatedAt = Date().millisecondPrecision
        let version = max(l.header.version, r.header.version) + 1
        let deleted = win.header.deleted
        return try ItemFile.encode(overview: overview, details: deleted ? nil : winDetails,
                                   version: version, deleted: deleted, keys: keys)
    }

    /// Replaces the local manifest with a merged one (no generation bump; the engine set it).
    public func replaceManifest(_ m: Manifest) throws {
        mutex.lock(); defer { mutex.unlock() }
        let keys = try requireKeys()
        var next = m
        next.deviceID = deviceID
        try AtomicFile.write(try ManifestFile.encode(next, key: keys.manifest), to: manifestURL)
        manifest = next
    }

    /// Accepts a header from the remote (already proven by the remote manifest's MAC).
    public func applyRemoteHeader(_ data: Data) throws {
        mutex.lock(); defer { mutex.unlock() }
        _ = try requireKeys()
        var h = try VaultHeader.decode(data)
        h.slots.removeAll { !$0.isPassword }
        let bytes = h.slots.count == (try VaultHeader.decode(data)).slots.count ? data : try h.encoded()
        try AtomicFile.write(bytes, to: headerURL)
        header = h
        manifest.headerHash = ManifestFile.sha256(bytes)
    }

    // MARK: Files

    private func writeHeader(_ h: VaultHeader) throws {
        _ = try requireKeys()
        let data = try h.encoded()
        try AtomicFile.write(data, to: headerURL)
        header = h
        manifest.headerHash = ManifestFile.sha256(data)
        try writeManifest(bumpingGeneration: true)
    }

    private func writeManifest(bumpingGeneration: Bool) throws {
        let keys = try requireKeys()
        if bumpingGeneration { manifest.generation += 1 }
        manifest.deviceID = deviceID
        try AtomicFile.write(try ManifestFile.encode(manifest, key: keys.manifest), to: manifestURL)
    }
}
