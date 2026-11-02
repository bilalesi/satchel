import Foundation
import os

public struct GitHubRepo: Codable, Equatable, Hashable, Sendable {
    public var owner: String
    public var name: String
    public var branch: String
    /// Directory inside the repo, "" for the root. Normalised to end with "/" when set.
    public var prefix: String

    public init(owner: String, name: String, branch: String = "main", prefix: String = "") {
        self.owner = owner.trimmingCharacters(in: .whitespaces)
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.branch = branch.isEmpty ? "main" : branch
        var p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !p.isEmpty { p += "/" }
        self.prefix = p
    }

    public var fullName: String { "\(owner)/\(name)" }
}

/// GitHub Contents API as a `RemoteStore`. The blob `sha` GitHub returns is exactly
/// `GitBlob.sha(content)`, so it doubles as the etag. One commit per object write; GitHub
/// requires these calls to be serial, which the engine already guarantees.
public final class GitHubStore: RemoteStore {
    public let repo: GitHubRepo
    private let token: String
    private let session: URLSession
    private let api = URL(string: "https://api.github.com")!

    public var displayName: String { "GitHub " + repo.fullName }

    public init(repo: GitHubRepo, token: String, session: URLSession = SyncNetwork.session) {
        self.repo = repo
        self.token = token
        self.session = session
    }

    // MARK: RemoteStore

    public func get(_ path: String) async throws -> RemoteObject? {
        let (data, status) = try await send(request("GET", contentsURL(path, ref: true)))
        if status == 404 { return nil }
        try check(status, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = obj["sha"] as? String else {
            throw SyncError.remote(status: status, message: "unexpected contents response")
        }
        // Contents API inlines base64 only up to 1 MB; vault objects are kilobytes.
        guard let b64 = obj["content"] as? String,
              let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            throw SyncError.remote(status: status, message: "object too large for the contents API")
        }
        // End-to-end integrity: the bytes must hash to the blob id GitHub reports.
        // Measured 2026-11-02: the contents API re-encodes files it sniffs as text (the
        // manifest is JSON followed by a binary MAC), expanding bytes >= 0x80 to UTF-8.
        // The git blob API returns the stored bytes exactly, so fall back to it.
        if GitBlob.sha(bytes) == sha { return RemoteObject(data: bytes, etag: sha) }
        let exact = try await blob(sha)
        guard GitBlob.sha(exact) == sha else {
            throw SyncError.remote(status: status, message: "\(path) failed its integrity check on download")
        }
        return RemoteObject(data: exact, etag: sha)
    }

    /// Exact stored bytes of a blob by id.
    private func blob(_ sha: String) async throws -> Data {
        let url = api.appendingPathComponent("repos/\(repo.owner)/\(repo.name)/git/blobs/\(sha)")
        let (data, status) = try await send(request("GET", url))
        try check(status, data)
        guard status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["content"] as? String,
              let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            throw SyncError.remote(status: status, message: "blob \(sha) unavailable")
        }
        return bytes
    }

    public func put(_ path: String, data: Data, ifMatch: String?) async throws -> String {
        var body: [String: Any] = [
            "message": "vault: \(path)",
            "content": data.base64EncodedString(),
            "branch": repo.branch,
        ]
        if let ifMatch { body["sha"] = ifMatch }
        var req = request("PUT", contentsURL(path, ref: false))
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (resp, status) = try await send(req)
        switch status {
        case 200, 201:
            guard let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
                  let content = obj["content"] as? [String: Any], let sha = content["sha"] as? String else {
                throw SyncError.remote(status: status, message: "missing sha in response")
            }
            return sha
        case 409:
            throw SyncError.conflict(path)
        case 422 where message(resp).lowercased().contains("sha"):
            // "sha wasn't supplied" (exists, create-only) or "does not match" (stale).
            throw SyncError.conflict(path)
        case 404 where ifMatch != nil:
            throw SyncError.conflict(path) // deleted underneath us
        default:
            try check(status, resp)
            throw SyncError.remote(status: status, message: message(resp))
        }
    }

    public func list(prefix: String) async throws -> [String: String] {
        let dir = String(prefix.dropLast(prefix.hasSuffix("/") ? 1 : 0))
        let (data, status) = try await send(request("GET", contentsURL(dir, ref: true)))
        if status == 404 { return [:] }
        try check(status, data)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SyncError.remote(status: status, message: "\(dir) is not a directory")
        }
        // The Contents API silently caps a directory listing at 1,000 entries; a partial list
        // would make the engine treat existing items as new and loop on conflicts.
        guard arr.count < 1000 else {
            throw SyncError.remote(status: status, message: "\(dir) has 1,000 or more files; the GitHub contents listing is truncated. Split items into a prefix per vault or move to the Git trees API.")
        }
        var out: [String: String] = [:]
        for entry in arr {
            guard entry["type"] as? String == "file", let name = entry["name"] as? String,
                  let sha = entry["sha"] as? String else { continue }
            out[prefix + name] = sha
        }
        return out
    }

    public func delete(_ path: String, ifMatch: String?) async throws {
        var sha = ifMatch
        if sha == nil {
            guard let current = try await get(path) else { return }
            sha = current.etag
        }
        var req = request("DELETE", contentsURL(path, ref: false))
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": "vault: remove \(path)", "sha": sha!, "branch": repo.branch,
        ])
        let (resp, status) = try await send(req)
        switch status {
        case 200: return
        case 404: return // already gone
        case 409, 422: throw SyncError.conflict(path)
        default:
            try check(status, resp)
            throw SyncError.remote(status: status, message: message(resp))
        }
    }

    /// Checks the token can see the repository. Returns its full name.
    public func verify() async throws -> String {
        let url = api.appendingPathComponent("repos/\(repo.owner)/\(repo.name)")
        let (data, status) = try await send(request("GET", url))
        if status == 404 { throw SyncError.notFound(repo.fullName) }
        try check(status, data)
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["full_name"] as? String ?? repo.fullName
    }

    // MARK: HTTP

    private func contentsURL(_ path: String, ref: Bool) -> URL {
        var comps = URLComponents(url: api, resolvingAgainstBaseURL: false)!
        let encoded = (repo.prefix + path).split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        comps.percentEncodedPath = "/repos/\(repo.owner)/\(repo.name)/contents/\(encoded)"
        if ref { comps.queryItems = [URLQueryItem(name: "ref", value: repo.branch)] }
        return comps.url!
    }

    private func request(_ method: String, _ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue(AppIdentity.name, forHTTPHeaderField: "User-Agent")
        if method == "PUT" { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.timeoutInterval = 30
        return r
    }

    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "github")

    /// Logs method, path and status only: never the token, never bodies.
    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        let what = "\(req.httpMethod ?? "?") \(req.url?.path ?? "?")"
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                Self.log.error("\(what, privacy: .public) → \(status) \(self.message(data), privacy: .public)")
            } else {
                Self.log.info("\(what, privacy: .public) → \(status)")
            }
            return (data, status)
        } catch {
            Self.log.error("\(what, privacy: .public) → network error \(error.localizedDescription, privacy: .public)")
            throw SyncError.network(error.localizedDescription)
        }
    }

    private func check(_ status: Int, _ data: Data) throws {
        switch status {
        case 200..<300, 404: return
        case 401: throw SyncError.unauthorized
        case 403 where !message(data).lowercased().contains("rate limit"): throw SyncError.unauthorized
        default: throw SyncError.remote(status: status, message: message(data))
        }
    }

    private func message(_ data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String) ?? ""
    }
}
