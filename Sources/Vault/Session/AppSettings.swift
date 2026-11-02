import AppKit
import Foundation
import VaultCore

/// UserDefaults-backed preferences. Keys are namespaced by the bundle id.
enum AppSettings {
    static let autoLockMinutesKey = "autoLockMinutes"
    static let clipboardSecondsKey = "clipboardSeconds"
    static let vaultPathKey = "vaultPath"
    static let hotKeyEnabledKey = "hotKeyEnabled"
    static let autoTypeEnabledKey = "autoTypeEnabled"
    /// Off by default: windows are hidden from screenshots and screen sharing.
    static let allowScreenCaptureKey = "allowScreenCapture"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoLockMinutesKey: 10,
            clipboardSecondsKey: 30,
            hotKeyEnabledKey: true,
        ])
    }

    static var autoLockMinutes: Int { UserDefaults.standard.integer(forKey: autoLockMinutesKey) }
    static var clipboardSeconds: Int { UserDefaults.standard.integer(forKey: clipboardSecondsKey) }
    static var autoTypeEnabled: Bool { UserDefaults.standard.bool(forKey: autoTypeEnabledKey) }
    static var allowScreenCapture: Bool { UserDefaults.standard.bool(forKey: allowScreenCaptureKey) }

    /// The one place that decides whether a window may appear in screenshots.
    @MainActor static func applyCapturePolicy(to window: NSWindow) {
        window.sharingType = allowScreenCapture ? .readOnly : .none
    }

    @MainActor static func applyCapturePolicyToAllWindows() {
        NSApp.windows.forEach(applyCapturePolicy)
    }

    static var vaultURL: URL {
        if let p = UserDefaults.standard.string(forKey: vaultPathKey), !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return AppIdentity.defaultVaultURL
    }
}
