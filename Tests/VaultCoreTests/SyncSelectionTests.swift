import XCTest
@testable import VaultCore

/// Etags that are not content hashes (like S3 and WebDAV): the engine must not assume otherwise.
private final class OpaqueEtagStore: RemoteStore, @unchecked Sendable {
    let inner: InMemoryRemoteStore
    var displayName: String { "opaque" }
    init(_ inner: InMemoryRemoteStore) { self.inner = inner }
    private func wrap(_ e: String) -> String { "\"opaque-\(e)\"" }
    private func unwrap(_ e: String?) -> String? { e.map { String($0.dropFirst(8).dropLast()) } }
    func get(_ path: String) async throws -> RemoteObject? {
        try await inner.get(path).map { RemoteObject(data: $0.data, etag: wrap($0.etag)) }
    }
    func put(_ path: String, data: Data, ifMatch: String?) async throws -> String {
        wrap(try await inner.put(path, data: data, ifMatch: unwrap(ifMatch)))
    }
    func list(prefix: String) async throws -> [String: String] {
        try await inner.list(prefix: prefix).mapValues(wrap)
    }
    func delete(_ path: String, ifMatch: String?) async throws {
        try await inner.delete(path, ifMatch: unwrap(ifMatch))
    }
}

/// A server that ignores preconditions, like an object store without conditional writes.
private final class LaxStore: RemoteStore, @unchecked Sendable {
    let inner = InMemoryRemoteStore()
    var displayName: String { "lax" }
    func get(_ path: String) async throws -> RemoteObject? { try await inner.get(path) }
    func put(_ path: String, data: Data, ifMatch: String?) async throws -> String {
        try? await inner.delete(path, ifMatch: nil)
        return try await inner.put(path, data: data, ifMatch: nil)
    }
    func list(prefix: String) async throws -> [String: String] { try await inner.list(prefix: prefix) }
    func delete(_ path: String, ifMatch: String?) async throws { try await inner.delete(path, ifMatch: nil) }
}

final class SyncSelectionTests: XCTestCase {
    let cheap = KDFParams(memoryKiB: 8192, iterations: 1, salt: Data(repeating: 5, count: 16))
    let pw = SecureBytes(utf8: "shared password")
    var root: URL!
    var remote: InMemoryRemoteStore!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        remote = InMemoryRemoteStore()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func makeA() throws -> VaultStore {
        try VaultStore.create(at: root.appendingPathComponent("A"), password: pw, kdfParams: cheap, deviceID: UUID())
    }
    func item(_ title: String, category: UUID? = nil) -> (ItemOverview, ItemDetails) {
        (ItemOverview(type: .login, title: title, categoryID: category), ItemDetails(fields: ["password": title]))
    }
    func save(_ s: VaultStore, _ pair: (ItemOverview, ItemDetails)) throws { try s.save(overview: pair.0, details: pair.1) }

    // MARK: Probe

    func testProbeAcceptsAServerThatEnforcesPreconditions() async throws {
        let result = try await remote.probeConditionalWrites()
        XCTAssertEqual(result, .enforced)
        XCTAssertEqual(remote.paths, [], "the scratch object must be removed")
    }

    func testProbeRejectsAServerThatIgnoresPreconditions() async throws {
        let lax = LaxStore()
        let result = try await lax.probeConditionalWrites()
        guard case .notEnforced = result else { return XCTFail("expected notEnforced, got \(result)") }
        XCTAssertEqual(lax.inner.paths, [])
    }

    // MARK: Opaque etags

    func testOpaqueEtagsDoNotCauseReuploadsOrFalseConflicts() async throws {
        let store = OpaqueEtagStore(remote)
        let a = try makeA()
        try save(a, item("one")); try save(a, item("two"))
        let r1 = try await SyncEngine(store: a, remote: store).sync()
        XCTAssertEqual(r1.pushed, 2)
        remote.resetCounters()
        let r2 = try await SyncEngine(store: a, remote: store).sync()
        XCTAssertEqual(r2.pushed, 0)
        XCTAssertEqual(r2.pulled, 0)
        XCTAssertEqual(r2.conflicts, 0)
        XCTAssertEqual(remote.puts, [], "an unchanged vault must not write anything")
    }

    func testOpaqueEtagsStillPushALocalEdit() async throws {
        let store = OpaqueEtagStore(remote)
        let a = try makeA()
        let one = item("one")
        try save(a, one)
        try await SyncEngine(store: a, remote: store).sync()
        var edited = one.0
        edited.title = "one (edited)"
        try a.save(overview: edited, details: one.1)
        let r = try await SyncEngine(store: a, remote: store).sync()
        XCTAssertEqual(r.pushed, 1)
        XCTAssertEqual(r.conflicts, 0)
    }

    // MARK: Selective sync

    func testExcludedCategoryIsNeitherUploadedNorLostLocally() async throws {
        let a = try makeA()
        let work = ItemOverview(type: .category, title: "Work")
        try a.save(overview: work, details: ItemDetails(fields: [:]))
        let secret = item("Work VPN", category: work.id)
        let personal = item("Gmail")
        try save(a, secret); try save(a, personal)
        var sel = SyncSelection()
        sel.excludedCategories = [work.id]
        let r = try await SyncEngine(store: a, remote: remote, filter: sel).sync()
        XCTAssertEqual(r.pushed, 1)
        XCTAssertNil(remote[RemotePaths.item(secret.0.id)])
        XCTAssertNil(remote[RemotePaths.item(work.id)])
        XCTAssertNotNil(remote[RemotePaths.item(personal.0.id)])
        // Still on this Mac, and a second sync leaves it alone.
        XCTAssertEqual(try a.details(for: secret.0.id).fields["password"], "Work VPN")
        remote.resetCounters()
        try await SyncEngine(store: a, remote: remote, filter: sel).sync()
        XCTAssertEqual(remote.puts, [])
        XCTAssertEqual(try a.details(for: secret.0.id).fields["password"], "Work VPN")
    }

    func testRemoteItemsOutsideTheSelectionAreNotStoredAndAppearWhenSelected() async throws {
        let a = try makeA()
        let work = ItemOverview(type: .category, title: "Work")
        try a.save(overview: work, details: ItemDetails(fields: [:]))
        let secret = item("Work VPN", category: work.id)
        try save(a, secret); try save(a, item("Gmail"))
        try await SyncEngine(store: a, remote: remote).sync() // everything goes up

        let b = try await SyncEngine.bootstrap(remote: remote, into: root.appendingPathComponent("B"), password: pw, deviceID: UUID())
        // Bootstrap copies everything; narrowing the selection afterwards must not delete or resurrect anything.
        var sel = SyncSelection()
        sel.excludedCategories = [work.id]
        let r = try await SyncEngine(store: b, remote: remote, filter: sel).sync()
        XCTAssertEqual(r.conflicts, 0)
        XCTAssertEqual(try b.details(for: secret.0.id).fields["password"], "Work VPN")
    }

    func testExcludedItemEditedElsewhereIsNotDownloaded() async throws {
        let a = try makeA()
        let work = ItemOverview(type: .category, title: "Work")
        try a.save(overview: work, details: ItemDetails(fields: [:]))
        let secret = item("Work VPN", category: work.id)
        try save(a, secret)
        try await SyncEngine(store: a, remote: remote).sync()

        // C holds a copy of the vault but deliberately has no local file for the Work item.
        let c = try await SyncEngine.bootstrap(remote: remote, into: root.appendingPathComponent("C"), password: pw, deviceID: UUID())
        try FileManager.default.removeItem(at: root.appendingPathComponent("C/items/\(secret.0.id.uuidString).\(ItemFile.fileExtension)"))
        var sel = SyncSelection()
        sel.excludedCategories = [work.id]
        remote.resetCounters()
        try await SyncEngine(store: c, remote: remote, filter: sel).sync()
        XCTAssertNil(try? c.details(for: secret.0.id), "an excluded item must not be stored on this device")
        // Re-including it brings it back on the next sync.
        try await SyncEngine(store: c, remote: remote, filter: SyncEverything()).sync()
        XCTAssertEqual(try c.details(for: secret.0.id).fields["password"], "Work VPN")
    }

    func testDeletingAnExcludedItemStillPropagates() async throws {
        let a = try makeA()
        let work = ItemOverview(type: .category, title: "Work")
        try a.save(overview: work, details: ItemDetails(fields: [:]))
        let secret = item("Work VPN", category: work.id)
        try save(a, secret)
        try await SyncEngine(store: a, remote: remote).sync()   // it is on the remote
        let before = remote[RemotePaths.item(secret.0.id)]
        try a.delete(id: secret.0.id)
        var sel = SyncSelection()
        sel.excludedCategories = [work.id]
        try await SyncEngine(store: a, remote: remote, filter: sel).sync()
        XCTAssertNotEqual(remote[RemotePaths.item(secret.0.id)], before, "the tombstone must reach the remote")
    }

    func testSelectionRoundTripsAndFingerprintTracksChanges() throws {
        var s = SyncSelection()
        XCTAssertTrue(s.isDefault)
        let fp0 = s.fingerprint
        s.excludedCategories = [UUID()]
        s.itemOverrides[UUID()] = true
        XCTAssertNotEqual(s.fingerprint, fp0)
        let back = try JSONDecoder().decode(SyncSelection.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
