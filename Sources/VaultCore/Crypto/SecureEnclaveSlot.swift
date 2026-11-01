import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Touch ID unlock. A P-256 key lives in the Secure Enclave, usable only with the
/// currently enrolled biometrics. The vault key is wrapped with ECIES: an ephemeral
/// P-256 key agrees with the SE public key, HKDF derives a KEK, AEAD seals the vault key.
/// Wrapping needs no biometrics; unwrapping prompts Touch ID.
/// `wrappedKey` = ephemeral public key (64 bytes, x‖y) ‖ AEAD box.
public enum SecureEnclaveSlot {
    static let hkdfInfo = Data("vault-se-wrap-v1".utf8)
    static let ephemeralPublicKeyBytes = 64

    public static var isAvailable: Bool {
        guard SecureEnclave.isAvailable else { return false }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public static func make(vaultKey: SecureBytes, context: LAContext) throws -> KeySlot {
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], &cfError) else {
            throw VaultError.biometryUnavailable
        }
        do {
            let sePrivate = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access,
                                                                           authenticationContext: context)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let kek = try kek(from: ephemeral.sharedSecretFromKeyAgreement(with: sePrivate.publicKey))
            defer { kek.wipe() }
            let box = try AEAD.seal(vaultKey, key: kek, aad: KeySlot.secureEnclaveAAD)
            return .secureEnclave(keyData: sePrivate.dataRepresentation,
                                  wrappedKey: ephemeral.publicKey.rawRepresentation + box)
        } catch let e as VaultError {
            throw e
        } catch {
            throw map(error)
        }
    }

    public static func unwrap(_ slot: KeySlot, context: LAContext) throws -> SecureBytes {
        guard case let .secureEnclave(keyData, wrapped) = slot else { throw VaultError.authenticationFailed }
        guard wrapped.count > ephemeralPublicKeyBytes else { throw VaultError.corruptHeader }
        do {
            let sePrivate = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keyData,
                                                                           authenticationContext: context)
            let ephemeralPublic = try P256.KeyAgreement.PublicKey(rawRepresentation: wrapped.prefix(ephemeralPublicKeyBytes))
            let kek = try kek(from: sePrivate.sharedSecretFromKeyAgreement(with: ephemeralPublic))
            defer { kek.wipe() }
            return try AEAD.open(wrapped.dropFirst(ephemeralPublicKeyBytes), key: kek, aad: KeySlot.secureEnclaveAAD)
        } catch let e as VaultError {
            throw e
        } catch {
            throw map(error)
        }
    }

    private static func kek(from shared: SharedSecret) throws -> SecureBytes {
        let sym = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
                                                 sharedInfo: hkdfInfo, outputByteCount: AEAD.keyBytes)
        let kek = SecureBytes(count: AEAD.keyBytes)
        sym.withUnsafeBytes { src in
            kek.withUnsafeMutableBytes { dst in dst.copyMemory(from: src) }
        }
        return kek
    }

    /// Maps LocalAuthentication / Security errors onto `VaultError`.
    static func map(_ error: Error) -> VaultError {
        if let la = error as? LAError {
            switch la.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
            case .biometryNotEnrolled, .biometryNotAvailable, .biometryLockout, .passcodeNotSet: return .biometryUnavailable
            default: return .authenticationFailed
            }
        }
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSOSStatusErrorDomain, Int(errSecUserCanceled)): return .cancelled
        // A key bound to `.biometryCurrentSet` becomes permanently unusable after enrollment changes.
        case (NSOSStatusErrorDomain, Int(errSecAuthFailed)), (NSOSStatusErrorDomain, Int(errSecItemNotFound)): return .biometryChanged
        case (LAErrorDomain, _): return .authenticationFailed
        default: return .biometryUnavailable
        }
    }
}
