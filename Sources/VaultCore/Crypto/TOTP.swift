import CryptoKit
import Foundation

/// RFC 6238 time-based one-time codes. Accepts a bare base32 secret or an
/// `otpauth://totp/...` URI (secret, digits, period, algorithm are read from it).
public struct TOTP: Equatable, Sendable {
    public enum Algorithm: String, Sendable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    public let secret: Data
    public let digits: Int
    public let period: Int
    public let algorithm: Algorithm

    public init(secret: Data, digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// Parses what users paste: a base32 string (spaces and dashes allowed) or an otpauth URI.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://") {
            guard let comps = URLComponents(string: trimmed),
                  let items = comps.queryItems,
                  let s = items.first(where: { $0.name.lowercased() == "secret" })?.value,
                  let secret = Self.base32Decode(s) else { return nil }
            let q = { (k: String) in items.first { $0.name.lowercased() == k }?.value }
            self.init(secret: secret,
                      digits: Int(q("digits") ?? "") ?? 6,
                      period: Int(q("period") ?? "") ?? 30,
                      algorithm: Algorithm(rawValue: (q("algorithm") ?? "SHA1").uppercased()) ?? .sha1)
            return
        }
        guard let secret = Self.base32Decode(trimmed), !secret.isEmpty else { return nil }
        self.init(secret: secret)
    }

    public func code(at date: Date = Date()) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970)) / UInt64(period)
        var be = counter.bigEndian
        let msg = Data(bytes: &be, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let bin = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus = modulus &* 10 }
        let value = bin % modulus
        return String(repeating: "0", count: max(0, digits - String(value).count)) + String(value)
    }

    /// Seconds until the current code changes.
    public func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    // MARK: Base32 (RFC 4648, case-insensitive, padding and separators ignored)

    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32Decode(_ s: String) -> Data? {
        var bits = 0, value = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && ch != " " && ch != "-" {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }
}
