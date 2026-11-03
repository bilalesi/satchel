import XCTest
@testable import VaultCore

final class FolderStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        // SATCHEL_FOLDER_TEST_ROOT=/Volumes/vault runs these against a network share or another real folder.
        let base = ProcessInfo.processInfo.environment["SATCHEL_FOLDER_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("folder-remote-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testAMissingFolderIsUnavailableNotEmpty() async throws {
        // An unmounted share or an ejected drive: not an empty remote, and nothing is created in its place.
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("unmounted-\(UUID().uuidString)")
        let store = FolderStore(root: gone)
        for op in ["get", "put", "list", "delete"] {
            do {
                switch op {
                case "get": _ = try await store.get("manifest.vman")
                case "put": _ = try await store.put("manifest.vman", data: Data([1]), ifMatch: nil)
                case "list": _ = try await store.list(prefix: "items/")
                default: try await store.delete("manifest.vman", ifMatch: nil)
                }
                XCTFail("\(op) must not treat a missing folder as empty")
            } catch let e as SyncError {
                guard case .unavailable = e else { return XCTFail("\(op): \(e)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testGitBlobKnownAnswer() {
        XCTAssertEqual(GitBlob.sha(Data("hello\n".utf8)), "ce013625030ba8dba906f756967f9e9ca394464a")
        XCTAssertEqual(GitBlob.sha(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    func testCompareAndSwap() async throws {
        let s = FolderStore(root: dir)
        let absent = try await s.get("items/a.vitem")
        XCTAssertNil(absent)
        let e1 = try await s.put("items/a.vitem", data: Data([1]), ifMatch: nil)
        XCTAssertEqual(e1, GitBlob.sha(Data([1])))
        // Create-only on an existing object fails; wrong etag fails; right etag succeeds.
        do { _ = try await s.put("items/a.vitem", data: Data([2]), ifMatch: nil); XCTFail() }
        catch { XCTAssertEqual(error as? SyncError, .conflict("items/a.vitem")) }
        do { _ = try await s.put("items/a.vitem", data: Data([2]), ifMatch: "nope"); XCTFail() }
        catch { XCTAssertEqual(error as? SyncError, .conflict("items/a.vitem")) }
        let e2 = try await s.put("items/a.vitem", data: Data([2]), ifMatch: e1)
        let got = try await s.get("items/a.vitem")
        XCTAssertEqual(got, RemoteObject(data: Data([2]), etag: e2))
        _ = try await s.put("items/b.vitem", data: Data([3]), ifMatch: nil)
        _ = try await s.put("vault.vhdr", data: Data([4]), ifMatch: nil)
        let listed = try await s.list(prefix: "items/")
        XCTAssertEqual(listed, ["items/a.vitem": e2, "items/b.vitem": GitBlob.sha(Data([3]))])
        XCTAssertEqual(RemotePaths.itemID(fromPath: RemotePaths.item(UUID(uuidString: "0A0B0C0D-0000-0000-0000-000000000000")!))?.uuidString,
                       "0A0B0C0D-0000-0000-0000-000000000000")
        XCTAssertNil(RemotePaths.itemID(fromPath: "items/junk.txt"))
    }

    func testSpecialFilesAreNotReadAndNotListed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("items"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("items/a.vitem"), withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        try Data("ok".utf8).write(to: dir.appendingPathComponent("items/b.vitem"))
        let store = FolderStore(root: dir)
        do { _ = try await store.get("items/a.vitem"); XCTFail("a link to a device must not be read") } catch {}
        let list = try await store.list(prefix: "items/")
        XCTAssertEqual(Set(list.keys), ["items/b.vitem"])
    }
}
