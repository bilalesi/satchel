import CryptoKit
import Foundation

/// Git's blob object id: SHA-1 of `"blob <len>\0" ‖ content`, hex.
/// Used as the etag by every backend. Not a security primitive: it only has to equal
/// what GitHub reports for the same bytes, so unchanged files are never transferred.
public enum GitBlob {
    public static func sha(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\u{0}".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
