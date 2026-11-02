import Foundation

/// Single place for the product name and bundle identifier.
/// Rename here only; nothing else hard-codes these values.
public enum AppIdentity {
    public static let name = "Satchel"
    public static let bundleID = "com.bilalesi.satchel"

    /// Identity used by builds before 2026-11-02; migrated on first launch.
    public static let legacyName = "Vault"
    public static let legacyBundleID = "com.bilalesi.vault"

    /// Executable name of the native messaging relay inside the bundle.
    public static let hostExecutableName = "satchel-host"

    /// `~/Library/Application Support/Satchel/`
    public static var supportDirectory: URL {
        applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
    public static let legacyNativeHostName = legacyBundleID
    /// Firefox extension id (`browser_specific_settings.gecko.id`).
    public static let firefoxExtensionID = "satchel@bilalesi"

    /// Moves `Application Support/Vault` to `Application Support/Satchel` once. Returns true
    /// when a move happened. Nothing is copied: a rename on the same volume is atomic.
    @discardableResult
    public static func migrateLegacySupportDirectory() -> Bool {
        let fm = FileManager.default
        let legacy = applicationSupport.appendingPathComponent(legacyName, isDirectory: true)
        guard !fm.fileExists(atPath: supportDirectory.path), fm.fileExists(atPath: legacy.path) else { return false }
        try? fm.removeItem(at: legacy.appendingPathComponent("bridge.sock")) // stale socket of the old app
        return (try? fm.moveItem(at: legacy, to: supportDirectory)) != nil
    }
}
