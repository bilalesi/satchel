import Foundation

/// One way to unwrap the vault key. LUKS-style: several slots wrap the same key, so
/// changing the password or adding Touch ID never re-encrypts items.
public enum KeySlot: Codable, Equatable, Sendable {
    case password(params: KDFParams, wrappedKey: Data)
    /// `keyData` is the Secure Enclave key's opaque representation (useless off this
    /// Mac); `wrappedKey` is `ephemeralPublicKey ‖ AEAD box`.
    case secureEnclave(keyData: Data, wrappedKey: Data)

    /// AAD binds a wrapped key to its slot type, so a slot cannot be re-labelled.
    static let passwordAAD = Data("vault-slot:password:v1".utf8)
    static let secureEnclaveAAD = Data("vault-slot:secure-enclave:v1".utf8)

    public var isPassword: Bool {
        if case .password = self { return true } else { return false }
    }

    public var isSecureEnclave: Bool {
        if case .secureEnclave = self { return true } else { return false }
    }

    public static func makePassword(_ password: SecureBytes, vaultKey: SecureBytes,
                                    params: KDFParams = .fresh()) throws -> KeySlot {
        let kek = try KDF.deriveKEK(password: password, params: params)
        defer { kek.wipe() }
        return .password(params: params, wrappedKey: try AEAD.seal(vaultKey, key: kek, aad: passwordAAD))
    }

    public func unwrap(password: SecureBytes) throws -> SecureBytes {
        guard case let .password(params, wrapped) = self else { throw VaultError.authenticationFailed }
        let kek = try KDF.deriveKEK(password: password, params: params)
        defer { kek.wipe() }
        return try AEAD.open(wrapped, key: kek, aad: Self.passwordAAD)
    }
}
