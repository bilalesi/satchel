import Foundation
@testable import VaultCore

struct MockResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
}

/// Serves URLSession requests from an in-process handler, so HTTP backends are tested against a
/// stateful fake server without opening a socket.
final class MockHTTPProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) -> MockResponse)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        let r = Self.handler?(request, body) ?? MockResponse(status: 500)
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHTTPProtocol.self]
        return URLSession(configuration: cfg)
    }
}

/// A WebDAV server that enforces If-Match / If-None-Match like a correct one.
final class FakeWebDAV: @unchecked Sendable {
    let root = "/dav/satchel/"
    let user = "me", pass = "pw"
    private let lock = NSLock()
    private(set) var files: [String: (data: Data, etag: String)] = [:]
    private(set) var dirs: Set<String> = [""]
    private var counter = 0
    var omitPutETag = false
    var enforcePreconditions = true
    /// Like Apache mod_dav: right after a write the ETag is weak (W/"…") and fails If-Match; a moment later
    /// (here: after one refused If-Match) it is strong again.
    var apacheWeakETags = false
    private var weak: Set<String> = []
    private func shown(_ path: String) -> String? { files[path].map { weak.contains(path) ? "W/" + $0.etag : $0.etag } }
    /// Strong comparison, as If-Match requires; a weak current tag never matches, then the second passes.
    private func matches(_ path: String, _ ifMatch: String) -> Bool {
        if weak.contains(path) { weak.remove(path); return false }
        return files[path]?.etag == ifMatch
    }

    func install() {
        MockHTTPProtocol.requests = []
        MockHTTPProtocol.handler = { [self] req, body in lock.withLock { handle(req, body) } }
    }

    func seed(_ path: String, _ data: Data) { lock.withLock { files[path] = (data, nextETag()) } }
    var paths: [String] { lock.withLock { files.keys.sorted() } }
    func data(_ path: String) -> Data? { lock.withLock { files[path]?.data } }

    private func nextETag() -> String { counter += 1; return "\"e\(counter)\"" }

    private func handle(_ req: URLRequest, _ body: Data) -> MockResponse {
        let expected = "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        guard req.value(forHTTPHeaderField: "Authorization") == expected else { return MockResponse(status: 401) }
        let full = req.url!.path
        guard full.hasPrefix(root) || full + "/" == root else { return MockResponse(status: 404) }
        let rel = String(full.dropFirst(root.count))
        let dirKey = rel.hasSuffix("/") ? String(rel.dropLast()) : rel
        let ifMatch = req.value(forHTTPHeaderField: "If-Match")
        let ifNone = req.value(forHTTPHeaderField: "If-None-Match")

        switch req.httpMethod ?? "" {
        case "GET", "HEAD":
            guard let f = files[rel] else { return MockResponse(status: 404) }
            return MockResponse(status: 200, headers: ["ETag": shown(rel) ?? f.etag], body: f.data)
        case "PUT":
            let parent = (rel as NSString).deletingLastPathComponent
            guard dirs.contains(parent == "." ? "" : parent) else { return MockResponse(status: 409) }
            let current = files[rel]
            if enforcePreconditions {
                if ifNone == "*", current != nil { return MockResponse(status: 412) }
                if let ifMatch, !matches(rel, ifMatch) { return MockResponse(status: 412) }
            }
            let etag = nextETag()
            files[rel] = (body, etag)
            if apacheWeakETags { weak.insert(rel) }
            return MockResponse(status: current == nil ? 201 : 204, headers: omitPutETag ? [:] : ["ETag": shown(rel)!])
        case "DELETE":
            guard let f = files[rel] else { return MockResponse(status: 404) }
            if enforcePreconditions, let ifMatch, !matches(rel, ifMatch) { _ = f; return MockResponse(status: 412) }
            files[rel] = nil
            weak.remove(rel)
            return MockResponse(status: 204)
        case "MKCOL":
            if dirs.contains(dirKey) { return MockResponse(status: 405) }
            let parent = (dirKey as NSString).deletingLastPathComponent
            guard dirs.contains(parent == "." ? "" : parent) else { return MockResponse(status: 409) }
            dirs.insert(dirKey)
            return MockResponse(status: 201)
        case "PROPFIND":
            guard dirs.contains(dirKey) else { return MockResponse(status: 404) }
            var xml = #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">"#
            func entry(_ href: String, etag: String?, collection: Bool) {
                xml += "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>"
                xml += collection ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:resourcetype/>"
                if let etag { xml += "<d:getetag>\(etag)</d:getetag>" }
                xml += "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            }
            entry(root + (dirKey.isEmpty ? "" : dirKey + "/"), etag: nil, collection: true)
            if req.value(forHTTPHeaderField: "Depth") == "1" {
                let prefix = dirKey.isEmpty ? "" : dirKey + "/"
                for (k, f) in files where k.hasPrefix(prefix) && !k.dropFirst(prefix.count).contains("/") {
                    let encoded = k.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? k
                    entry(root + encoded, etag: shown(k) ?? f.etag, collection: false)
                }
                for d in dirs where d.hasPrefix(prefix) && d != dirKey && !d.dropFirst(prefix.count).contains("/") {
                    entry(root + d + "/", etag: nil, collection: true)
                }
            }
            xml += "</d:multistatus>"
            return MockResponse(status: 207, headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
        default:
            return MockResponse(status: 405)
        }
    }
}

/// An S3 endpoint (path-style) that verifies the SigV4 signature and enforces preconditions.
final class FakeS3: @unchecked Sendable {
    let bucket = "vault", access = "AKIATEST", secret = "s3cr3t", region = "eu-west-1"
    var pageSize = 1000
    var enforcePreconditions = true
    private let lock = NSLock()
    private(set) var objects: [String: (data: Data, etag: String)] = [:]
    private var counter = 0
    private(set) var badSignatures = 0

    func install() {
        MockHTTPProtocol.requests = []
        MockHTTPProtocol.handler = { [self] req, body in lock.withLock { handle(req, body) } }
    }

    var keys: [String] { lock.withLock { objects.keys.sorted() } }

    private func error(_ status: Int, _ code: String) -> MockResponse {
        MockResponse(status: status, body: Data("<?xml version=\"1.0\"?><Error><Code>\(code)</Code></Error>".utf8))
    }

    private func verifySignature(_ req: URLRequest, _ body: Data) -> Bool {
        guard let auth = req.value(forHTTPHeaderField: "Authorization"),
              let signedList = auth.components(separatedBy: "SignedHeaders=").last?.components(separatedBy: ",").first else { return false }
        var extra: [String: String] = [:]
        for name in signedList.split(separator: ";").map(String.init) where !["host", "x-amz-date", "x-amz-content-sha256"].contains(name) {
            extra[name] = req.value(forHTTPHeaderField: name)
        }
        guard let stamp = req.value(forHTTPHeaderField: "x-amz-date") else { return false }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let date = f.date(from: stamp), req.value(forHTTPHeaderField: "x-amz-content-sha256") == SigV4.sha256Hex(body) else { return false }
        let expected = SigV4.sign(method: req.httpMethod ?? "", url: req.url!, headers: extra, payloadHash: SigV4.sha256Hex(body), date: date,
                                  region: region, service: "s3", credentials: .init(accessKey: access, secretKey: secret))
        return expected["Authorization"] == auth
    }

    private func handle(_ req: URLRequest, _ body: Data) -> MockResponse {
        guard verifySignature(req, body) else { badSignatures += 1; return error(403, "SignatureDoesNotMatch") }
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let path = comps.path
        guard path == "/\(bucket)" || path.hasPrefix("/\(bucket)/") else { return error(404, "NoSuchBucket") }
        let key = String(path.dropFirst(bucket.count + 2)).removingPercentEncoding ?? ""
        let ifMatch = req.value(forHTTPHeaderField: "If-Match")
        let ifNone = req.value(forHTTPHeaderField: "If-None-Match")

        switch req.httpMethod ?? "" {
        case "GET" where key.isEmpty:
            let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let prefix = q["prefix"] ?? ""
            let all = objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
            let start = q["continuation-token"].flatMap { t in all.firstIndex { $0 > t } } ?? 0
            let slice = Array(all[start...].prefix(min(pageSize, Int(q["max-keys"] ?? "") ?? pageSize)))
            let truncated = start + slice.count < all.count
            var xml = #"<?xml version="1.0"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
            xml += "<IsTruncated>\(truncated)</IsTruncated>"
            if truncated, let last = slice.last { xml += "<NextContinuationToken>\(last)</NextContinuationToken>" }
            for k in slice { xml += "<Contents><Key>\(k.replacingOccurrences(of: "&", with: "&amp;"))</Key><ETag>\(objects[k]!.etag.replacingOccurrences(of: "\"", with: "&quot;"))</ETag></Contents>" }
            xml += "</ListBucketResult>"
            return MockResponse(status: 200, body: Data(xml.utf8))
        case "GET":
            guard let o = objects[key] else { return error(404, "NoSuchKey") }
            return MockResponse(status: 200, headers: ["ETag": o.etag], body: o.data)
        case "PUT":
            let current = objects[key]
            if enforcePreconditions {
                if ifNone == "*", current != nil { return error(412, "PreconditionFailed") }
                if let ifMatch {
                    guard let current else { return error(404, "NoSuchKey") }
                    if current.etag != ifMatch { return error(412, "PreconditionFailed") }
                }
            }
            counter += 1
            let etag = "\"s3-\(counter)\""
            objects[key] = (body, etag)
            return MockResponse(status: 200, headers: ["ETag": etag])
        case "DELETE":
            objects[key] = nil
            return MockResponse(status: 204)
        default:
            return error(405, "MethodNotAllowed")
        }
    }
}
