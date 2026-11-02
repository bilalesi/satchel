import Foundation

/// WebDAV as a `RemoteStore` (Nextcloud, ownCloud, Synology, a NAS, any `mod_dav`).
/// Compare-and-swap uses `If-Match` and `If-None-Match: *` (RFC 4918 / 7232). The sync engine
/// depends on the server enforcing them, which `probeConditionalWrites()` checks at setup.
public final class WebDAVStore: RemoteStore {
    public let baseURL: URL
    private let username: String
    private let password: String
    private let http: HTTPClient

    public var displayName: String { "WebDAV " + (baseURL.host ?? baseURL.absoluteString) }

    public init(baseURL: URL, username: String, password: String, session: URLSession = .shared) throws {
        try HTTPClient.requireSecure(baseURL)
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.http = HTTPClient(session: session, category: "webdav")
    }

    // MARK: RemoteStore

    public func get(_ path: String) async throws -> RemoteObject? {
        let (data, resp) = try await http.send(request("GET", path))
        switch resp.statusCode {
        case 404: return nil
        case 200:
            guard let etag = resp.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else { throw Self.noETags }
            return RemoteObject(data: data, etag: etag)
        default: throw fail(resp.statusCode, path)
        }
    }

    public func put(_ path: String, data: Data, ifMatch: String?) async throws -> String {
        func attempt() async throws -> HTTPURLResponse {
            var req = request("PUT", path)
            req.httpBody = data
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if let ifMatch { req.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
            else { req.setValue("*", forHTTPHeaderField: "If-None-Match") }
            return try await http.send(req).1
        }
        var resp = try await attempt()
        if resp.statusCode == 409 { // a parent collection is missing
            try await makeParents(of: path)
            resp = try await attempt()
        }
        switch resp.statusCode {
        case 200, 201, 204:
            if let etag = resp.value(forHTTPHeaderField: "ETag"), !etag.isEmpty { return etag }
            // Some servers do not return the new ETag on PUT.
            let (_, head) = try await http.send(request("HEAD", path))
            guard head.statusCode == 200, let etag = head.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else { throw Self.noETags }
            return etag
        case 412, 409: throw SyncError.conflict(path)
        case 404 where ifMatch != nil: throw SyncError.conflict(path)
        default: throw fail(resp.statusCode, path)
        }
    }

    public func list(prefix: String) async throws -> [String: String] {
        var req = request("PROPFIND", prefix)
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:resourcetype/></d:prop></d:propfind>"#.utf8)
        let (data, resp) = try await http.send(req)
        switch resp.statusCode {
        case 404: return [:]
        case 207: break
        default: throw fail(resp.statusCode, prefix)
        }
        let entries = try DAVMultistatus.parse(data)
        var out: [String: String] = [:]
        for entry in entries where !entry.isCollection {
            let name = entry.href.removingPercentEncoding.map { ($0 as NSString).lastPathComponent } ?? ""
            guard !name.isEmpty else { continue }
            guard let etag = entry.etag, !etag.isEmpty else { throw Self.noETags }
            out[prefix + name] = etag
        }
        return out
    }

    public func delete(_ path: String, ifMatch: String?) async throws {
        var req = request("DELETE", path)
        if let ifMatch { req.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let (_, resp) = try await http.send(req)
        switch resp.statusCode {
        case 200, 202, 204, 404: return
        case 412: throw SyncError.conflict(path)
        default: throw fail(resp.statusCode, path)
        }
    }

    /// Checks the credentials and that the folder exists, creating it when it does not.
    public func verify() async throws {
        var req = request("PROPFIND", "")
        req.setValue("0", forHTTPHeaderField: "Depth")
        let (_, resp) = try await http.send(req)
        switch resp.statusCode {
        case 200, 207: return
        case 404:
            let (_, made) = try await http.send(request("MKCOL", ""))
            guard made.statusCode == 201 else { throw fail(made.statusCode, "") }
        default: throw fail(resp.statusCode, "")
        }
    }

    // MARK: Helpers

    private static let noETags = SyncError.remote(status: 0, message: "This server does not return ETags, which Satchel needs to sync safely. Pick a different server or another sync method.")

    private func request(_ method: String, _ path: String) -> URLRequest {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        let encoded = HTTPClient.encodePath(path)
        var s = encoded.isEmpty ? base + "/" : base + "/" + encoded
        if path.hasSuffix("/"), !s.hasSuffix("/") { s += "/" } // collections
        var r = URLRequest(url: URL(string: s)!)
        r.httpMethod = method
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(AppIdentity.name, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 30
        return r
    }

    private func makeParents(of path: String) async throws {
        var built = ""
        for part in path.split(separator: "/").dropLast() {
            built += part + "/"
            let (_, resp) = try await http.send(request("MKCOL", built))
            // 201 created, 405 already exists
            guard resp.statusCode == 201 || resp.statusCode == 405 else { throw fail(resp.statusCode, built) }
        }
    }

    private func fail(_ status: Int, _ path: String) -> SyncError {
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .notFound(path)
        default: return .remote(status: status, message: "unexpected response for \(path.isEmpty ? "the folder" : path)")
        }
    }
}

/// Parses a WebDAV 207 multistatus body.
enum DAVMultistatus {
    struct Entry { var href = ""; var etag: String?; var isCollection = false }

    static func parse(_ data: Data) throws -> [Entry] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { throw SyncError.remote(status: 207, message: "the server's listing is not valid XML") }
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            guard namespaceURI == "DAV:" else { return }
            if name == "response" { current = Entry() }
            if name == "collection" { current?.isCollection = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard namespaceURI == "DAV:" else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href": if current?.href.isEmpty == true { current?.href = value }
            case "getetag": current?.etag = value
            case "response": if let c = current { entries.append(c) }; current = nil
            default: break
            }
        }
    }
}
