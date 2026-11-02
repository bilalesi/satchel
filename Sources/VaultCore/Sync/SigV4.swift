import Foundation
import CryptoKit

/// AWS Signature Version 4 (header form), enough for S3-compatible object stores.
enum SigV4 {
    struct Credentials { var accessKey: String; var secretKey: String }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// RFC 3986 unreserved characters stay, everything else is %XX. `keepSlash` for paths.
    static func encode(_ s: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// Returns the headers to add to the request (`Authorization`, `x-amz-date`,
    /// `x-amz-content-sha256`). `headers` are extra headers the caller sends and wants signed.
    static func sign(method: String, url: URL, headers: [String: String], payloadHash: String,
                     date: Date, region: String, service: String, credentials: Credentials) -> [String: String] {
        let stamp = amzDate(date)
        let day = String(stamp.prefix(8))

        var all = headers
        all["host"] = hostHeader(url)
        all["x-amz-content-sha256"] = payloadHash
        all["x-amz-date"] = stamp
        var sorted: [(String, String)] = []
        for (k, v) in all { sorted.append((k.lowercased(), v.trimmingCharacters(in: .whitespaces))) }
        sorted.sort { $0.0 < $1.0 }
        var canonicalHeaders = ""
        for (k, v) in sorted { canonicalHeaders += "\(k):\(v)\n" }
        let signedHeaders = sorted.map { $0.0 }.joined(separator: ";")

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawPath = comps?.percentEncodedPath ?? "/"
        // S3: the path is encoded exactly once. Decode what URL percent-encoded, then encode strictly.
        let canonicalPath = encode(rawPath.removingPercentEncoding ?? rawPath, keepSlash: true)
        var query: [(String, String)] = []
        for pair in (comps?.percentEncodedQuery ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = String(kv[0])
            let rawValue: String = kv.count > 1 ? String(kv[1]) : ""
            query.append((encode(rawKey.removingPercentEncoding ?? rawKey, keepSlash: false),
                          encode(rawValue.removingPercentEncoding ?? rawValue, keepSlash: false)))
        }
        query.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let canonicalQuery = query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let path: String = canonicalPath.isEmpty ? "/" : canonicalPath
        let canonicalParts: [String] = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
        let canonical = canonicalParts.joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSignParts: [String] = ["AWS4-HMAC-SHA256", stamp, scope, sha256Hex(Data(canonical.utf8))]
        let toSign = toSignParts.joined(separator: "\n")

        var key = hmac(Data("AWS4\(credentials.secretKey)".utf8), day)
        key = hmac(key, region); key = hmac(key, service); key = hmac(key, "aws4_request")
        let signature = hmac(key, toSign).map { String(format: "%02x", $0) }.joined()

        return [
            "Authorization": "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            "x-amz-date": stamp,
            "x-amz-content-sha256": payloadHash,
        ]
    }

    private static func hostHeader(_ url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) { return "\(host):\(port)" }
        return host
    }
}
