import Foundation

/// Single place for the product name and bundle identifier.
/// Rename here only; nothing else hard-codes these values.
public enum AppIdentity {
    public static let name = "Vault"
    public static let bundleID = "com.bilalesi.vault"

    /// Default on-disk location of the vault directory.
    public static var defaultVaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("default.vault", isDirectory: true)
    }
}
