import Clibsodium
import Foundation

/// XChaCha20-Poly1305-IETF with a random 24-byte nonce.
/// Box layout: `nonce ‖ ciphertext ‖ tag`.
/// Reason: the 192-bit nonce makes random nonces safe without any counter state,
/// which matters because items are encrypted independently on several devices.
enum AEAD {
    static let nonceBytes = Int(crypto_aead_xchacha20poly1305_ietf_npubbytes())
    static let tagBytes = Int(crypto_aead_xchacha20poly1305_ietf_abytes())
    static let keyBytes = Int(crypto_aead_xchacha20poly1305_ietf_keybytes())

    static func seal(_ plaintext: SecureBytes, key: SecureBytes, aad: Data) throws -> Data {
        Sodium.ensureReady()
        guard key.count == keyBytes else { throw VaultError.cryptoFailure }
        var out = Data(count: nonceBytes + plaintext.count + tagBytes)
        let rc: Int32 = out.withUnsafeMutableBytes { o in
            let base = o.baseAddress!.assumingMemoryBound(to: UInt8.self)
            randombytes_buf(base, nonceBytes)
            var clen: UInt64 = 0
            return plaintext.withUnsafeBytes { m in
                key.withUnsafeBytes { k in
                    aad.withUnsafeBytes { a in
                        crypto_aead_xchacha20poly1305_ietf_encrypt(
                            base + nonceBytes, &clen,
                            m.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt64(plaintext.count),
                            a.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt64(aad.count),
                            nil, base,
                            k.baseAddress!.assumingMemoryBound(to: UInt8.self))
                    }
                }
            }
        }
        guard rc == 0 else { throw VaultError.cryptoFailure }
        return out
    }

    static func open(_ box: Data, key: SecureBytes, aad: Data) throws -> SecureBytes {
        Sodium.ensureReady()
        guard key.count == keyBytes else { throw VaultError.cryptoFailure }
        guard box.count >= nonceBytes + tagBytes else { throw VaultError.authenticationFailed }
        let out = SecureBytes(count: box.count - nonceBytes - tagBytes)
        let rc: Int32 = box.withUnsafeBytes { b in
            let base = b.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var mlen: UInt64 = 0
            return out.withUnsafeMutableBytes { m in
                key.withUnsafeBytes { k in
                    aad.withUnsafeBytes { a in
                        crypto_aead_xchacha20poly1305_ietf_decrypt(
                            m.baseAddress?.assumingMemoryBound(to: UInt8.self), &mlen,
                            nil,
                            base + nonceBytes, UInt64(box.count - nonceBytes),
                            a.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt64(aad.count),
                            base,
                            k.baseAddress!.assumingMemoryBound(to: UInt8.self))
                    }
                }
            }
        }
        guard rc == 0 else { throw VaultError.authenticationFailed }
        return out
    }
}
