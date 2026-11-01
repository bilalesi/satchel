import Foundation

public enum VaultError: Error, Equatable, Sendable {
    /// Wrong password, wrong key, or ciphertext that fails authentication.
    case authenticationFailed
    /// A libsodium call failed for a non-authentication reason (e.g. out of memory for Argon2).
    case cryptoFailure
    case corruptHeader
    case corruptItem(UUID)
    /// Raised by `ItemFile` which does not know the file name; `VaultStore` maps it to `corruptItem(id)`.
    case corruptItemData
    case corruptManifest
    case rollbackDetected(local: UInt64, remote: UInt64)
    case biometryUnavailable
    /// Secure Enclave key invalidated because the biometric set changed.
    case biometryChanged
    /// The user dismissed the Touch ID prompt. Not an error to display.
    case cancelled
    case locked
    case io(String)
}

extension VaultError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationFailed: return "Wrong password or corrupted data."
        case .cryptoFailure: return "A cryptographic operation failed."
        case .corruptHeader: return "The vault header is unreadable."
        case .corruptItem(let id): return "Item \(id.uuidString) is unreadable."
        case .corruptItemData: return "Item data is unreadable."
        case .corruptManifest: return "The vault manifest failed verification."
        case .rollbackDetected(let local, let remote):
            return "The remote vault is older (generation \(remote)) than this device last saw (\(local))."
        case .biometryUnavailable: return "Touch ID is not available."
        case .biometryChanged: return "Touch ID enrollment changed. Unlock with your password and enable Touch ID again."
        case .cancelled: return "Cancelled."
        case .locked: return "The vault is locked."
        case .io(let message): return message
        }
    }
}
