import Foundation
import VaultCore

/// UserDefaults-backed preferences. Keys are namespaced by the bundle id.
enum AppSettings {
    static let autoLockMinutesKey = "autoLockMinutes"
    static let clipboardSecondsKey = "clipboardSeconds"
    static let vaultPathKey = "vaultPath"
    static let hotKeyEnabledKey = "hotKeyEnabled"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoLockMinutesKey: 10,
            clipboardSecondsKey: 30,
            hotKeyEnabledKey: true,
        ])
    }

    static var autoLockMinutes: Int { UserDefaults.standard.integer(forKey: autoLockMinutesKey) }
    static var clipboardSeconds: Int { UserDefaults.standard.integer(forKey: clipboardSecondsKey) }

    static var vaultURL: URL {
        if let p = UserDefaults.standard.string(forKey: vaultPathKey), !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return AppIdentity.defaultVaultURL
    }
}
