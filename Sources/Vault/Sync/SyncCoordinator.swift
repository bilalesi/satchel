import Foundation
import Network
import VaultCore

/// Decides *when* to sync; `SyncEngine` decides *what*. One run at a time, a request
/// during a run sets a dirty flag and re-runs once. Triggers: 2 s after a local change,
/// on unlock, every 15 minutes, on network regain, on config change.
@MainActor
final class SyncCoordinator: ObservableObject {
    enum Status: Equatable {
        case off, idle, syncing, error(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastReport: SyncReport?
    @Published var config: RemoteConfig {
        didSet {
            guard config != oldValue else { return }
            config.persist()
            status = config == .off ? .off : .idle
            lastReport = nil
            requestSync(reason: "configuration changed", delay: 0)
        }
    }

    private weak var session: VaultSession?
    private var debounce: Task<Void, Never>?
    private var running = false
    private var dirty = false
    private var periodic: Timer?
    private let monitor = NWPathMonitor()
    private var online = true

    init() {
        config = RemoteConfig.load()
        status = config == .off ? .off : .idle
        periodic = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSync(reason: "periodic", delay: 0) }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let regained = up && !self.online
                self.online = up
                if regained { self.requestSync(reason: "network regained", delay: 1) }
            }
        }
        monitor.start(queue: DispatchQueue(label: AppIdentity.bundleID + ".network"))
    }

    func attach(session: VaultSession) {
        self.session = session
    }

    var isConfigured: Bool { config != .off }

    /// Coalesces bursts of local edits into one run.
    func requestSync(reason: String, delay: TimeInterval = 2) {
        guard isConfigured, session?.state == .unlocked else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let session, let store = session.store, store.isUnlocked, isConfigured else { return }
        if running { dirty = true; return }
        running = true
        status = .syncing
        defer { running = false }
        do {
            let config = self.config
            // Token lookup and the whole run stay off the main thread (Keychain migration may prompt).
            let report = try await Task.detached(priority: .utility) {
                let token = config.needsToken ? try RemoteConfig.resolveToken(store: store) : nil
                let remote = try config.makeStore(token: token)
                return try await SyncEngine(store: store, remote: remote).sync()
            }.value
            lastReport = report
            lastSyncAt = Date()
            status = .idle
            if report.pulled > 0 || report.conflicts > 0 { try session.reload() }
        } catch {
            status = .error(Self.describe(error))
        }
        if dirty {
            dirty = false
            await syncNow()
        }
    }

    /// Stores the GitHub token encrypted in the vault directory.
    func saveToken(_ token: String) throws {
        guard let store = session?.store, store.isUnlocked else { throw VaultError.locked }
        try store.setLocalSecret(RemoteConfig.tokenSecretName, token)
    }

    var hasToken: Bool {
        guard let store = session?.store, store.isUnlocked else { return false }
        return (try? store.localSecret(RemoteConfig.tokenSecretName)) != nil
    }

    /// "Test connection" in settings. Returns a human sentence.
    func test(_ config: RemoteConfig, token typed: String?) async -> String {
        do {
            let store = session?.store
            let remote = try await Task.detached { () throws -> RemoteStore in
                var token = typed?.isEmpty == false ? typed : nil
                if token == nil, config.needsToken, let store { token = try RemoteConfig.resolveToken(store: store) }
                return try config.makeStore(token: token)
            }.value
            if let gh = remote as? GitHubStore {
                let name = try await gh.verify()
                let hasVault = try await gh.get(RemotePaths.manifest) != nil
                return "Connected to \(name). " + (hasVault ? "A vault is already there." : "No vault there yet; the first sync will create it.")
            }
            let hasVault = try await remote.get(RemotePaths.manifest) != nil
            return "Folder reachable. " + (hasVault ? "A vault is already there." : "No vault there yet.")
        } catch {
            return Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case VaultError.rollbackDetected(let local, let remote):
            return "The remote vault is older (generation \(remote)) than what this Mac last synced (\(local)). Refusing to roll back."
        case VaultError.corruptManifest:
            return "The remote manifest failed verification. It was written with a different vault key or tampered with."
        case VaultError.authenticationFailed, VaultError.corruptItemData:
            return "A remote item failed verification and was not applied."
        case SyncError.unauthorized:
            return "GitHub rejected the token. Check it has Contents read/write on the repository."
        case let e as LocalizedError:
            return e.errorDescription ?? "\(error)"
        default:
            return "\(error)"
        }
    }
}
