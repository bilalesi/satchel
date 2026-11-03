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
    /// Secrets only. Categories are kept apart in `categories`.
    @Published private(set) var items: [ItemOverview] = []
    @Published private(set) var categories: [CategoryInfo] = []
    /// Set by "New → Category"; the sidebar answers by opening its name row and clears it.
    @Published var newCategoryRequested = false
    /// Set by Settings → Vault → Play welcome; the main window answers by playing it and clears it.
    @Published var welcomeRequested = false
    @Published private(set) var corruptIDs: [UUID] = []
    @Published private(set) var touchIDEnabled = false
    @Published var lastError: String?
    @Published private(set) var busy = false

    private(set) var store: VaultStore?
    private var index = SearchIndex([])
    private var autoLock: AutoLock?
    private(set) var vaultURL: URL
    let sync = SyncCoordinator()
    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var activeWorkspaceID: UUID

    var activeWorkspace: Workspace { workspaces.first { $0.id == activeWorkspaceID } ?? workspaces[0] }

    var touchIDAvailable: Bool { SecureEnclaveSlot.isAvailable }

    init() {
        let loaded = WorkspaceStore.load()
        workspaces = loaded.list
        activeWorkspaceID = loaded.active
        vaultURL = loaded.list.first { $0.id == loaded.active }!.url
        openVault()
        autoLock = AutoLock(idleSeconds: { TimeInterval(AppSettings.autoLockMinutes * 60) },
                            onLock: { [weak self] in self?.lock() })
        sync.attach(session: self)
        #if DEBUG
        // UI development only: unlock a throwaway demo vault without typing. Compiled out of release builds.
        if let pw = ProcessInfo.processInfo.environment["SATCHEL_DEMO_PASSWORD"], state == .locked {
            Task { await unlock(password: pw) }
        }
        #endif
    }

    /// Second Mac: pull the vault from the remote, then unlock it with the shared password.
    func connectExisting(config: RemoteConfig, secret: String?, password: String) async -> Bool {
        var ok = false
        await run {
            // Same safety gate as Settings → Sync: a server that ignores conditional writes is refused.
            if config.needsConditionalWriteProbe { _ = try await self.sync.check(config, typedSecret: secret) }
            let remote = try config.makeStore(secret: secret)
            let pw = SecureBytes(utf8: password)
            let url = self.vaultURL
            let s = try await Task.detached(priority: .userInitiated) {
                try await SyncEngine.bootstrap(remote: remote, into: url, password: pw)
            }.value
            self.store = s
            self.touchIDEnabled = false
            try self.finishUnlock()
            try self.sync.apply(config, secret: secret, resetState: false)
            ok = true
        }
        return ok
    }

    /// Opens the vault at `vaultURL` (locked), or reports that none exists yet.
    private func openVault() {
        store = nil
        touchIDEnabled = false
        guard VaultStore.exists(at: vaultURL) else { state = .noVault; return }
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

    // MARK: Workspaces

    func switchWorkspace(_ id: UUID) {
        // While an unlock, create or connect is awaiting, it holds the old vault: switching now would
        // leave that vault unlocked in memory and mix its data into the other workspace.
        guard !busy, id != activeWorkspaceID, let target = workspaces.first(where: { $0.id == id }) else { return }
        lock()
        sync.vaultLocked()
        store = nil
        items = []; categories = []; corruptIDs = []
        lastError = nil
        activeWorkspaceID = id
        vaultURL = target.url
        WorkspaceStore.save(workspaces, active: id)
        openVault()
        NotchHUD.shared.show(title: target.name, detail: "Workspace switched")
    }

    /// Registers an empty workspace and switches to it; the lock screen then offers to create
    /// or connect its vault.
    @discardableResult
    func addWorkspace(named name: String, iconName: String, colorName: String) -> Workspace? {
        guard !busy else { return nil }
        let ws = Workspace(id: UUID(), name: name.trimmingCharacters(in: .whitespaces), path: WorkspaceStore.newPath(),
                           iconName: iconName, colorName: colorName)
        workspaces.append(ws)
        WorkspaceStore.save(workspaces, active: activeWorkspaceID)
        switchWorkspace(ws.id)
        return ws
    }

    func updateWorkspace(_ id: UUID, name: String, iconName: String, colorName: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        workspaces[i].name = clean
        workspaces[i].iconName = iconName
        workspaces[i].colorName = colorName
        WorkspaceStore.save(workspaces, active: activeWorkspaceID)
    }

    /// Takes the workspace off this Mac; its folder goes to the Trash. A remote copy is untouched.
    func removeWorkspace(_ id: UUID) {
        guard !busy, workspaces.count > 1, let ws = workspaces.first(where: { $0.id == id }) else { return }
        if id == activeWorkspaceID, let other = workspaces.first(where: { $0.id != id }) { switchWorkspace(other.id) }
        workspaces.removeAll { $0.id == id }
        WorkspaceStore.save(workspaces, active: activeWorkspaceID)
        do { if FileManager.default.fileExists(atPath: ws.path) { try FileManager.default.trashItem(at: ws.url, resultingItemURL: nil) } }
        catch { lastError = error.localizedDescription }
    }

    // MARK: Lock / unlock

    func createVault(password: String) async {
        await run {
            let pw = SecureBytes(utf8: password)
            let url = self.vaultURL
            let s = try await Self.offMain { try VaultStore.create(at: url, password: pw) }
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
        sync.vaultLocked()
        items = []
        categories = []
        index = SearchIndex([])
        state = .locked
    }

    private func finishUnlock() throws {
        state = .unlocked
        try reload()
        if let store { sync.vaultUnlocked(store) }
        sync.requestSync(reason: "unlock", delay: 0)
    }

    func reload() throws {
        guard let store else { return }
        let result = try store.loadOverviews()
        items = result.items.filter { $0.type != .category }
        categories = result.items.filter { $0.type == .category }.map { o in
            let fields = (try? store.details(for: o.id).fields) ?? [:]
            return CategoryInfo(id: o.id, name: o.title, iconName: fields["icon"] ?? "folder", colorName: fields["color"] ?? "blue")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    /// The category an item belongs to, if it still exists.
    func category(of item: ItemOverview) -> CategoryInfo? {
        item.categoryID.flatMap { id in categories.first { $0.id == id } }
    }

    /// Creates or updates a category. Returns its id.
    @discardableResult
    func saveCategory(id: UUID?, name: String, iconName: String, colorName: String) -> UUID? {
        guard let store else { return nil }
        let overview = categories.first { $0.id == id }.flatMap { _ in try? store.loadOverviews().items.first { $0.id == id } }
            ?? ItemOverview(id: id ?? UUID(), type: .category, title: name)
        var o = overview
        o.title = name
        do {
            try store.save(overview: o, details: ItemDetails(fields: ["icon": iconName, "color": colorName]))
            try reload()
            sync.requestSync(reason: "category")
            return o.id
        } catch { lastError = error.localizedDescription; return nil }
    }

    /// Deletes a category; its items stay and become uncategorized.
    func deleteCategory(_ id: UUID) {
        guard let store else { return }
        do {
            for var item in items where item.categoryID == id {
                item.categoryID = nil
                try store.save(overview: item, details: try store.details(for: item.id))
            }
            try store.delete(id: id)
            sync.forget(category: id)
            try reload()
            sync.requestSync(reason: "category deleted")
        } catch { lastError = error.localizedDescription }
    }

    func search(_ text: String, frontmostBundleID: String? = nil, limit: Int = 50) -> [ItemOverview] {
        index.query(text, frontmostBundleID: frontmostBundleID, limit: limit)
    }

    func copy(_ value: String) {
        Clipboard.copyConcealed(value, clearAfter: TimeInterval(AppSettings.clipboardSeconds))

    }

    /// Types a field into `app`. Returns an error message to show, or nil on success.
    func typeField(_ field: String, of id: UUID, into app: NSRunningApplication?) async -> String? {
        guard AppSettings.autoTypeEnabled else { return "Auto-type is off. Enable it in Settings → Security." }
        guard Licensing.shared.conveniencesOn else { return Licensing.endedMessage }
        guard let app else { return AutoTypeError.noTargetApp.errorDescription }
        do {
            let value: String?
            if field == "username" {
                value = items.first { $0.id == id }?.username
            } else {
                value = try details(id).fields[field]
            }
            guard let value, !value.isEmpty else { return "This item has no \(field)." }
            _ = try await AutoType.type(value, into: app)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Current one-time code for an item, if it has a TOTP seed.
    func oneTimeCode(of id: UUID) -> String? {
        guard let seed = try? details(id).fields["totpSeed"], let totp = TOTP(seed) else { return nil }
        return totp.code()
    }

    /// Copies a secret field without keeping the decoded details around.
    /// The pseudo-field "totp" copies the current one-time code.
    func copyField(_ field: String, of id: UUID) {
        if field == "totp" {
            if let code = oneTimeCode(of: id) { copy(code) } else { lastError = "This item has no one-time code." }
            return
        }
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
