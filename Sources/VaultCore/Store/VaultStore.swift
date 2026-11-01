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

    public var itemsURL: URL { url.appendingPathComponent("items", isDirectory: true) }
    private var headerURL: URL { url.appendingPathComponent(VaultHeader.fileName) }
    private var manifestURL: URL { url.appendingPathComponent(Manifest.fileName) }

    private init(url: URL, header: VaultHeader, manifest: Manifest, deviceID: UUID) {
        self.url = url
        self.header = header
        self.manifest = manifest
        self.deviceID = deviceID
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

    public var hasSecureEnclaveSlot: Bool { header.slots.contains { $0.isSecureEnclave } }

    public var secureEnclaveSlot: KeySlot? { header.slots.first { $0.isSecureEnclave } }

    public func unlock(password: SecureBytes) throws {
        guard let slot = header.slots.first(where: { $0.isPassword }) else { throw VaultError.corruptHeader }
        try unlock(vaultKey: try slot.unwrap(password: password))
    }

    public func unlock(vaultKey vk: SecureBytes) throws {
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
    }

    public func lock() {
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
        let keys = try requireKeys()
        do { return try ItemFile.decodeDetails(try AtomicFile.read(itemURL(id)), keys: keys) }
        catch VaultError.corruptItemData { throw VaultError.corruptItem(id) }
        catch VaultError.authenticationFailed { throw VaultError.corruptItem(id) }
    }

    /// Writes a new version of the item. Secret fields that changed are recorded in history.
    @discardableResult
    public func save(overview: ItemOverview, details: ItemDetails) throws -> ItemOverview {
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
        guard slot.isSecureEnclave else { throw VaultError.cryptoFailure }
        var h = header
        h.slots.removeAll { $0.isSecureEnclave }
        h.slots.append(slot)
        try writeHeader(h)
    }

    public func removeSecureEnclaveSlots() throws {
        var h = header
        h.slots.removeAll { $0.isSecureEnclave }
        try writeHeader(h)
    }

    public func changePassword(old: SecureBytes, new: SecureBytes, kdfParams: KDFParams = .fresh()) throws {
        guard let vaultKey else { throw VaultError.locked }
        guard let idx = header.slots.firstIndex(where: { $0.isPassword }) else { throw VaultError.corruptHeader }
        guard try header.slots[idx].unwrap(password: old) == vaultKey else { throw VaultError.authenticationFailed }
        var h = header
        h.slots[idx] = try KeySlot.makePassword(new, vaultKey: vaultKey, params: kdfParams)
        try writeHeader(h)
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
