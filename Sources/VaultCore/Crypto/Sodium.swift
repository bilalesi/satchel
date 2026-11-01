import Clibsodium
import Foundation

/// libsodium bootstrap and randomness. Everything in `VaultCore` goes through here
/// so `sodium_init()` is guaranteed before any primitive is used.
enum Sodium {
    /// `sodium_init()` is thread-safe and idempotent (returns 1 when already done).
    static let ready: Bool = sodium_init() >= 0

    static func ensureReady() {
        precondition(ready, "libsodium failed to initialise")
    }

    static func random(_ count: Int) -> SecureBytes {
        let bytes = SecureBytes(count: count)
        bytes.withUnsafeMutableBytes { randombytes_buf($0.baseAddress!, count) }
        return bytes
    }

    static func randomData(_ count: Int) -> Data {
        ensureReady()
        var data = Data(count: count)
        if count > 0 { data.withUnsafeMutableBytes { randombytes_buf($0.baseAddress!, count) } }
        return data
    }
}
