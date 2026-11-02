import AppKit
import Foundation
import VaultCore

/// Answers extension requests using the session. The origin allowlist and the
/// origin ↔ item re-check happen here, never in the extension.
@MainActor
final class BridgeHandler {
    private let session: VaultSession

    init(session: VaultSession) {
        self.session = session
    }

    func handle(_ req: BridgeRequest) async -> BridgeResponse {
        guard let origin = req.origin, BrowserIntegration.allowedOrigins.contains(origin) else {
            return .failure(req.id, "origin_not_allowed")
        }
        switch req.type {
        case "hello", "status":
            return status(req.id)
        case "unlock":
            if session.state == .locked {
                let ok = await session.unlockWithBiometrics()
                if !ok, session.state != .unlocked { AppDelegate.openMainWindow() }
            } else if session.state == .noVault {
                AppDelegate.openMainWindow()
            }
            return status(req.id)
        case "match":
            guard session.state == .unlocked else { return status(req.id) }
            guard let url = req.url.flatMap(URL.init(string:)) else { return .failure(req.id, "bad_url") }
            var r = status(req.id)
            r.items = BrowserMatch.rank(session.items, for: url).map(bridgeItem)
            return r
        case "fill":
            guard session.state == .unlocked else { return status(req.id) }
            guard let url = req.url.flatMap(URL.init(string:)), let id = req.itemID else { return .failure(req.id, "bad_request") }
            // The page may only receive an item that matches it; the extension's word is not enough.
            guard let item = BrowserMatch.rank(session.items, for: url).first(where: { $0.id == id }) else {
                return .failure(req.id, "origin_mismatch")
            }
            do {
                let details = try session.details(id)
                guard let password = details.fields["password"], !password.isEmpty else { return .failure(req.id, "no_password") }
                var r = status(req.id)
                r.credential = BridgeCredential(username: item.username, password: password,
                                                totp: details.fields["totpSeed"].flatMap(TOTP.init)?.code())
                return r
            } catch {
                return .failure(req.id, error.localizedDescription)
            }
        case "save":
            guard session.state == .unlocked else { return status(req.id) }
            guard let url = req.url.flatMap(URL.init(string:)), let host = BrowserMatch.pageHost(url),
                  let password = req.password, !password.isEmpty else { return .failure(req.id, "bad_request") }
            let site = DomainMatcher.shared.registrableDomain(of: host)
            let scheme = url.scheme?.lowercased() ?? "https"
            let overview = ItemOverview(type: .login, title: req.title?.isEmpty == false ? req.title! : site,
                                        username: req.username?.isEmpty == false ? req.username : nil,
                                        urls: ["\(scheme)://\(host)"], tags: ["browser"])
            session.save(overview, ItemDetails(fields: ["password": password]))
            var r = status(req.id)
            r.items = [BridgeItem(overview)]
            return r
        case "search":
            guard session.state == .unlocked else { return status(req.id) }
            let query = (req.query ?? "").trimmingCharacters(in: .whitespaces)
            var r = status(req.id)
            r.items = query.isEmpty ? [] : session.search(query, limit: min(max(req.limit ?? 8, 1), 25)).map(bridgeItem)
            return r
        case "copy":
            // The app copies (concealed, cleared after the vault's timer): the secret never reaches the extension.
            guard session.state == .unlocked else { return status(req.id) }
            guard let id = req.itemID, let item = session.items.first(where: { $0.id == id }) else { return .failure(req.id, "no_item") }
            switch req.field {
            case "username":
                guard let u = item.username, !u.isEmpty else { return .failure(req.id, "no_username") }
                session.copy(u)
            case "password": session.copyField(item.type.primarySecretField, of: id)
            case "totp": session.copyField("totp", of: id)
            default: return .failure(req.id, "bad_field")
            }
            return status(req.id)
        case "code":
            guard session.state == .unlocked else { return status(req.id) }
            guard let id = req.itemID, let seed = try? session.details(id).fields["totpSeed"], let totp = TOTP(seed) else {
                return .failure(req.id, "no_code")
            }
            var r = status(req.id)
            r.code = totp.code()
            r.remaining = totp.period - Int(Date().timeIntervalSince1970) % totp.period
            return r
        case "lock":
            session.lock()
            return status(req.id)
        case "generate":
            // Copied by the app (concealed type + auto-clear); the password never reaches the extension.
            session.copy(PasswordGenerator.generate())
            return status(req.id)
        case "open":
            if req.target == "settings:sync" {
                UserDefaults.standard.set(SettingsView.Tab.sync.rawValue, forKey: "settingsTab")
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                AppDelegate.openMainWindow()
            }
            return status(req.id)
        default:
            return .failure(req.id, "unknown_type")
        }
    }

    private func status(_ id: Int) -> BridgeResponse {
        var r = BridgeResponse(id: id)
        r.locked = session.state != .unlocked
        r.version = BridgeResponse.version
        r.info = info()
        return r
    }

    private func bridgeItem(_ o: ItemOverview) -> BridgeItem {
        BridgeItem(o, category: o.categoryID.flatMap { id in session.categories.first { $0.id == id }?.name })
    }

    /// The workspace and sync lines of the popup. Counts and titles only while unlocked.
    private func info() -> BridgeInfo {
        let w = session.activeWorkspace
        let sync = session.sync
        let syncState: BridgeSync = {
            guard sync.isConfigured else { return BridgeSync(state: "off") }
            switch sync.status {
            case .off: return BridgeSync(state: "off")
            case .idle: return BridgeSync(state: "idle", backend: sync.config.displayName, last: sync.lastSyncAt?.timeIntervalSince1970)
            case .syncing: return BridgeSync(state: "syncing", backend: sync.config.displayName, last: sync.lastSyncAt?.timeIntervalSince1970)
            case .error(let m): return BridgeSync(state: "error", backend: sync.config.displayName, last: sync.lastSyncAt?.timeIntervalSince1970, error: m)
            }
        }()
        var i = BridgeInfo(workspace: w.name, workspaceIcon: w.look.icon, workspaceColor: w.look.color, sync: syncState)
        if session.state == .unlocked {
            let cutoff = Date().addingTimeInterval(-180 * 86400)
            let stale = session.items.filter { $0.updatedAt < cutoff }.sorted { $0.updatedAt < $1.updatedAt }
            i.items = session.items.count
            i.rotate = stale.count
            i.rotateTitles = stale.prefix(3).map(\.title)
            if sync.isConfigured { i.localOnly = session.items.filter { !sync.selection.includes($0) }.count }
        }
        return i
    }
}
