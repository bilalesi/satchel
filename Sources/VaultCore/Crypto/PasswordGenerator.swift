import Clibsodium
import Foundation

public enum PasswordGenerator {
    static let letters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ") // no l/I/O ambiguity
    static let digits = Array("23456789")
    static let symbols = Array("!@#$%^&*-_=+?")

    /// Uniformly random characters via `randombytes_uniform` (rejection sampling, no modulo bias).
    public static func generate(length: Int = 24, digits useDigits: Bool = true, symbols useSymbols: Bool = true) -> String {
        Sodium.ensureReady()
        var alphabet = letters
        if useDigits { alphabet += digits }
        if useSymbols { alphabet += symbols }
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<max(length, 1) {
            out.append(alphabet[Int(randombytes_uniform(UInt32(alphabet.count)))])
        }
        return out
    }
}
