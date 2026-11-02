import Clibsodium
import Foundation

/// Argon2id parameters, stored in the vault header so they can be raised later.
public struct KDFParams: Codable, Equatable, Sendable {
    /// 256 MiB. Measured 2026-11-01 on the owner's Apple-silicon Mac: 324 ms per derivation
    /// (64 MiB = 73 ms, 512 MiB = 676 ms). Four times the RFC 9106 second-recommendation floor.
    public var memoryKiB: UInt32 = 262144
    public var iterations: UInt32 = 3
    /// libsodium's Argon2id implements a single lane; parallelism is recorded for
    /// format compatibility and must be 1 for this implementation. The memory × passes
    /// cost per guess is the same as the RFC's p=4 setting.
    public var parallelism: UInt32 = 1
    public var salt: Data

    public static let saltBytes = Int(crypto_pwhash_saltbytes())

    public init(memoryKiB: UInt32 = 262144, iterations: UInt32 = 3, parallelism: UInt32 = 1, salt: Data) {
        self.memoryKiB = memoryKiB
        self.iterations = iterations
        self.parallelism = parallelism
        self.salt = salt
    }

    /// Upper bounds accepted from a header: 1 GiB and 20 passes (the defaults are 256 MiB, 3).
    static let maxMemoryKiB: UInt32 = 1_048_576
    static let maxIterations: UInt32 = 20

    public static func fresh() -> KDFParams {
        KDFParams(salt: Sodium.randomData(saltBytes))
    }
}

enum KDF {
    /// Derives a 32-byte key-encryption key from a password.
    static func deriveKEK(password: SecureBytes, params: KDFParams) throws -> SecureBytes {
        Sodium.ensureReady()
        // The parameters come from a file that a hostile remote can serve (the first download of a
        // vault has nothing to authenticate it yet): bound the work so it cannot exhaust memory or time.
        guard params.salt.count == KDFParams.saltBytes, params.parallelism == 1,
              params.iterations >= 1, params.iterations <= KDFParams.maxIterations,
              params.memoryKiB >= 8, params.memoryKiB <= KDFParams.maxMemoryKiB else {
            throw VaultError.corruptHeader
        }
        let out = SecureBytes(count: AEAD.keyBytes)
        let rc: Int32 = out.withUnsafeMutableBytes { o in
            password.withUnsafeBytes { p in
                params.salt.withUnsafeBytes { s in
                    crypto_pwhash(
                        o.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt64(AEAD.keyBytes),
                        p.baseAddress!.assumingMemoryBound(to: CChar.self), UInt64(password.count),
                        s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        UInt64(params.iterations), Int(params.memoryKiB) * 1024,
                        crypto_pwhash_alg_argon2id13())
                }
            }
        }
        guard rc == 0 else { throw VaultError.cryptoFailure } // only fails on allocation
        return out
    }
}

/// The random vault key and the sub-keys derived from it.
public enum VaultKey {
    public static let byteCount = 32

    public static func generate() -> SecureBytes {
        Sodium.random(byteCount)
    }

    /// HKDF-SHA256(salt: empty, ikm: vaultKey, info: info) → `count` bytes.
    static func subkey(_ vaultKey: SecureBytes, info: String, count: Int = 32) -> SecureBytes {
        Sodium.ensureReady()
        let prk = SecureBytes(count: Int(crypto_kdf_hkdf_sha256_keybytes()))
        defer { prk.wipe() }
        let out = SecureBytes(count: count)
        prk.withUnsafeMutableBytes { p in
            vaultKey.withUnsafeBytes { vk in
                _ = crypto_kdf_hkdf_sha256_extract(
                    p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    nil, 0,
                    vk.baseAddress!.assumingMemoryBound(to: UInt8.self), vaultKey.count)
            }
            out.withUnsafeMutableBytes { o in
                _ = crypto_kdf_hkdf_sha256_expand(
                    o.baseAddress!.assumingMemoryBound(to: UInt8.self), count,
                    info, info.utf8.count,
                    p.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
        return out
    }
}
