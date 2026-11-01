import XCTest
@testable import VaultCore

final class SyncEngineTests: XCTestCase {
    let cheap = KDFParams(memoryKiB: 8192, iterations: 1, salt: Data(repeating: 5, count: 16))
    let pw = SecureBytes(utf8: "shared password")
    var root: URL!
    var remote: InMemoryRemoteStore!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        remote = InMemoryRemoteStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func vaultURL(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    func makeA() throws -> VaultStore {
        try VaultStore.create(at: vaultURL("A"), password: pw, kdfParams: cheap, deviceID: UUID())
    }

    func bootstrapB() async throws -> VaultStore {
        try await SyncEngine.bootstrap(remote: remote, into: vaultURL("B"), password: pw, deviceID: UUID())
    }

    func login(_ title: String, _ pass: String) -> (ItemOverview, ItemDetails) {
        (ItemOverview(type: .login, title: title), ItemDetails(fields: ["password": pass]))
    }

    func password(_ store: VaultStore, _ id: UUID) throws -> String? {
        try store.details(for: id).fields["password"]
    }

    @discardableResult
    func sync(_ store: VaultStore) async throws -> SyncReport {
        try await SyncEngine(store: store, remote: remote).sync()
    }

    // MARK: Tests

    func testInitialPushAndBootstrap() async throws {
        let a = try makeA()
        let (o1, d1) = login("Gmail", "a1")
        let (o2, d2) = login("Discord", "a2")
        try a.save(overview: o1, details: d1)
        try a.save(overview: o2, details: d2)
        let r = try await sync(a)
        XCTAssertEqual(r.pushed, 2)
        XCTAssertEqual(Set(remote.paths), ["vault.vhdr", "manifest.vman", RemotePaths.item(o1.id), RemotePaths.item(o2.id)])
        XCTAssertFalse(remote.paths.contains(VaultStore.touchIDSlotFileName))

        let b = try await bootstrapB()
        XCTAssertTrue(b.isUnlocked)
        let loaded = try b.loadOverviews()
        XCTAssertEqual(Set(loaded.items.map(\.title)), ["Gmail", "Discord"])
        XCTAssertEqual(loaded.corrupt, [])
        XCTAssertEqual(try password(b, o1.id), "a1")
        XCTAssertEqual(b.syncState.lastGeneration, a.manifest.generation)
        // A second sync on either side moves nothing.
        remote.resetCounters()
        let again = try await sync(b)
        XCTAssertEqual(again.pulled + again.pushed, 0)
        XCTAssertEqual(remote.puts, ["manifest.vman"])
        XCTAssertFalse(remote.gets.contains { $0.hasPrefix("items/") })
    }

    func testBootstrapWrongPasswordLeavesNothing() async throws {
        let a = try makeA()
        try a.save(overview: login("X", "x").0, details: login("X", "x").1)
        try await sync(a)
        do {
            _ = try await SyncEngine.bootstrap(remote: remote, into: vaultURL("B"), password: SecureBytes(utf8: "wrong"), deviceID: UUID())
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? VaultError, .authenticationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL("B").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["A"])
    }

    func testEditAndDeletePropagateBothWays() async throws {
        let a = try makeA()
        let (o1, d1) = login("Gmail", "v1")
        try a.save(overview: o1, details: d1)
        try await sync(a)
        let b = try await bootstrapB()

        try a.save(overview: o1, details: ItemDetails(fields: ["password": "v2"]))
        try await sync(a)
        let rb = try await sync(b)
        XCTAssertEqual(rb.pulled, 1)
        XCTAssertEqual(try password(b, o1.id), "v2")
        XCTAssertEqual(try b.details(for: o1.id).history.map(\.value), ["v1"])

        let (o2, d2) = login("GitHub", "g1")
        try b.save(overview: o2, details: d2)
        try b.delete(id: o1.id)
        try await sync(b)
        let ra = try await sync(a)
        XCTAssertEqual(ra.pulled, 2)
        let items = try a.loadOverviews().items
        XCTAssertEqual(items.map(\.title), ["GitHub"])
        XCTAssertEqual(try password(a, o2.id), "g1")
        XCTAssertEqual(a.manifest.versions, b.manifest.versions)
    }

    func testDisjointEditsBothKept() async throws {
        let a = try makeA()
        let (o1, d1) = login("One", "1"), (o2, d2) = login("Two", "2")
        try a.save(overview: o1, details: d1)
        try a.save(overview: o2, details: d2)
        try await sync(a)
        let b = try await bootstrapB()
        try a.save(overview: o1, details: ItemDetails(fields: ["password": "1a"]))
        try b.save(overview: o2, details: ItemDetails(fields: ["password": "2b"]))
        try await sync(a)
        let rb = try await sync(b)
        XCTAssertEqual(rb.conflicts, 0)
        XCTAssertEqual(rb.pulled, 1)
        XCTAssertEqual(rb.pushed, 1)
        try await sync(a)
        for s in [a, b] {
            XCTAssertEqual(try password(s, o1.id), "1a")
            XCTAssertEqual(try password(s, o2.id), "2b")
        }
    }

    func testSameItemConflictKeepsBothValues() async throws {
        let a = try makeA()
        let (o, d) = login("Gmail", "base")
        try a.save(overview: o, details: d)
        try await sync(a)
        let b = try await bootstrapB()

        try a.save(overview: o, details: ItemDetails(fields: ["password": "from-a"]))
        try await Task.sleep(for: .milliseconds(3))
        try b.save(overview: o, details: ItemDetails(fields: ["password": "from-b"])) // newer → wins
        try await sync(a)
        let rb = try await sync(b)
        XCTAssertEqual(rb.conflicts, 1)
        let ra = try await sync(a)
        XCTAssertEqual(ra.pulled, 1)

        for s in [a, b] {
            let details = try s.details(for: o.id)
            XCTAssertEqual(details.fields["password"], "from-b")
            XCTAssertTrue(details.history.map(\.value).contains("from-a"))
            XCTAssertTrue(details.history.map(\.value).contains("base"))
            XCTAssertTrue(try s.loadOverviews().items[0].tags.contains("conflict"))
        }
        XCTAssertEqual(a.manifest.versions, b.manifest.versions)
        // Converged: another round on each side moves nothing.
        let r2 = try await sync(b)
        XCTAssertEqual(r2.pulled + r2.pushed + r2.conflicts, 0)
    }

    func testRollbackRefused() async throws {
        let a = try makeA()
        let (o, d) = login("Gmail", "1")
        try a.save(overview: o, details: d)
        try await sync(a)
        let old = remote[RemotePaths.manifest]!
        try a.save(overview: o, details: ItemDetails(fields: ["password": "2"]))
        try await sync(a)
        remote[RemotePaths.manifest] = old // provider serves an older manifest
        do { try await sync(a); XCTFail("expected rollback error") } catch {
            guard case .rollbackDetected = error as? VaultError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try password(a, o.id), "2")
    }

    func testTamperedRemoteItemRejectedWithoutTouchingLocal() async throws {
        let a = try makeA()
        let (o, d) = login("Gmail", "1")
        try a.save(overview: o, details: d)
        try await sync(a)
        let b = try await bootstrapB()
        try a.save(overview: o, details: ItemDetails(fields: ["password": "2"]))
        try await sync(a)
        var bytes = remote[RemotePaths.item(o.id)]!
        bytes[60] ^= 0xff
        remote[RemotePaths.item(o.id)] = bytes
        do { try await sync(b); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? VaultError, .authenticationFailed)
        }
        XCTAssertEqual(try password(b, o.id), "1")
        XCTAssertEqual(b.manifest.version(of: o.id), 1)
    }

    func testTamperedRemoteManifestRejected() async throws {
        let a = try makeA()
        try a.save(overview: login("X", "x").0, details: login("X", "x").1)
        try await sync(a)
        var m = remote[RemotePaths.manifest]!
        m[1] ^= 0x01
        remote[RemotePaths.manifest] = m
        do { try await sync(a); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .corruptManifest) }
    }

    func testManifestConflictRetries() async throws {
        let a = try makeA()
        try a.save(overview: login("X", "x").0, details: login("X", "x").1)
        try await sync(a)
        try a.save(overview: login("Y", "y").0, details: login("Y", "y").1)
        remote.conflictOnce = [RemotePaths.manifest]
        let r = try await sync(a)
        XCTAssertEqual(r.pushed, 1)
        XCTAssertEqual(remote.lists, 3) // initial push + failed round + successful round
    }

    func testPartialUploadResumes() async throws {
        let a = try makeA()
        for i in 0..<3 { try a.save(overview: login("Item\(i)", "p").0, details: login("Item\(i)", "p").1) }
        remote.failPutsAfter = 2 // header + 1 item, then the network dies
        do { try await sync(a); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .network("injected")) }
        XCTAssertNil(remote[RemotePaths.manifest])
        remote.failPutsAfter = nil
        remote.resetCounters()
        let r = try await sync(a)
        XCTAssertEqual(r.pushed, 2) // only the two missing items
        XCTAssertEqual(remote.paths.count, 5)
        let b = try await bootstrapB()
        XCTAssertEqual(try b.loadOverviews().items.count, 3)
    }

    func testPasswordChangePropagatesViaHeader() async throws {
        let a = try makeA()
        try a.save(overview: login("X", "x").0, details: login("X", "x").1)
        try await sync(a)
        let b = try await bootstrapB()
        try await Task.sleep(for: .milliseconds(3))
        try a.changePassword(old: pw, new: SecureBytes(utf8: "new one"), kdfParams: cheap)
        try await sync(a)
        try await sync(b)
        b.lock()
        XCTAssertThrowsError(try b.unlock(password: pw))
        try b.unlock(password: SecureBytes(utf8: "new one"))
        XCTAssertEqual(try b.loadOverviews().items.count, 1)
    }
}
