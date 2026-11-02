import Foundation
import Network
import os
import VaultCore

/// Decides *when* to sync; `SyncEngine` decides *what*. One run at a time, a request
/// during a run sets a dirty flag and re-runs once. Triggers: 2 s after a local change,
/// on unlock, every 15 minutes, on network regain, on config change.
///
/// The configuration and the "what to sync" selection belong to the unlocked vault (they are
/// stored encrypted inside it), so the coordinator loads them on unlock and forgets them on lock.
@MainActor
final class SyncCoordinator: ObservableObject {
    enum Status: Equatable {
        case off, idle, syncing, error(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var config: RemoteConfig = .off
    @Published private(set) var selection = SyncSelection()

    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "sync")
    private weak var session: VaultSession?
    private var debounce: Task<Void, Never>?
    private var running = false
    private var dirty = false
    private var periodic: Timer?
    private let monitor = NWPathMonitor()
    private var online = true

    init() {
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

    // MARK: Vault lifecycle

    /// Loads this vault's configuration and selection. Called right after unlock.
    func vaultUnlocked(_ store: VaultStore) {
        adoptLegacyConfig(into: store)
        config = RemoteConfig.load(from: store)
        selection = Self.loadSelection(store)
        status = config == .off ? .off : .idle
        lastReport = nil
        lastSyncAt = (try? store.loadSyncState())?.lastSyncAt
    }

    /// Builds before 0.2 kept the sync setting in UserDefaults for the whole app. The first vault
    /// unlocked afterwards takes it over, so an update does not switch sync off.
    private func adoptLegacyConfig(into store: VaultStore) {
        let key = "remoteConfig"
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        defer { UserDefaults.standard.removeObject(forKey: key) }
        guard RemoteConfig.load(from: store) == .off, let legacy = try? JSONDecoder().decode(RemoteConfig.self, from: data) else { return }
        try? legacy.persist(to: store)
    }

    /// Forgets everything that came from the vault and stops pending work.
    func vaultLocked() {
        debounce?.cancel()
        config = .off
        selection = SyncSelection()
        status = .off
        lastReport = nil
    }

    private static func loadSelection(_ store: VaultStore) -> SyncSelection {
        guard let json = try? store.localSecret(SyncSelection.secretName), let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(SyncSelection.self, from: data) else { return SyncSelection() }
        return s
    }

    // MARK: Changing settings

    /// Saves a new remote (and its credential) for this vault and syncs.
    func apply(_ newConfig: RemoteConfig, secret: String?) throws {
        guard let store = session?.store, store.isUnlocked else { throw VaultError.locked }
        if let name = newConfig.secretName, let secret, !secret.isEmpty { try store.setLocalSecret(name, secret) }
        try newConfig.persist(to: store)
        config = newConfig
        status = newConfig == .off ? .off : .idle
        lastReport = nil
        requestSync(reason: "configuration changed", delay: 0)
    }

    func updateSelection(_ new: SyncSelection) {
        guard let store = session?.store, store.isUnlocked, new != selection else { return }
        do {
            if new.isDefault { try store.setLocalSecret(SyncSelection.secretName, nil) }
            else { try store.setLocalSecret(SyncSelection.secretName, String(decoding: try JSONEncoder().encode(new), as: UTF8.self)) }
            selection = new
            requestSync(reason: "selection changed", delay: 1)
        } catch { session?.lastError = error.localizedDescription }
    }

    func hasSecret(for config: RemoteConfig) -> Bool {
        guard let name = config.secretName, let store = session?.store, store.isUnlocked else { return false }
        return ((try? store.localSecret(name)) ?? nil) != nil
    }

    // MARK: Running

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
        guard session?.store?.isUnlocked == true, isConfigured else { return }
        if running { dirty = true; return }
        running = true
        defer { running = false }
        // A request that arrives during a run is not dropped: run again until none is pending.
        repeat {
            dirty = false
            await runOnce()
        } while dirty && session?.store?.isUnlocked == true
    }

    private func runOnce() async {
        guard let session, let store = session.store, store.isUnlocked else { return }
        status = .syncing
        // .notice is persisted by the unified log; .info is not (kept for diagnosis).
        Self.log.notice("sync start: \(self.config.displayName, privacy: .public)")
        do {
            let config = self.config
            let selection = self.selection
            let report = try await Task.detached(priority: .utility) {
                let remote = try config.makeStore(secret: try config.resolveSecret(store: store))
                return try await SyncEngine(store: store, remote: remote, filter: selection).sync()
            }.value
            lastReport = report
            lastSyncAt = Date()
            status = .idle
            Self.log.notice("sync ok: pulled \(report.pulled) pushed \(report.pushed) conflicts \(report.conflicts) generation \(report.generation)")
            if report.pulled > 0 || report.conflicts > 0 { try session.reload() }
        } catch {
            let text = Self.describe(error, config: config)
            Self.log.error("sync failed: \(text, privacy: .public)")
            status = .error(text)
        }
    }

    // MARK: Testing a configuration

    /// Verifies a configuration is usable and safe: reachable, signed in, and (for HTTP object
    /// stores) enforcing conditional writes. Returns a sentence for the user, throws on failure.
    func check(_ config: RemoteConfig, typedSecret: String?) async throws -> String {
        let store = session?.store
        let remote = try await Task.detached { () throws -> RemoteStore in
            var secret = typedSecret?.isEmpty == false ? typedSecret : nil
            if secret == nil, let store { secret = try config.resolveSecret(store: store) }
            return try config.makeStore(secret: secret)
        }.value

        var lines: [String] = []
        switch remote {
        case let gh as GitHubStore: lines.append("Connected to \(try await gh.verify()).")
        case let dav as WebDAVStore: try await dav.verify(); lines.append("Signed in to \(dav.baseURL.host ?? "the server").")
        case let s3 as S3Store: try await s3.verify(); lines.append("Bucket \(s3.config.bucket) is reachable.")
        case let git as GitStore: try await git.verify(); lines.append("Repository is reachable.")
        default: lines.append("Folder reachable.")
        }
        if config.needsConditionalWriteProbe {
            switch try await remote.probeConditionalWrites() {
            case .enforced: lines.append("The server protects against overwriting changes from another device.")
            case .notEnforced(let why):
                throw SyncError.remote(status: 0, message: "This server does not protect against two devices overwriting each other (\(why)). Satchel will not use it. Pick a different server or another sync method.")
            }
        }
        let hasVault = try await remote.get(RemotePaths.manifest) != nil
        lines.append(hasVault ? "A vault is already there." : "No vault there yet; the first sync creates it.")
        return lines.joined(separator: " ")
    }

    func test(_ config: RemoteConfig, secret: String?) async -> String {
        do { return try await check(config, typedSecret: secret) }
        catch {
            let text = Self.describe(error, config: config)
            Self.log.error("test connection failed: \(text, privacy: .public)")
            return text
        }
    }

    static func describe(_ error: Error, config: RemoteConfig = .off) -> String {
        switch error {
        case VaultError.rollbackDetected(let local, let remote):
            return "The remote vault is older (generation \(remote)) than what this Mac last synced (\(local)). Refusing to roll back."
        case VaultError.corruptManifest:
            return "The remote manifest failed verification: it belongs to another vault or was modified."
        case VaultError.authenticationFailed, VaultError.corruptItemData:
            return "A remote item failed verification and was not applied."
        case SyncError.unauthorized:
            switch config {
            case .github: return "GitHub rejected the token. Check it has Contents read/write on the repository."
            case .webdav: return "The server rejected the username or password."
            case .s3: return "The storage service rejected the access key or secret."
            default: return "The remote rejected the credentials."
            }
        case SyncError.missingToken:
            return "No password or key is saved for this remote. Enter it in Settings → Sync."
        case let e as LocalizedError:
            return e.errorDescription ?? "\(error)"
        default:
            return "\(error)"
        }
    }
}
