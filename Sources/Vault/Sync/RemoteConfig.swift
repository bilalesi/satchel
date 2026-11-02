import Foundation
import VaultCore

/// Which remote the vault mirrors to. Persisted as JSON in UserDefaults. The GitHub
/// token is not here: it lives encrypted in the vault directory (`github-token.local`).
enum RemoteConfig: Codable, Equatable {
    case off
    case folder(URL)
    case github(GitHubRepo)

    static let defaultsKey = "remoteConfig"
    static let tokenSecretName = "github-token"
    /// Legacy location (phase 2 builds); migrated once, off the main thread.
    static let legacyKeychainService = AppIdentity.bundleID + ".github"

    static func load() -> RemoteConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let c = try? JSONDecoder().decode(RemoteConfig.self, from: data) else { return .off }
        return c
    }

    func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .folder(let url): return "Folder: " + url.lastPathComponent
        case .github(let repo): return "GitHub: " + repo.fullName
        }
    }

    var needsToken: Bool {
        if case .github = self { return true } else { return false }
    }

    /// Builds the backend with an explicit token (GitHub) or none (folder).
    func makeStore(token: String?) throws -> RemoteStore {
        switch self {
        case .off:
            throw SyncError.notConfigured
        case .folder(let url):
            return FolderStore(root: url)
        case .github(let repo):
            guard let token, !token.isEmpty else { throw SyncError.missingToken }
            return GitHubStore(repo: repo, token: token)
        }
    }

    /// Token from the unlocked vault; migrates a phase-2 Keychain item on first use.
    /// Must not run on the main thread: a Keychain ACL prompt blocks the caller.
    static func resolveToken(store: VaultStore) throws -> String? {
        if let t = try store.localSecret(tokenSecretName) { return t }
        guard let legacy = KeychainToken.load(service: legacyKeychainService), !legacy.isEmpty else { return nil }
        try store.setLocalSecret(tokenSecretName, legacy)
        KeychainToken.delete(service: legacyKeychainService)
        return legacy
    }
}
