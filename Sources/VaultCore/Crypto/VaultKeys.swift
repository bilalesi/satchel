import Foundation

/// Sub-keys derived from the vault key. Each has one job so a leak of one blob type
/// never helps with another.
public struct VaultKeys: Sendable {
    public let item: SecureBytes
    public let overview: SecureBytes
    public let manifest: SecureBytes

    public init(vaultKey: SecureBytes) {
        item = VaultKey.subkey(vaultKey, info: "item")
        overview = VaultKey.subkey(vaultKey, info: "overview")
        manifest = VaultKey.subkey(vaultKey, info: "manifest")
    }

    public func wipe() {
        item.wipe()
        overview.wipe()
        manifest.wipe()
    }
}
