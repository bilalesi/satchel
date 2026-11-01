import Foundation

/// Public Suffix List lookup. "Same site" for autofill means the same registrable domain
/// (`mail.google.com` and `accounts.google.com` → `google.com`), never a substring match.
/// Reason: `accounts.google.com.evil.io` must not see Google credentials.
public struct DomainMatcher: Sendable {
    private let rules: Set<String>
    private let wildcards: Set<String>   // "ck" for the rule "*.ck"
    private let exceptions: Set<String>  // "www.ck" for the rule "!www.ck"

    /// The bundled list (ICANN + private sections), parsed once (~16k rules, a few ms).
    public static let shared: DomainMatcher = {
        let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return DomainMatcher(rules: text)
    }()

    public init(rules text: String) {
        var r = Set<String>(), w = Set<String>(), e = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            let rule = line.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
            if rule.hasPrefix("!") { e.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { w.insert(String(rule.dropFirst(2))) }
            else { r.insert(rule) }
        }
        rules = r; wildcards = w; exceptions = e
    }

    public var ruleCount: Int { rules.count + wildcards.count + exceptions.count }

    /// Longest matching rule wins; an exception rule beats the wildcard it carves out;
    /// with no match the last label is the suffix (the implicit `*` rule).
    public func publicSuffix(of host: String) -> String? {
        let labels = Self.labels(host)
        guard labels.count > 1, !Self.isIPAddress(host) else { return nil }
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            if exceptions.contains(candidate) {
                return i + 1 < labels.count ? labels[(i + 1)...].joined(separator: ".") : nil
            }
            if rules.contains(candidate) { return candidate }
            if i + 1 < labels.count, wildcards.contains(labels[(i + 1)...].joined(separator: ".")) { return candidate }
        }
        return labels.last
    }

    /// The suffix plus one label. A bare suffix, a single label or an IP returns itself.
    public func registrableDomain(of host: String) -> String {
        let normalised = Self.labels(host).joined(separator: ".")
        guard let suffix = publicSuffix(of: normalised) else { return normalised }
        let labels = Self.labels(normalised)
        let suffixCount = Self.labels(suffix).count
        guard labels.count > suffixCount else { return normalised }
        return labels[(labels.count - suffixCount - 1)...].joined(separator: ".")
    }

    public func sameSite(_ a: String, _ b: String) -> Bool {
        registrableDomain(of: a) == registrableDomain(of: b)
    }

    static func labels(_ host: String) -> [String] {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .split(separator: ".").map(String.init)
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}
