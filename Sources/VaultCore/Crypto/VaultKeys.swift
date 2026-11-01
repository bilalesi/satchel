import Foundation

/// Sub-keys derived from the vault key. Each has one job so a leak of one blob type
/// never helps with another.
public struct VaultKeys: Sendable {
    public let item: SecureBytes
    public let overview: SecureBytes
    public let manifest: SecureBytes
    /// Device-local secrets next to the vault (remote tokens); never synced.
    public let local: SecureBytes

    public init(vaultKey: SecureBytes) {
        item = VaultKey.subkey(vaultKey, info: "item")
        overview = VaultKey.subkey(vaultKey, info: "overview")
        manifest = VaultKey.subkey(vaultKey, info: "manifest")
        local = VaultKey.subkey(vaultKey, info: "local-secret")
    }

    public func wipe() {
        item.wipe()
        overview.wipe()
        manifest.wipe()
        local.wipe()
    }
}
