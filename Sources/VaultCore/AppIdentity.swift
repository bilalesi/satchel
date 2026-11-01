import Foundation

/// Single place for the product name and bundle identifier.
/// Rename here only; nothing else hard-codes these values.
public enum AppIdentity {
    public static let name = "Vault"
    public static let bundleID = "com.bilalesi.vault"

    /// `~/Library/Application Support/Vault/`
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Default on-disk location of the vault directory.
    public static var defaultVaultURL: URL {
        supportDirectory.appendingPathComponent("default.vault", isDirectory: true)
    }

    /// Unix socket the native messaging host talks to.
    public static var bridgeSocketURL: URL {
        supportDirectory.appendingPathComponent("bridge.sock")
    }

    /// Native messaging host name registered in the browsers' manifests.
    public static let nativeHostName = bundleID
    /// Firefox extension id (`browser_specific_settings.gecko.id`).
    public static let firefoxExtensionID = "vault@bilalesi"
}
