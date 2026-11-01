import Foundation

/// Which items a page may see. Shared by the browser bridge (and later the credential
/// provider) so there is exactly one matching rule in the app.
public enum BrowserMatch {
    public static func pageHost(_ url: URL) -> String? {
        url.host?.lowercased()
    }

    /// Scheme rule: https always; http only for loopback or when the item itself was
    /// saved with an explicit `http://` URL for that exact host.
    public static func allowed(_ url: URL, for item: ItemOverview) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = pageHost(url) else { return false }
        switch scheme {
        case "https": return true
        case "http":
            if host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" { return true }
            return item.urls.contains { $0.lowercased().hasPrefix("http://") && URL(string: $0)?.host?.lowercased() == host }
        default: return false
        }
    }

    /// Items for a page, best first: exact host (2) beats same registrable domain (1);
    /// favorites, then most recently updated, break ties. Non-login types never match.
    public static func rank(_ items: [ItemOverview], for url: URL, matcher: DomainMatcher = .shared) -> [ItemOverview] {
        guard let host = pageHost(url) else { return [] }
        let site = matcher.registrableDomain(of: host)
        var scored: [(Int, ItemOverview)] = []
        for item in items where item.type == .login && allowed(url, for: item) {
            var best = 0
            for h in item.hosts {
                if h == host { best = max(best, 2) }
                else if matcher.registrableDomain(of: h) == site { best = max(best, 1) }
            }
            if best > 0 { scored.append((best, item)) }
        }
        scored.sort {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            if $0.1.favorite != $1.1.favorite { return $0.1.favorite }
            return $0.1.updatedAt > $1.1.updatedAt
        }
        return scored.map(\.1)
    }
}
