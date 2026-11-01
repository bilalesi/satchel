import Foundation
import VaultCore

/// Which remote the vault mirrors to. Persisted as JSON in UserDefaults; the GitHub
/// token is never here, it lives in the Keychain under `tokenService`.
enum RemoteConfig: Codable, Equatable {
    case off
    case folder(URL)
    case github(GitHubRepo)

    static let defaultsKey = "remoteConfig"
    static let tokenService = AppIdentity.bundleID + ".github"

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

    /// Builds the backend. Throws `SyncError.notConfigured` when off, `.unauthorized` when
    /// the GitHub token is missing from the Keychain.
    func makeStore() throws -> RemoteStore {
        switch self {
        case .off:
            throw SyncError.notConfigured
        case .folder(let url):
            return FolderStore(root: url)
        case .github(let repo):
            guard let token = KeychainToken.load(service: Self.tokenService), !token.isEmpty else {
                throw SyncError.unauthorized
            }
            return GitHubStore(repo: repo, token: token)
        }
    }
}
