import XCTest
@testable import VaultCore

/// Runs against a real bare repository on disk through the system git (file transport).
final class GitStoreTests: XCTestCase {
    var tmp: URL!
    var bare: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID())", isDirectory: true)
        bare = tmp.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await GitStore.run(try await GitStore.locateGit(), ["init", "-q", "--bare", "-b", "main", bare.path], cwd: nil, env: [:])
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func makeStore(_ name: String, prefix: String = "") throws -> GitStore {
        try GitStore(config: GitConfig(url: "file://" + bare.path, branch: "main", prefix: prefix),
                     cacheRoot: tmp.appendingPathComponent("cache-" + name), allowedProtocols: "file")
    }

    func commitCount() async throws -> Int {
        let r = try await GitStore.run(try await GitStore.locateGit(), ["rev-list", "--count", "main"], cwd: bare, env: [:])
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func testRoundTripOnAnEmptyRemote() async throws {
        let s = try makeStore("a", prefix: "vault")
        let empty = try await s.get("manifest.vman")
        XCTAssertNil(empty)
        let etag = try await s.put("items/a.vitem", data: Data("one".utf8), ifMatch: nil)
        XCTAssertEqual(etag, GitBlob.sha(Data("one".utf8)))
        let other = try makeStore("b", prefix: "vault") // a second clone sees it
        let got = try await other.get("items/a.vitem")
        XCTAssertEqual(got?.data, Data("one".utf8))
        let list = try await other.list(prefix: "items/")
        XCTAssertEqual(list, ["items/a.vitem": etag])
    }

    func testCreateOnlyAndStaleWritesConflict() async throws {
        let s = try makeStore("a")
        let e1 = try await s.put("x", data: Data("1".utf8), ifMatch: nil)
        do { _ = try await s.put("x", data: Data("2".utf8), ifMatch: nil); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .conflict("x")) }
        do { _ = try await s.put("x", data: Data("2".utf8), ifMatch: "bogus"); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .conflict("x")) }
        _ = try await s.put("x", data: Data("2".utf8), ifMatch: e1)
    }

    func testPushRejectedWhenAnotherDevicePushedFirst() async throws {
        let a = try makeStore("a"), b = try makeStore("b")
        _ = try await a.put("seed", data: Data("s".utf8), ifMatch: nil)
        do {
            try await a.withBatch {
                _ = try await a.put("mine", data: Data("a".utf8), ifMatch: nil)
                _ = try await b.put("theirs", data: Data("b".utf8), ifMatch: nil) // lands while A's batch is open
            }
            XCTFail("expected a conflict")
        } catch { XCTAssertEqual(error as? SyncError, .conflict("git push")) }
        let fresh = try await b.get("mine")
        XCTAssertNil(fresh, "a rejected batch publishes nothing")
        // The next round starts from the new head and succeeds.
        try await a.withBatch { _ = try await a.put("mine", data: Data("a".utf8), ifMatch: nil) }
        let after = try await b.get("mine")
        XCTAssertNotNil(after)
    }

    func testAFailedBatchLeavesNoLocalResidue() async throws {
        let a = try makeStore("a")
        struct Boom: Error {}
        do { try await a.withBatch { _ = try await a.put("x", data: Data("1".utf8), ifMatch: nil); throw Boom() } } catch {}
        let x = try await a.get("x")
        XCTAssertNil(x)
        let commits = try await commitCount()
        XCTAssertEqual(commits, 0)
    }

    func testProbeAcceptsAndLeavesNoCommit() async throws {
        let a = try makeStore("a")
        let result = try await a.probeConditionalWrites()
        XCTAssertEqual(result, .enforced)
        let commits = try await commitCount()
        XCTAssertEqual(commits, 0)
    }

    func testOneCommitPerSyncRoundAndNoneWhenIdle() async throws {
        let store = try makeStore("a", prefix: "vault")
        let cheap = KDFParams(memoryKiB: 8192, iterations: 1, salt: Data(repeating: 5, count: 16))
        let pw = SecureBytes(utf8: "pw")
        let a = try VaultStore.create(at: tmp.appendingPathComponent("A"), password: pw, kdfParams: cheap, deviceID: UUID())
        for i in 0..<3 { try a.save(overview: ItemOverview(type: .login, title: "Item \(i)"), details: ItemDetails(fields: ["password": "p\(i)"])) }
        _ = try await SyncEngine(store: a, remote: store).sync()
        let afterFirst = try await commitCount()
        XCTAssertEqual(afterFirst, 1, "header, manifest and three items go up in a single commit")
        _ = try await SyncEngine(store: a, remote: store).sync()
        let afterIdle = try await commitCount()
        XCTAssertEqual(afterIdle, 1, "an idle sync must not commit")

        let other = try makeStore("b", prefix: "vault")
        let b = try await SyncEngine.bootstrap(remote: other, into: tmp.appendingPathComponent("B"), password: pw, deviceID: UUID())
        XCTAssertEqual(try b.loadOverviews().items.count, 3)
        let afterBootstrap = try await commitCount()
        XCTAssertEqual(afterBootstrap, 1)
    }

    func testRejectsUnsafeAddresses() {
        for bad in ["", "-oProxyCommand=evil", "ext::sh -c id", "git@host:repo.git extra"] {
            XCTAssertFalse(GitConfig(url: bad).isValid, bad)
        }
        XCTAssertTrue(GitConfig(url: "git@github.com:me/vault.git").isValid)
        XCTAssertFalse(GitConfig(url: "git@host:r.git", branch: "--upload-pack=x").isValid)
    }

    func testErrorMapping() {
        XCTAssertEqual(GitStore.map(" ! [rejected]  HEAD -> main (fetch first)", pushing: true), .conflict("git push"))
        if case .network = GitStore.map("ssh: Could not resolve hostname nope") {} else { XCTFail() }
        if case .remote(_, let m) = GitStore.map("git@h: Permission denied (publickey).") { XCTAssertTrue(m.contains("SSH key")) } else { XCTFail() }
    }

    func testSymlinksInAHostileRepositoryAreNotFollowed() async throws {
        // Another "device" pushes a repository whose item path is a symlink to a local file.
        let git = try await GitStore.locateGit()
        let work = tmp.appendingPathComponent("hostile")
        func run(_ args: [String]) async throws {
            let r = try await GitStore.run(git, ["-c", "user.name=t", "-c", "user.email=t@t"] + args, cwd: work, env: [:])
            XCTAssertEqual(r.status, 0, r.stderr)
        }
        try FileManager.default.createDirectory(at: work.appendingPathComponent("items"), withIntermediateDirectories: true)
        let secretFile = tmp.appendingPathComponent("outside-secret.txt")
        try Data("do not read me".utf8).write(to: secretFile)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("items/00000000-0000-0000-0000-000000000001.vitem"),
                                                   withDestinationURL: secretFile)
        try await run(["init", "-q", "-b", "main"])
        try await run(["add", "-A"])
        try await run(["commit", "-q", "-m", "hostile"])
        try await run(["push", "-q", "file://" + bare.path, "HEAD:refs/heads/main"])

        let victim = try makeStore("victim")
        let got = try await victim.get("items/00000000-0000-0000-0000-000000000001.vitem")
        XCTAssertNotEqual(got?.data, Data("do not read me".utf8), "the link must not be followed to the file outside the clone")
        XCTAssertLessThan(got?.data.count ?? 0, 200, "it is checked out as a tiny plain file holding the link text")
    }

    func testGitAddressesWithCredentialsAreRejected() {
        XCTAssertFalse(GitConfig(url: "https://user:token@example.com/r.git").isValid)
        XCTAssertFalse(GitConfig(url: "https://ghp_token@github.com/me/r.git").isValid)
        XCTAssertTrue(GitConfig(url: "https://github.com/me/r.git").isValid)
        XCTAssertTrue(GitConfig(url: "git@github.com:me/r.git").isValid)
        XCTAssertTrue(GitConfig(url: "ssh://git@host.example/r.git").isValid)
    }
}
