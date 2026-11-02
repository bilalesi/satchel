import Foundation
import VaultCore

/// JSON contract between the extension and the app (via the host). Versioned by `version`.
struct BridgeRequest: Decodable {
    let id: Int
    let type: String
    var origin: String?
    var url: String?
    var itemID: UUID?
    var username: String?
    var password: String?
    var title: String?
    var query: String?
    /// For `copy`: "username", "password" or "totp".
    var field: String?
    /// For `open`: "settings:sync", or nothing for the main window.
    var target: String?
    var limit: Int?
}

struct BridgeItem: Encodable {
    let id: UUID
    let title: String
    let username: String?
    let host: String?
    let type: String
    let favorite: Bool
    let category: String?

    init(_ o: ItemOverview, category: String? = nil) {
        id = o.id
        title = o.title
        username = o.username
        host = o.hosts.first
        type = o.type.rawValue
        favorite = o.favorite
        self.category = category
    }
}

/// What the popup shows about the vault besides the matches. Never contains a secret.
struct BridgeInfo: Encodable {
    var workspace: String
    var workspaceIcon: String
    var workspaceColor: String
    /// Only while unlocked.
    var items: Int?
    var rotate: Int?
    var rotateTitles: [String]?
    var localOnly: Int?
    var sync: BridgeSync
}

struct BridgeSync: Encodable {
    /// "off", "idle", "syncing" or "error".
    var state: String
    var backend: String?
    /// Seconds since 1970 of the last good sync.
    var last: Double?
    var error: String?
}

struct BridgeCredential: Encodable {
    let username: String?
    let password: String
    /// Current one-time code when the item has a TOTP seed.
    var totp: String?
}

struct BridgeResponse: Encodable {
    static let version = "1"

    let id: Int
    var ok = true
    var error: String?
    var locked: Bool?
    var items: [BridgeItem]?
    var credential: BridgeCredential?
    var password: String?
    var version: String?
    var info: BridgeInfo?
    /// For `code`: the current one-time code and the seconds it stays valid.
    var code: String?
    var remaining: Int?

    static func failure(_ id: Int, _ error: String) -> BridgeResponse {
        BridgeResponse(id: id, ok: false, error: error)
    }
}

/// Constants the app, the host manifests and the extension agree on.
enum BrowserIntegration {
    /// Derived from the public key in `extension/src/.chromium-key`.
    static let chromiumExtensionID = "nhhioljdfmghplnmhnmakppanojkodpn"
    static let chromiumOrigin = "chrome-extension://\(chromiumExtensionID)/"
    static let allowedOrigins: Set<String> = [chromiumOrigin, AppIdentity.firefoxExtensionID]

    static var hostBinaryURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + AppIdentity.hostExecutableName)
    }

    /// The folder to load the extension from: the stable copy in Satchel's data folder (see `ExtensionFiles`),
    /// or the app's own while that copy does not exist yet.
    static var extensionDistURL: URL? {
        if FileManager.default.fileExists(atPath: ExtensionFiles.stableURL.path) { return ExtensionFiles.stableURL }
        return Bundle.main.resourceURL?.appendingPathComponent("extension", isDirectory: true)
    }
}
