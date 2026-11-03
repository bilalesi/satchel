import Foundation

/// Single place for the product name and bundle identifier.
/// Rename here only; nothing else hard-codes these values.
public enum AppIdentity {
    public static let name = "Satchel"
    public static let bundleID = "com.ekhodev.satchel"

    /// Executable name of the native messaging relay inside the bundle.
    public static let hostExecutableName = "satchel-host"

    /// `~/Library/Application Support/Satchel/`
    public static var supportDirectory: URL {
        #if DEBUG
        // Development only (compiled out of releases): run a throwaway copy against its own data.
        if let path = ProcessInfo.processInfo.environment["SATCHEL_SUPPORT_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        return applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    /// True for a throwaway debug copy that runs on its own data folder. Such a copy must not touch anything
    /// outside that folder: the browsers' connection files point at the real app, and a test copy that rewrote
    /// them would cut the real app's browser extension off.
    public static var isIsolatedCopy: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SATCHEL_SUPPORT_DIR"] != nil
        #else
        return false
        #endif
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
    /// Where "Buy" and "Renew" lead.
    public static let purchaseURL = URL(string: "https://satchel.echospace.dev/pricing")!

    /// Firefox extension id (`browser_specific_settings.gecko.id`).
    public static let firefoxExtensionID = "satchel@ekhodev"
}
