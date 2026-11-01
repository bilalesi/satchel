import AppKit
import LocalAuthentication
import SwiftUI
import VaultCore

/// Facade over `VaultStore` for the UI. Owns lock state, the search index, Touch ID,
/// clipboard copies and auto-lock. Everything runs on the main actor; the only
/// blocking work (Touch ID prompt, Argon2) is pushed to a detached task.
@MainActor
final class VaultSession: ObservableObject {
    enum State: Equatable { case noVault, locked, unlocked }

    @Published private(set) var state: State = .noVault
    @Published private(set) var items: [ItemOverview] = []
    @Published private(set) var corruptIDs: [UUID] = []
    @Published private(set) var touchIDEnabled = false
    @Published var lastError: String?
    @Published private(set) var busy = false

    private(set) var store: VaultStore?
    private var index = SearchIndex([])
    private var autoLock: AutoLock?
    let vaultURL: URL
    let sync = SyncCoordinator()

    var touchIDAvailable: Bool { SecureEnclaveSlot.isAvailable }

    init(vaultURL: URL = AppSettings.vaultURL) {
        self.vaultURL = vaultURL
        if VaultStore.exists(at: vaultURL) {
            do {
                let s = try VaultStore.open(at: vaultURL)
                store = s
                touchIDEnabled = s.hasSecureEnclaveSlot
                state = .locked
            } catch {
                lastError = error.localizedDescription
                state = .noVault
            }
        }
        autoLock = AutoLock(idleSeconds: { TimeInterval(AppSettings.autoLockMinutes * 60) },
                            onLock: { [weak self] in self?.lock() })
        sync.attach(session: self)
    }

    /// Second Mac: pull the vault from the remote, then unlock it with the shared password.
    func connectExisting(config: RemoteConfig, password: String) async -> Bool {
        var ok = false
        await run {
            let remote = try config.makeStore()
            let pw = SecureBytes(utf8: password)
            let url = self.vaultURL
            let s = try await Task.detached(priority: .userInitiated) {
                try await SyncEngine.bootstrap(remote: remote, into: url, password: pw)
            }.value
            self.store = s
            self.touchIDEnabled = false
            try self.finishUnlock()
            self.sync.config = config
            ok = true
        }
        return ok
    }

    // MARK: Lock / unlock

    func createVault(password: String) async {
        await run {
            let pw = SecureBytes(utf8: password)
            let s = try await Self.offMain { try VaultStore.create(at: self.vaultURL, password: pw) }
            self.store = s
            self.touchIDEnabled = false
            try self.finishUnlock()
        }
    }

    func unlock(password: String) async {
        guard let store else { return }
        await run {
            let pw = SecureBytes(utf8: password)
            try await Self.offMain { try store.unlock(password: pw) }
            try self.finishUnlock()
        }
    }

    /// Returns false when the user cancelled or Touch ID is unusable (caller shows password).
    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard let store, let slot = store.secureEnclaveSlot else { return false }
        var ok = false
        await run {
            do {
                let vk = try await Self.offMain {
                    let ctx = LAContext()
                    ctx.localizedReason = "unlock \(AppIdentity.name)"
                    return try SecureEnclaveSlot.unwrap(slot, context: ctx)
                }
                try store.unlock(vaultKey: vk)
                try self.finishUnlock()
                ok = true
            } catch VaultError.cancelled {
                // silent
            } catch VaultError.biometryChanged {
                // Slot is dead; drop it so the UI stops offering Touch ID until re-enabled.
                self.touchIDEnabled = false
                throw VaultError.biometryChanged
            }
        }
        return ok
    }

    func lock() {
        guard state == .unlocked else { return }
        store?.lock()
        items = []
        index = SearchIndex([])
        state = .locked
    }

    private func finishUnlock() throws {
        state = .unlocked
        try reload()
        sync.requestSync(reason: "unlock", delay: 0)
    }

    func reload() throws {
        guard let store else { return }
        let result = try store.loadOverviews()
        items = result.items
        corruptIDs = result.corrupt
        index = SearchIndex(items)
        touchIDEnabled = store.hasSecureEnclaveSlot
    }

    // MARK: Touch ID

    func enableTouchID(password: String) async {
        guard let store else { return }
        await run {
            let pw = SecureBytes(utf8: password)
            // Re-prove the password: enabling a weaker unlock path requires the strong one.
            let vk = try await Self.offMain { () throws -> SecureBytes in
                guard let slot = store.header.slots.first(where: { $0.isPassword }) else { throw VaultError.corruptHeader }
                return try slot.unwrap(password: pw)
            }
            let slot = try await Self.offMain {
                let ctx = LAContext()
                ctx.localizedReason = "enable Touch ID for \(AppIdentity.name)"
                return try SecureEnclaveSlot.make(vaultKey: vk, context: ctx)
            }
            vk.wipe()
            try store.addSecureEnclaveSlot(slot)
            self.touchIDEnabled = true
        }
    }

    func disableTouchID() {
        guard let store else { return }
        do { try store.removeSecureEnclaveSlots(); touchIDEnabled = false }
        catch { lastError = error.localizedDescription }
    }

    func changePassword(old: String, new: String) async -> Bool {
        guard let store else { return false }
        var ok = false
        await run {
            let o = SecureBytes(utf8: old), n = SecureBytes(utf8: new)
            try await Self.offMain { try store.changePassword(old: o, new: n) }
            ok = true
        }
        return ok
    }

    // MARK: Items

    func details(_ id: UUID) throws -> ItemDetails {
        guard let store else { throw VaultError.locked }
        return try store.details(for: id)
    }

    func save(_ overview: ItemOverview, _ details: ItemDetails) {
        guard let store else { return }
        do { try store.save(overview: overview, details: details); try reload(); sync.requestSync(reason: "save") }
        catch { lastError = error.localizedDescription }
    }

    func delete(_ id: UUID) {
        guard let store else { return }
        do { try store.delete(id: id); try reload(); sync.requestSync(reason: "delete") }
        catch { lastError = error.localizedDescription }
    }

    func search(_ text: String, frontmostBundleID: String? = nil, limit: Int = 50) -> [ItemOverview] {
        index.query(text, frontmostBundleID: frontmostBundleID, limit: limit)
    }

    func copy(_ value: String) {
        Clipboard.copyConcealed(value, clearAfter: TimeInterval(AppSettings.clipboardSeconds))
    }

    /// Copies a secret field without keeping the decoded details around.
    func copyField(_ field: String, of id: UUID) {
        do {
            if let v = try details(id).fields[field], !v.isEmpty { copy(v) }
        } catch { lastError = error.localizedDescription }
    }

    // MARK: Helpers

    private func run(_ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await body() } catch { lastError = error.localizedDescription }
    }

    private static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }
}
