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
            r.items = BrowserMatch.rank(session.items, for: url).map(BridgeItem.init)
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
                r.credential = BridgeCredential(username: item.username, password: password)
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
        case "generate":
            var r = status(req.id)
            r.password = PasswordGenerator.generate()
            return r
        case "open":
            AppDelegate.openMainWindow()
            return status(req.id)
        default:
            return .failure(req.id, "unknown_type")
        }
    }

    private func status(_ id: Int) -> BridgeResponse {
        var r = BridgeResponse(id: id)
        r.locked = session.state != .unlocked
        r.version = BridgeResponse.version
        return r
    }
}
