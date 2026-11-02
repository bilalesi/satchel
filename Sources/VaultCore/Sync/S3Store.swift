import Foundation

public struct S3Config: Codable, Equatable, Sendable {
    /// e.g. https://s3.eu-west-1.amazonaws.com, https://<account>.r2.cloudflarestorage.com, http://localhost:9000
    public var endpoint: String
    public var region: String
    public var bucket: String
    /// Folder inside the bucket, "" for the root. Normalised to end with "/".
    public var prefix: String
    public var accessKeyID: String

    public init(endpoint: String, region: String, bucket: String, prefix: String = "", accessKeyID: String) {
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region.trimmingCharacters(in: .whitespaces).isEmpty ? "us-east-1" : region.trimmingCharacters(in: .whitespaces)
        self.bucket = bucket.trimmingCharacters(in: .whitespaces)
        var p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !p.isEmpty { p += "/" }
        self.prefix = p
        self.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespaces)
    }
}

/// S3-compatible object storage (AWS S3, Cloudflare R2, MinIO, Backblaze B2, Wasabi).
/// Path-style addressing. Compare-and-swap uses `If-Match` / `If-None-Match: *` on PutObject,
/// which not every provider enforces: `probeConditionalWrites()` is run before a bucket is used.
public final class S3Store: RemoteStore {
    public let config: S3Config
    private let endpoint: URL
    private let credentials: SigV4.Credentials
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public var displayName: String { "S3 \(config.bucket)" }

    public init(config: S3Config, secretKey: String, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let url = URL(string: config.endpoint), !config.bucket.isEmpty, !config.accessKeyID.isEmpty, !secretKey.isEmpty else {
            throw SyncError.notConfigured
        }
        try HTTPClient.requireSecure(url)
        self.config = config
        self.endpoint = url
        self.credentials = SigV4.Credentials(accessKey: config.accessKeyID, secretKey: secretKey)
        self.http = HTTPClient(session: session, category: "s3")
        self.now = now
    }

    // MARK: RemoteStore

    public func get(_ path: String) async throws -> RemoteObject? {
        let (data, resp) = try await send("GET", key(path))
        switch resp.statusCode {
        case 404: return nil
        case 200:
            guard let etag = resp.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else { throw Self.noETags }
            return RemoteObject(data: data, etag: etag)
        default: throw fail(resp, data, path)
        }
    }

    public func put(_ path: String, data: Data, ifMatch: String?) async throws -> String {
        var headers: [String: String] = [:]
        if let ifMatch { headers["If-Match"] = ifMatch } else { headers["If-None-Match"] = "*" }
        let (body, resp) = try await send("PUT", key(path), headers: headers, body: data)
        switch resp.statusCode {
        case 200, 201:
            guard let etag = resp.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else { throw Self.noETags }
            return etag
        case 412, 409: throw SyncError.conflict(path)
        case 404 where ifMatch != nil && Self.code(body) == "NoSuchKey": throw SyncError.conflict(path)
        default: throw fail(resp, body, path)
        }
    }

    public func list(prefix: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", config.prefix + prefix)]
            if let token { query.append(("continuation-token", token)) }
            let (data, resp) = try await send("GET", "", query: query)
            guard resp.statusCode == 200 else { throw fail(resp, data, prefix) }
            let page = try S3ListParser.parse(data)
            for (k, etag) in page.objects where k.hasPrefix(config.prefix) {
                out[String(k.dropFirst(config.prefix.count))] = etag
            }
            token = page.truncated ? page.nextToken : nil
        } while token != nil
        return out
    }

    /// Not atomic against concurrent writers (S3 only offers conditional deletes on some
    /// storage classes); the engine never deletes shared objects, only the probe does.
    public func delete(_ path: String, ifMatch: String?) async throws {
        if let ifMatch, let current = try await get(path), current.etag != ifMatch { throw SyncError.conflict(path) }
        let (data, resp) = try await send("DELETE", key(path))
        guard [200, 204, 404].contains(resp.statusCode) else { throw fail(resp, data, path) }
    }

    /// Checks credentials, region and bucket.
    public func verify() async throws {
        let (data, resp) = try await send("GET", "", query: [("list-type", "2"), ("max-keys", "1")])
        switch resp.statusCode {
        case 200: return
        case 404 where Self.code(data) == "NoSuchBucket": throw SyncError.notFound("bucket \(config.bucket)")
        default: throw fail(resp, data, "the bucket")
        }
    }

    // MARK: Helpers

    private static let noETags = SyncError.remote(status: 0, message: "This server does not return ETags, which Satchel needs to sync safely.")

    private func key(_ path: String) -> String { config.prefix + path }

    /// `key == ""` addresses the bucket itself (listing).
    private func send(_ method: String, _ key: String, query: [(String, String)] = [],
                      headers: [String: String] = [:], body: Data = Data()) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let base = comps.percentEncodedPath.hasSuffix("/") ? String(comps.percentEncodedPath.dropLast()) : comps.percentEncodedPath
        comps.percentEncodedPath = base + "/" + SigV4.encode(config.bucket, keepSlash: false)
            + (key.isEmpty ? "" : "/" + key.split(separator: "/", omittingEmptySubsequences: false).map { SigV4.encode(String($0), keepSlash: false) }.joined(separator: "/"))
        if !query.isEmpty {
            comps.percentEncodedQuery = query.map { "\(SigV4.encode($0.0, keepSlash: false))=\(SigV4.encode($0.1, keepSlash: false))" }.joined(separator: "&")
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.httpBody = body.isEmpty ? nil : body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(AppIdentity.name, forHTTPHeaderField: "User-Agent")
        let signed = SigV4.sign(method: method, url: req.url!, headers: headers, payloadHash: SigV4.sha256Hex(body),
                                date: now(), region: config.region, service: "s3", credentials: credentials)
        for (k, v) in signed { req.setValue(v, forHTTPHeaderField: k) }
        return try await http.send(req)
    }

    private func fail(_ resp: HTTPURLResponse, _ data: Data, _ path: String) -> SyncError {
        switch (resp.statusCode, Self.code(data)) {
        case (401, _), (403, _): return .unauthorized
        case (404, "NoSuchBucket"): return .notFound("bucket \(config.bucket)")
        case (404, _): return .notFound(path)
        case (_, let code): return .remote(status: resp.statusCode, message: code.isEmpty ? "unexpected response" : code)
        }
    }

    /// S3 error body: `<Error><Code>NoSuchKey</Code>…`.
    static func code(_ data: Data) -> String {
        guard let s = String(data: data, encoding: .utf8), let a = s.range(of: "<Code>"), let b = s.range(of: "</Code>"), a.upperBound <= b.lowerBound else { return "" }
        return String(s[a.upperBound..<b.lowerBound])
    }
}

enum S3ListParser {
    struct Page { var objects: [(String, String)] = []; var truncated = false; var nextToken: String? }

    static func parse(_ data: Data) throws -> Page {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let d = Delegate()
        parser.delegate = d
        guard parser.parse() else { throw SyncError.remote(status: 200, message: "the bucket listing is not valid XML") }
        return d.page
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var page = Page()
        private var path: [String] = []
        private var text = ""
        private var key = ""
        private var etag = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            path.append(name); text = ""
            if name == "Contents" { key = ""; etag = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            switch name {
            case "Key" where path.dropLast().last == "Contents": key = text
            case "ETag" where path.dropLast().last == "Contents": etag = text
            case "Contents": if !key.isEmpty { page.objects.append((key, etag)) }
            case "IsTruncated": page.truncated = text == "true"
            case "NextContinuationToken": page.nextToken = text
            default: break
            }
        }
    }
}
