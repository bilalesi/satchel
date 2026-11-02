import Foundation
import os

/// The session the HTTP backends use by default: no disk cache (a stale cached manifest would be
/// served without asking the server), no cookies, and a ceiling on total time per request.
public enum SyncNetwork {
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 180
        return URLSession(configuration: c)
    }()
}

/// Thin URLSession wrapper shared by the HTTP backends: maps transport errors to
/// `SyncError.network`, never follows redirects (a redirect could carry credentials to another
/// host), and logs method, path and status only. No headers and no bodies reach the log.
struct HTTPClient: Sendable {
    let session: URLSession
    let log: Logger

    init(session: URLSession, category: String) {
        self.session = session
        self.log = Logger(subsystem: AppIdentity.bundleID, category: category)
    }

    /// A response body larger than this is refused: vault objects are kilobytes, and a hostile
    /// server could otherwise stream until memory runs out.
    static let maxBodyBytes = 64 * 1024 * 1024

    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let what = "\(req.httpMethod ?? "?") \(req.url?.path ?? "?")"
        do {
            let (stream, resp) = try await session.bytes(for: req, delegate: NoRedirects.shared)
            guard let http = resp as? HTTPURLResponse else { throw SyncError.network("not an HTTP response") }
            guard resp.expectedContentLength <= Int64(Self.maxBodyBytes) else { throw SyncError.remote(status: http.statusCode, message: "response too large") }
            var data = Data()
            if resp.expectedContentLength > 0 { data.reserveCapacity(Int(resp.expectedContentLength)) }
            for try await byte in stream {
                data.append(byte)
                if data.count > Self.maxBodyBytes { throw SyncError.remote(status: http.statusCode, message: "response too large") }
            }
            if http.statusCode >= 400 { log.error("\(what, privacy: .public) → \(http.statusCode)") }
            else { log.info("\(what, privacy: .public) → \(http.statusCode)") }
            return (data, http)
        } catch let e as SyncError {
            throw e
        } catch {
            log.error("\(what, privacy: .public) → network error \(error.localizedDescription, privacy: .public)")
            throw SyncError.network(error.localizedDescription)
        }
    }

    /// Credentials are sent in Basic or signed headers, so they may only go over TLS, or to this
    /// machine (a local server, a test). Called when a backend is created.
    static func requireSecure(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw SyncError.remote(status: 0, message: "The address is not a valid URL.")
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw SyncError.remote(status: 0, message: "The address must start with https:// (plain http is only accepted for localhost).")
        }
    }

    /// Percent-encodes a path segment by segment; "/" stays a separator.
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
