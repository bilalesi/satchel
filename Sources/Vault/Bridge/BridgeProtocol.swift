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
}

struct BridgeItem: Encodable {
    let id: UUID
    let title: String
    let username: String?
    let host: String?
    let type: String

    init(_ o: ItemOverview) {
        id = o.id
        title = o.title
        username = o.username
        host = o.hosts.first
        type = o.type.rawValue
    }
}

struct BridgeCredential: Encodable {
    let username: String?
    let password: String
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
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/vault-host")
    }

    static var extensionDistURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("extension", isDirectory: true)
    }
}
