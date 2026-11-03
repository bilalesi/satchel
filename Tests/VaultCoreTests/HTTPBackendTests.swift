import XCTest
@testable import VaultCore

final class WebDAVStoreTests: XCTestCase {
    var dav: FakeWebDAV!
    var store: WebDAVStore!

    override func setUpWithError() throws {
        dav = FakeWebDAV()
        dav.install()
        store = try WebDAVStore(baseURL: URL(string: "https://dav.test/dav/satchel")!, username: dav.user, password: dav.pass,
                                session: MockHTTPProtocol.session())
    }

    func testPutCreatesParentFoldersAndGetReturnsServerETag() async throws {
        let etag = try await store.put("items/a.vitem", data: Data("one".utf8), ifMatch: nil)
        let got = try await store.get("items/a.vitem")
        XCTAssertEqual(got, RemoteObject(data: Data("one".utf8), etag: etag))
        XCTAssertNotNil(dav.data("items/a.vitem"))
    }

    func testCreateOnlyAndStaleWritesConflict() async throws {
        let e1 = try await store.put("manifest.vman", data: Data("1".utf8), ifMatch: nil)
        do { _ = try await store.put("manifest.vman", data: Data("x".utf8), ifMatch: nil); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .conflict("manifest.vman")) }
        let e2 = try await store.put("manifest.vman", data: Data("2".utf8), ifMatch: e1)
        do { _ = try await store.put("manifest.vman", data: Data("y".utf8), ifMatch: e1); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .conflict("manifest.vman")) }
        XCTAssertNotEqual(e1, e2)
        XCTAssertEqual(dav.data("manifest.vman"), Data("2".utf8))
    }

    func testPutWithoutETagHeaderFallsBackToHead() async throws {
        dav.omitPutETag = true
        let etag = try await store.put("vault.vhdr", data: Data("h".utf8), ifMatch: nil)
        let got = try await store.get("vault.vhdr")
        XCTAssertEqual(got?.etag, etag)
    }

    func testListReturnsOnlyFilesOfThePrefix() async throws {
        _ = try await store.put("items/a.vitem", data: Data("a".utf8), ifMatch: nil)
        _ = try await store.put("items/b c.vitem", data: Data("b".utf8), ifMatch: nil)
        _ = try await store.put("manifest.vman", data: Data("m".utf8), ifMatch: nil)
        let list = try await store.list(prefix: "items/")
        XCTAssertEqual(Set(list.keys), ["items/a.vitem", "items/b c.vitem"])
        let empty = try await store.list(prefix: "nothing/")
        XCTAssertEqual(empty, [:])
    }

    func testWrongPasswordIsUnauthorized() async throws {
        let bad = try WebDAVStore(baseURL: URL(string: "https://dav.test/dav/satchel")!, username: "me", password: "nope", session: MockHTTPProtocol.session())
        do { _ = try await bad.get("x"); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .unauthorized) }
    }

    func testPlainHTTPIsRefusedExceptForLocalhost() throws {
        XCTAssertThrowsError(try WebDAVStore(baseURL: URL(string: "http://nas.example.com/dav")!, username: "a", password: "b"))
        XCTAssertNoThrow(try WebDAVStore(baseURL: URL(string: "http://localhost:8080/dav")!, username: "a", password: "b"))
    }

    func testProbeAcceptsAnEnforcingServerAndRejectsALaxOne() async throws {
        let ok = try await store.probeConditionalWrites()
        XCTAssertEqual(ok, .enforced)
        XCTAssertEqual(dav.paths, [])
        dav.enforcePreconditions = false
        let lax = try await store.probeConditionalWrites()
        guard case .notEnforced = lax else { return XCTFail("\(lax)") }
    }

    /// A real server: SATCHEL_WEBDAV_TEST_URL is an existing folder on it, such as http://localhost:8088/dav
    /// (`bun run test-webdav up` in the website repository starts one; SATCHEL_WEBDAV_TEST_USER and _PASSWORD default
    /// to its test account). The test makes and removes a folder of its own inside it.
    func testLiveServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["SATCHEL_WEBDAV_TEST_URL"], let base = URL(string: raw) else { throw XCTSkip("set SATCHEL_WEBDAV_TEST_URL") }
        let live = try WebDAVStore(baseURL: base.appendingPathComponent("test-\(UUID().uuidString)"),
                                   username: env["SATCHEL_WEBDAV_TEST_USER"] ?? "satchel", password: env["SATCHEL_WEBDAV_TEST_PASSWORD"] ?? "satchel-test")
        try await live.verify() // creates the folder, as setting up sync does
        let probe = try await live.probeConditionalWrites()
        XCTAssertEqual(probe, .enforced)
        let e1 = try await live.put("items/a.vitem", data: Data([1]), ifMatch: nil)
        do { _ = try await live.put("items/a.vitem", data: Data([2]), ifMatch: nil); XCTFail("create-only must conflict") } catch SyncError.conflict {}
        do { _ = try await live.put("items/a.vitem", data: Data([2]), ifMatch: "\"stale\""); XCTFail("stale write must conflict") } catch SyncError.conflict {}
        let e2 = try await live.put("items/a.vitem", data: Data([2]), ifMatch: e1)
        let got = try await live.get("items/a.vitem")
        XCTAssertEqual(got?.data, Data([2]))
        XCTAssertEqual(got?.etag, e2)
        let listed = try await live.list(prefix: "items/")
        XCTAssertEqual(Array(listed.keys), ["items/a.vitem"])
        try await live.delete("items/a.vitem", ifMatch: e2)
        let gone = try await live.get("items/a.vitem")
        XCTAssertNil(gone)
    }

    func testApacheWeakETagRightAfterAWriteIsRetriedOnce() async throws {
        dav.apacheWeakETags = true
        WebDAVStore.weakETagWait = .zero
        defer { WebDAVStore.weakETagWait = .milliseconds(1100) }
        // The setup check writes and overwrites at once: it must pass on such a server.
        let probe = try await store.probeConditionalWrites()
        XCTAssertEqual(probe, .enforced)
        // A write right after a write succeeds.
        let e1 = try await store.put("items/a.vitem", data: Data([1]), ifMatch: nil)
        XCTAssertTrue(e1.hasPrefix("W/"))
        let e2 = try await store.put("items/a.vitem", data: Data([2]), ifMatch: e1)
        // A real change by another device is still a conflict, retry or not.
        dav.seed("items/a.vitem", Data([9]))
        do { _ = try await store.put("items/a.vitem", data: Data([3]), ifMatch: e2); XCTFail("must conflict") } catch SyncError.conflict {}
        XCTAssertEqual(dav.data("items/a.vitem"), Data([9]))
    }

    func testVerifyCreatesAMissingFolderOnlyWhenParentExists() async throws {
        try await store.verify() // root dir "" exists in the fake; satchel folder is the root here
    }

    func testTwoDevicesSyncThroughWebDAV() async throws {
        let cheap = KDFParams(memoryKiB: 8192, iterations: 1, salt: Data(repeating: 5, count: 16))
        let pw = SecureBytes(utf8: "pw")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dav-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try VaultStore.create(at: tmp.appendingPathComponent("A"), password: pw, kdfParams: cheap, deviceID: UUID())
        let item = ItemOverview(type: .login, title: "Gmail")
        try a.save(overview: item, details: ItemDetails(fields: ["password": "p1"]))
        let r1 = try await SyncEngine(store: a, remote: store).sync()
        XCTAssertEqual(r1.pushed, 1)
        let b = try await SyncEngine.bootstrap(remote: store, into: tmp.appendingPathComponent("B"), password: pw, deviceID: UUID())
        XCTAssertEqual(try b.details(for: item.id).fields["password"], "p1")
        // B edits, A pulls; then an idle round writes nothing.
        var edited = item; edited.title = "Gmail (work)"
        try b.save(overview: edited, details: ItemDetails(fields: ["password": "p2"]))
        _ = try await SyncEngine(store: b, remote: store).sync()
        let r2 = try await SyncEngine(store: a, remote: store).sync()
        XCTAssertEqual(r2.pulled, 1)
        XCTAssertEqual(try a.details(for: item.id).fields["password"], "p2")
        MockHTTPProtocol.requests = []
        _ = try await SyncEngine(store: a, remote: store).sync()
        XCTAssertFalse(MockHTTPProtocol.requests.contains { $0.httpMethod == "PUT" }, "an idle sync must not write")
    }
}

final class SigV4Tests: XCTestCase {
    // Published AWS examples ("Signature Calculations for the Authorization Header").
    let creds = SigV4.Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let date = Date(timeIntervalSince1970: 1369353600) // 2013-05-24T00:00:00Z
    let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func testGetObjectVector() {
        let h = SigV4.sign(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, headers: ["Range": "bytes=0-9"],
                           payloadHash: emptyHash, date: date, region: "us-east-1", service: "s3", credentials: creds)
        XCTAssertTrue(h["Authorization"]!.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"), h["Authorization"]!)
        XCTAssertTrue(h["Authorization"]!.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"))
    }

    func testPutObjectVectorWithEncodedKey() {
        let body = Data("Welcome to Amazon S3.".utf8)
        let h = SigV4.sign(method: "PUT", url: URL(string: "https://examplebucket.s3.amazonaws.com/test%24file.text")!,
                           headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"],
                           payloadHash: SigV4.sha256Hex(body), date: date, region: "us-east-1", service: "s3", credentials: creds)
        XCTAssertTrue(h["Authorization"]!.hasSuffix("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"), h["Authorization"]!)
    }

    func testListObjectsVectorWithQuery() {
        let h = SigV4.sign(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!, headers: [:],
                           payloadHash: emptyHash, date: date, region: "us-east-1", service: "s3", credentials: creds)
        XCTAssertTrue(h["Authorization"]!.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"), h["Authorization"]!)
    }
}

final class S3StoreTests: XCTestCase {
    var s3: FakeS3!
    var store: S3Store!

    func makeStore(prefix: String = "vault") throws -> S3Store {
        try S3Store(config: S3Config(endpoint: "https://s3.test", region: s3.region, bucket: s3.bucket, prefix: prefix, accessKeyID: s3.access),
                    secretKey: s3.secret, session: MockHTTPProtocol.session())
    }

    /// A real bucket (AWS S3, Cloudflare R2, MinIO): SATCHEL_S3_TEST_ENDPOINT, _REGION (default "auto"), _BUCKET,
    /// _ACCESS_KEY and _SECRET. `bun run r2-sync-test` in the website repository makes an R2 one and keeps its key in
    /// that repository's .env as R2_SYNC_*. Works in a folder of its own inside the bucket and removes what it wrote.
    func testLiveBucket() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["SATCHEL_S3_TEST_ENDPOINT"], let bucket = env["SATCHEL_S3_TEST_BUCKET"],
              let access = env["SATCHEL_S3_TEST_ACCESS_KEY"], let secret = env["SATCHEL_S3_TEST_SECRET"] else { throw XCTSkip("set SATCHEL_S3_TEST_*") }
        let live = try S3Store(config: S3Config(endpoint: endpoint, region: env["SATCHEL_S3_TEST_REGION"] ?? "auto", bucket: bucket,
                                                prefix: "test-\(UUID().uuidString)", accessKeyID: access), secretKey: secret)
        try await live.verify()
        let probe = try await live.probeConditionalWrites()
        XCTAssertEqual(probe, .enforced)
        let e1 = try await live.put("items/a.vitem", data: Data([1]), ifMatch: nil)
        do { _ = try await live.put("items/a.vitem", data: Data([2]), ifMatch: nil); XCTFail("create-only must conflict") } catch SyncError.conflict {}
        do { _ = try await live.put("items/a.vitem", data: Data([2]), ifMatch: "\"stale\""); XCTFail("stale write must conflict") } catch SyncError.conflict {}
        let e2 = try await live.put("items/a.vitem", data: Data([2]), ifMatch: e1)
        let got = try await live.get("items/a.vitem")
        XCTAssertEqual(got?.data, Data([2]))
        let listed = try await live.list(prefix: "items/")
        XCTAssertEqual(Array(listed.keys), ["items/a.vitem"])
        try await live.delete("items/a.vitem", ifMatch: e2)
        let gone = try await live.get("items/a.vitem")
        XCTAssertNil(gone)
    }

    override func setUpWithError() throws {
        s3 = FakeS3()
        s3.install()
        store = try makeStore()
    }

    func testRequestsAreSignedAndUseThePrefix() async throws {
        let etag = try await store.put("items/a.vitem", data: Data("a".utf8), ifMatch: nil)
        XCTAssertEqual(s3.keys, ["vault/items/a.vitem"])
        let got = try await store.get("items/a.vitem")
        XCTAssertEqual(got, RemoteObject(data: Data("a".utf8), etag: etag))
        XCTAssertEqual(s3.badSignatures, 0)
    }

    func testCreateOnlyAndStaleWritesConflict() async throws {
        let e1 = try await store.put("manifest.vman", data: Data("1".utf8), ifMatch: nil)
        do { _ = try await store.put("manifest.vman", data: Data("x".utf8), ifMatch: nil); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .conflict("manifest.vman")) }
        _ = try await store.put("manifest.vman", data: Data("2".utf8), ifMatch: e1)
        do { _ = try await store.put("manifest.vman", data: Data("y".utf8), ifMatch: e1); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .conflict("manifest.vman")) }
        do { _ = try await store.put("gone", data: Data(), ifMatch: "\"x\""); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .conflict("gone")) }
    }

    func testListFollowsPaginationAndStripsThePrefix() async throws {
        s3.pageSize = 2
        for i in 0..<5 { _ = try await store.put("items/\(i).vitem", data: Data("\(i)".utf8), ifMatch: nil) }
        let other = try makeStore(prefix: "other")
        _ = try await other.put("items/x.vitem", data: Data("x".utf8), ifMatch: nil)
        let list = try await store.list(prefix: "items/")
        XCTAssertEqual(Set(list.keys), Set((0..<5).map { "items/\($0).vitem" }))
    }

    func testWrongSecretIsUnauthorizedAndMissingBucketIsReported() async throws {
        let bad = try S3Store(config: S3Config(endpoint: "https://s3.test", region: s3.region, bucket: s3.bucket, accessKeyID: s3.access),
                              secretKey: "wrong", session: MockHTTPProtocol.session())
        do { _ = try await bad.get("x"); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .unauthorized) }
        let nobucket = try S3Store(config: S3Config(endpoint: "https://s3.test", region: s3.region, bucket: "nope", accessKeyID: s3.access),
                                   secretKey: s3.secret, session: MockHTTPProtocol.session())
        do { try await nobucket.verify(); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .notFound("bucket nope")) }
    }

    func testProbeAcceptsAnEnforcingServerAndRejectsALaxOne() async throws {
        let ok = try await store.probeConditionalWrites()
        XCTAssertEqual(ok, .enforced)
        XCTAssertEqual(s3.keys, [])
        s3.enforcePreconditions = false
        let lax = try await store.probeConditionalWrites()
        guard case .notEnforced = lax else { return XCTFail("\(lax)") }
    }

    func testKeysWithSpecialCharactersRoundTrip() async throws {
        _ = try await store.put("items/a b+c&d.vitem", data: Data("z".utf8), ifMatch: nil)
        let list = try await store.list(prefix: "items/")
        XCTAssertEqual(Set(list.keys), ["items/a b+c&d.vitem"])
        XCTAssertEqual(s3.badSignatures, 0)
    }

    func testTwoDevicesSyncThroughS3() async throws {
        let cheap = KDFParams(memoryKiB: 8192, iterations: 1, salt: Data(repeating: 5, count: 16))
        let pw = SecureBytes(utf8: "pw")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("s3-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try VaultStore.create(at: tmp.appendingPathComponent("A"), password: pw, kdfParams: cheap, deviceID: UUID())
        let item = ItemOverview(type: .login, title: "Bank")
        try a.save(overview: item, details: ItemDetails(fields: ["password": "p1"]))
        _ = try await SyncEngine(store: a, remote: store).sync()
        let b = try await SyncEngine.bootstrap(remote: store, into: tmp.appendingPathComponent("B"), password: pw, deviceID: UUID())
        XCTAssertEqual(try b.details(for: item.id).fields["password"], "p1")
        // Concurrent edits on both devices: the loser is merged, never overwritten.
        var ea = item; ea.title = "Bank A"
        var eb = item; eb.title = "Bank B"
        try a.save(overview: ea, details: ItemDetails(fields: ["password": "pa"]))
        try b.save(overview: eb, details: ItemDetails(fields: ["password": "pb"]))
        _ = try await SyncEngine(store: a, remote: store).sync()
        let r = try await SyncEngine(store: b, remote: store).sync()
        XCTAssertEqual(r.conflicts, 1)
        XCTAssertEqual(s3.badSignatures, 0)
    }
}
