import Foundation
import CryptoKit

/// A dotted numeric version such as "0.1.27" (a leading "v" is ignored).
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !pieces.isEmpty, pieces.allSatisfy({ $0 != nil && $0! >= 0 }), pieces.count <= 4 else { return nil }
        parts = pieces.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A newer release that can be installed.
public struct UpdateOffer: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let dmgURL: URL
    public let size: Int
    /// Lower-case hex SHA-256 of the DMG, checked after the download and again right before install.
    public let sha256: String
    /// Base64 Ed25519 signature over the DMG bytes, made with the update key (not the licence key).
    public let signature: String
    /// When the release was published; compared with a licence's update window. Nil when the feed omits it.
    public var published: Date? = nil
}

/// Reads the update feed, `GET https://satchel.echospace.dev/api/update` (404 = no release yet):
/// `{"version","url","size","sha256","signature","notes","published"}`. Only a newer version whose DMG is
/// served by satchel.echospace.dev over https, with a well-formed digest and signature, becomes an offer.
public enum UpdateFeed {
    public static let url = URL(string: "https://satchel.echospace.dev/api/update")!
    public static let maxDownloadBytes = 250 * 1024 * 1024
    /// The only host the feed and the download may come from (redirects included).
    public static let allowedHost = "satchel.echospace.dev"

    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == allowedHost && url.port == nil
    }

    /// `allowLocal` is for tests and development builds that serve a feed from this machine.
    public static func parse(_ json: Data, current: AppVersion, allowLocal: Bool = false) -> UpdateOffer? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let v = obj["version"] as? String, let version = AppVersion(v), version > current,
              let link = obj["url"] as? String, let dmg = URL(string: link),
              let size = obj["size"] as? Int, size > 0, size <= maxDownloadBytes,
              let sha = (obj["sha256"] as? String)?.lowercased(), sha.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) }),
              let signature = obj["signature"] as? String, Data(base64Encoded: signature)?.count == 64 else { return nil }
        let local = allowLocal && ["localhost", "127.0.0.1"].contains(dmg.host ?? "")
        guard local || (isAllowedDownloadURL(dmg) && dmg.path == "/download/Satchel-\(version).dmg") else { return nil }
        return UpdateOffer(version: version, notes: String((obj["notes"] as? String ?? "").prefix(4000)), dmgURL: dmg,
                           size: size, sha256: sha, signature: signature,
                           published: (obj["published"] as? String).flatMap(date))
    }

    /// ISO 8601, with or without fractional seconds (`2026-11-03T10:00:00Z`, JavaScript's `…:00.000Z`).
    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: text)
    }
}

public enum UpdateSignature {
    /// Ed25519 over the exact bytes of the file; keys and signature are base64.
    public static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        guard let key = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return pub.isValidSignature(sig, for: data)
    }
}
