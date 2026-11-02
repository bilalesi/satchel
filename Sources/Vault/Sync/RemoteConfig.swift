import Foundation
import VaultCore

/// Which remote one vault mirrors to. Stored per vault, encrypted, as the local secret
/// `sync-config` (it can name private hosts and repositories). Credentials are separate local
/// secrets named by `secretName`. Neither is ever synced.
enum RemoteConfig: Codable, Equatable {
    case off
    case folder(URL)
    case github(GitHubRepo)
    case git(GitConfig)
    case webdav(url: URL, username: String)
    case s3(S3Config)

    static let storeKey = "sync-config"

    static func load(from store: VaultStore) -> RemoteConfig {
        guard let json = try? store.localSecret(storeKey), let data = json.data(using: .utf8),
              let c = try? JSONDecoder().decode(RemoteConfig.self, from: data) else { return .off }
        return c
    }

    func persist(to store: VaultStore) throws {
        if self == .off { try store.setLocalSecret(Self.storeKey, nil); return }
        let json = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        try store.setLocalSecret(Self.storeKey, json)
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .folder(let url): return "Folder: " + url.lastPathComponent
        case .github(let repo): return "GitHub: " + repo.fullName
        case .git(let g): return "Git: " + g.url
        case .webdav(let url, _): return "WebDAV: " + (url.host ?? url.absoluteString)
        case .s3(let c): return "S3: " + c.bucket
        }
    }

    /// Local secret holding the password or token, if the backend needs one.
    var secretName: String? {
        switch self {
        case .github: return "github-token"
        case .webdav: return "webdav-password"
        case .s3: return "s3-secret-key"
        case .off, .folder, .git: return nil
        }
    }

    var needsSecret: Bool { secretName != nil }

    /// Backends whose servers must be proven to enforce conditional writes before use.
    var needsConditionalWriteProbe: Bool {
        switch self {
        case .webdav, .s3: return true
        case .off, .folder, .github, .git: return false
        }
    }

    func makeStore(secret: String?) throws -> RemoteStore {
        switch self {
        case .off:
            throw SyncError.notConfigured
        case .folder(let url):
            return FolderStore(root: url)
        case .github(let repo):
            guard let secret, !secret.isEmpty else { throw SyncError.missingToken }
            return GitHubStore(repo: repo, token: secret)
        case .git(let config):
            return try GitStore(config: config, cacheRoot: GitStore.defaultCacheRoot)
        case .webdav(let url, let username):
            guard let secret, !secret.isEmpty else { throw SyncError.missingToken }
            return try WebDAVStore(baseURL: url, username: username, password: secret)
        case .s3(let config):
            guard let secret, !secret.isEmpty else { throw SyncError.missingToken }
            return try S3Store(config: config, secretKey: secret)
        }
    }

    /// The credential from the unlocked vault. Never call on the main thread for slow stores.
    func resolveSecret(store: VaultStore) throws -> String? {
        guard let name = secretName else { return nil }
        return try store.localSecret(name)
    }
}
