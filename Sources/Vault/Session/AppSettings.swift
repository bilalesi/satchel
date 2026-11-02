import Foundation
import VaultCore

/// UserDefaults-backed preferences. Keys are namespaced by the bundle id.
enum AppSettings {
    static let autoLockMinutesKey = "autoLockMinutes"
    static let clipboardSecondsKey = "clipboardSeconds"
    static let vaultPathKey = "vaultPath"
    static let hotKeyEnabledKey = "hotKeyEnabled"
    static let autoTypeEnabledKey = "autoTypeEnabled"

    static let migratedKey = "migratedFromLegacyDefaults"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoLockMinutesKey: 10,
            clipboardSecondsKey: 30,
            hotKeyEnabledKey: true,
        ])
        migrateLegacyDefaults()
    }

    /// One-time copy of settings from the previous bundle id's preference domain.
    static func migrateLegacyDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: migratedKey), let legacy = UserDefaults(suiteName: AppIdentity.legacyBundleID) else { return }
        for key in [autoLockMinutesKey, clipboardSecondsKey, vaultPathKey, hotKeyEnabledKey, autoTypeEnabledKey, "remoteConfig"] {
            if d.object(forKey: key) == nil, let v = legacy.object(forKey: key) { d.set(v, forKey: key) }
        }
        let legacyDevice = AppIdentity.legacyBundleID + ".deviceID", newDevice = AppIdentity.bundleID + ".deviceID"
        if d.string(forKey: newDevice) == nil, let v = legacy.string(forKey: legacyDevice) { d.set(v, forKey: newDevice) }
        d.set(true, forKey: migratedKey)
    }

    static var autoLockMinutes: Int { UserDefaults.standard.integer(forKey: autoLockMinutesKey) }
    static var clipboardSeconds: Int { UserDefaults.standard.integer(forKey: clipboardSecondsKey) }
    static var autoTypeEnabled: Bool { UserDefaults.standard.bool(forKey: autoTypeEnabledKey) }

    static var vaultURL: URL {
        if let p = UserDefaults.standard.string(forKey: vaultPathKey), !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return AppIdentity.defaultVaultURL
    }
}
