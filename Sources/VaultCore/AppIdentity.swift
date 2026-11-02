import Foundation

/// Single place for the product name and bundle identifier.
/// Rename here only; nothing else hard-codes these values.
public enum AppIdentity {
    public static let name = "Satchel"
    public static let bundleID = "com.bilalesi.satchel"

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

    /// Folder holding the vaults of additional workspaces.
    public static var workspacesURL: URL {
        supportDirectory.appendingPathComponent("workspaces", isDirectory: true)
    }

    /// Unix socket the native messaging host talks to.
    public static var bridgeSocketURL: URL {
        supportDirectory.appendingPathComponent("bridge.sock")
    }

    /// Native messaging host name registered in the browsers' manifests.
    public static let nativeHostName = bundleID
    /// Firefox extension id (`browser_specific_settings.gecko.id`).
    public static let firefoxExtensionID = "satchel@bilalesi"
}
