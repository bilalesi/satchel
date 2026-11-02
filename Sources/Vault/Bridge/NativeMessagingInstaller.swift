import AppKit
import Foundation
import VaultCore

/// Writes the native messaging host manifest into each browser's directory so the
/// extension can spawn `satchel-host`. Re-run after the app moves (paths are absolute).
enum NativeMessagingInstaller {
    enum Browser: String, CaseIterable, Identifiable {
        case dia, arc, chrome, firefox
        var id: String { rawValue }

        var title: String {
            switch self { case .dia: return "Dia"; case .arc: return "Arc"; case .chrome: return "Google Chrome"; case .firefox: return "Firefox" }
        }

        var bundleID: String {
            switch self {
            case .dia: return "company.thebrowser.dia"
            case .arc: return "company.thebrowser.Browser"
            case .chrome: return "com.google.Chrome"
            case .firefox: return "org.mozilla.firefox"
            }
        }

        var isChromium: Bool { self != .firefox }

        var manifestDirectory: URL {
            // An isolated test copy writes its connection files inside its own folder, never into the browsers'.
            if AppIdentity.isIsolatedCopy {
                return AppIdentity.supportDirectory.appendingPathComponent("NativeMessagingHosts/\(rawValue)", isDirectory: true)
            }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            switch self {
            case .dia: return support.appendingPathComponent("Dia/User Data/NativeMessagingHosts")
            case .arc: return support.appendingPathComponent("Arc/User Data/NativeMessagingHosts")
            case .chrome: return support.appendingPathComponent("Google/Chrome/NativeMessagingHosts")
            case .firefox: return support.appendingPathComponent("Mozilla/NativeMessagingHosts")
            }
        }

        var manifestURL: URL { manifestDirectory.appendingPathComponent(AppIdentity.nativeHostName + ".json") }

        /// The browser app exists on this Mac (by bundle id, so a moved app still counts).
        var isInstalled: Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }

        var manifestPresent: Bool { FileManager.default.fileExists(atPath: manifestURL.path) }

        /// Present but pointing at another copy of the app.
        var manifestStale: Bool {
            guard let data = try? Data(contentsOf: manifestURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = obj["path"] as? String else { return false }
            return path != BrowserIntegration.hostBinaryURL.path
        }
    }

    static func manifest(for browser: Browser) -> [String: Any] {
        var m: [String: Any] = [
            "name": AppIdentity.nativeHostName,
            "description": "\(AppIdentity.name) native messaging host",
            "path": BrowserIntegration.hostBinaryURL.path,
            "type": "stdio",
        ]
        if browser.isChromium {
            m["allowed_origins"] = [BrowserIntegration.chromiumOrigin]
        } else {
            m["allowed_extensions"] = [AppIdentity.firefoxExtensionID]
        }
        return m
    }

    static func install(_ browser: Browser) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: browser.manifestDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest(for: browser), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: browser.manifestURL, options: .atomic)
    }

    static func remove(_ browser: Browser) {
        try? FileManager.default.removeItem(at: browser.manifestURL)
    }

    /// At launch: manifests that exist but point elsewhere (the app moved or was updated)
    /// are rewritten for this copy.
    static func refreshStalePaths() {
        for b in Browser.allCases where b.manifestPresent && b.manifestStale {
            try? install(b)
        }
    }
}
