import XCTest
@testable import VaultCore

/// Records every request and answers from a queue of canned responses.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class GitHubStoreTests: XCTestCase {
    var store: GitHubStore!

    override func setUp() {
        StubURLProtocol.requests = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        store = GitHubStore(repo: GitHubRepo(owner: "me", name: "secrets", branch: "main", prefix: "vault"),
                            token: "ghp_test", session: URLSession(configuration: cfg))
    }

    func json(_ s: String) -> Data { Data(s.utf8) }

    func body(of req: URLRequest) -> [String: Any] {
        var data = req.httpBody
        if data == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            var out = Data()
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
            data = out
        }
        return (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]) ?? [:]
    }

    func testGetParsesShaAndBase64AndSendsHeaders() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(#"{"sha":"abc123","encoding":"base64","content":"aGVs\nbG8=\n"}"#)) }
        let obj = try await store.get("manifest.vman")
        XCTAssertEqual(obj, RemoteObject(data: Data("hello".utf8), etag: "abc123"))
        let req = StubURLProtocol.requests[0]
        XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/me/secrets/contents/vault/manifest.vman?ref=main")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testAbsentIs404Nil() async throws {
        StubURLProtocol.handler = { _ in (404, self.json(#"{"message":"Not Found"}"#)) }
        let obj = try await store.get("vault.vhdr")
        XCTAssertNil(obj)
        let listed = try await store.list(prefix: "items/")
        XCTAssertEqual(listed, [:])
    }

    func testPutSendsShaBranchAndParsesNewSha() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(#"{"content":{"sha":"new1"},"commit":{"sha":"c"}}"#)) }
        let etag = try await store.put("items/x.vitem", data: Data([1, 2, 3]), ifMatch: "old1")
        XCTAssertEqual(etag, "new1")
        let req = StubURLProtocol.requests[0]
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/me/secrets/contents/vault/items/x.vitem")
        let b = body(of: req)
        XCTAssertEqual(b["sha"] as? String, "old1")
        XCTAssertEqual(b["branch"] as? String, "main")
        XCTAssertEqual(b["content"] as? String, Data([1, 2, 3]).base64EncodedString())

        StubURLProtocol.handler = { _ in (201, self.json(#"{"content":{"sha":"created"}}"#)) }
        _ = try await store.put("items/y.vitem", data: Data([9]), ifMatch: nil)
        XCTAssertNil(body(of: StubURLProtocol.requests[1])["sha"])
    }

    func testConflictMappings() async {
        for (status, msg) in [(409, "is at abc but expected def"), (422, "sha wasn't supplied"), (422, "sha does not match")] {
            StubURLProtocol.handler = { _ in (status, self.json(#"{"message":"\#(msg)"}"#)) }
            do { _ = try await store.put("items/x.vitem", data: Data(), ifMatch: "e"); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? SyncError, .conflict("items/x.vitem"), "\(status) \(msg)") }
        }
        // 404 with a sha means the object vanished: also a conflict.
        StubURLProtocol.handler = { _ in (404, self.json(#"{"message":"Not Found"}"#)) }
        do { _ = try await store.put("items/x.vitem", data: Data(), ifMatch: "e"); XCTFail() }
        catch { XCTAssertEqual(error as? SyncError, .conflict("items/x.vitem")) }
        // A 422 unrelated to sha is a plain remote error.
        StubURLProtocol.handler = { _ in (422, self.json(#"{"message":"Invalid request"}"#)) }
        do { _ = try await store.put("items/x.vitem", data: Data(), ifMatch: nil); XCTFail() }
        catch { XCTAssertEqual(error as? SyncError, .remote(status: 422, message: "Invalid request")) }
    }

    func testUnauthorizedAndNetwork() async {
        StubURLProtocol.handler = { _ in (401, self.json(#"{"message":"Bad credentials"}"#)) }
        do { _ = try await store.get("manifest.vman"); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .unauthorized) }
        StubURLProtocol.handler = { _ in (403, self.json(#"{"message":"Resource not accessible by personal access token"}"#)) }
        do { _ = try await store.verify(); XCTFail() } catch { XCTAssertEqual(error as? SyncError, .unauthorized) }
        StubURLProtocol.handler = { _ in (403, self.json(#"{"message":"API rate limit exceeded"}"#)) }
        do { _ = try await store.get("x"); XCTFail() } catch {
            XCTAssertEqual(error as? SyncError, .remote(status: 403, message: "API rate limit exceeded"))
        }
    }

    func testListMapsFilesToShas() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(#"[{"name":"a.vitem","sha":"s1","type":"file"},{"name":"sub","sha":"s2","type":"dir"},{"name":"b.vitem","sha":"s3","type":"file"}]"#)) }
        let listed = try await store.list(prefix: "items/")
        XCTAssertEqual(listed, ["items/a.vitem": "s1", "items/b.vitem": "s3"])
        XCTAssertEqual(StubURLProtocol.requests[0].url?.absoluteString, "https://api.github.com/repos/me/secrets/contents/vault/items?ref=main")
    }

    func testTruncatedListingIsAnError() async {
        let entries = (0..<1000).map { #"{"name":"\#($0).vitem","sha":"s","type":"file"}"# }.joined(separator: ",")
        StubURLProtocol.handler = { _ in (200, self.json("[" + entries + "]")) }
        do { _ = try await store.list(prefix: "items/"); XCTFail() } catch {
            guard case .remote(let status, let message)? = error as? SyncError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 200)
            XCTAssertTrue(message.contains("truncated"))
        }
    }

    func testVerifyReturnsFullName() async throws {
        StubURLProtocol.handler = { _ in (200, self.json(#"{"full_name":"me/secrets","private":true}"#)) }
        let name = try await store.verify()
        XCTAssertEqual(name, "me/secrets")
        XCTAssertEqual(StubURLProtocol.requests[0].url?.absoluteString, "https://api.github.com/repos/me/secrets")
    }

    func testRepoNormalisation() {
        let r = GitHubRepo(owner: " me ", name: "secrets", branch: "", prefix: "/vault/")
        XCTAssertEqual(r.owner, "me")
        XCTAssertEqual(r.branch, "main")
        XCTAssertEqual(r.prefix, "vault/")
        XCTAssertEqual(GitHubRepo(owner: "a", name: "b").prefix, "")
    }

    func testKeychainRoundTripIfEnabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VAULT_KEYCHAIN_TEST"] == "1", "touches the login keychain")
        let service = "com.bilalesi.vault.test.\(UUID().uuidString)"
        XCTAssertNil(KeychainToken.load(service: service))
        try KeychainToken.save("one", service: service)
        XCTAssertEqual(KeychainToken.load(service: service), "one")
        try KeychainToken.save("two", service: service)
        XCTAssertEqual(KeychainToken.load(service: service), "two")
        KeychainToken.delete(service: service)
        XCTAssertNil(KeychainToken.load(service: service))
    }
}
