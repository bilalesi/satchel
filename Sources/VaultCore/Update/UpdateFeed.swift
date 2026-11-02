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
    public let pageURL: URL
    public let dmgURL: URL
    public let signatureURL: URL
    public let size: Int
}

/// Reads GitHub's "latest release" JSON. Only a release for a newer version, with a DMG and a
/// matching signature file hosted by github.com, becomes an offer; anything else is ignored.
public enum UpdateFeed {
    public static let maxDownloadBytes = 250 * 1024 * 1024
    /// Hosts a release asset may be served from (GitHub redirects downloads to its CDN).
    public static let allowedHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && (url.host.map { allowedHosts.contains($0.lowercased()) } ?? false)
    }

    /// `allowLocal` is for tests and development builds that serve a feed from this machine.
    public static func parse(_ json: Data, current: AppVersion, repository: String, allowLocal: Bool = false) -> UpdateOffer? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              obj["draft"] as? Bool != true, obj["prerelease"] as? Bool != true,
              let tag = obj["tag_name"] as? String, let version = AppVersion(tag), version > current,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let wanted = "Satchel-\(version).dmg"
        func asset(_ name: String) -> (URL, Int)? {
            guard let a = assets.first(where: { $0["name"] as? String == name }),
                  let s = a["browser_download_url"] as? String, let url = URL(string: s) else { return nil }
            if allowLocal, ["localhost", "127.0.0.1"].contains(url.host ?? "") { return (url, a["size"] as? Int ?? 0) }
            guard isAllowedDownloadURL(url), url.host?.lowercased() == "github.com",
                  url.path.hasPrefix("/\(repository)/releases/download/") else { return nil }
            return (url, a["size"] as? Int ?? 0)
        }
        guard let (dmg, size) = asset(wanted), size > 0, size <= maxDownloadBytes, let (sig, _) = asset(wanted + ".sig") else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init) ?? URL(string: "https://github.com/\(repository)/releases")!
        return UpdateOffer(version: version, notes: String((obj["body"] as? String ?? "").prefix(4000)),
                           pageURL: page, dmgURL: dmg, signatureURL: sig, size: size)
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
