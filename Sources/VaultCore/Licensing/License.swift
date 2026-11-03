import Foundation

/// An offline licence key: `SATCHEL-<payload>.<signature>`, both base64url. The payload is
/// `1|<plan>|<purchase date yyyy-MM-dd>|<id>` and the signature is Ed25519 over its exact bytes, checked
/// against the public key built into the app (the same check as update signatures, with its own key pair).
///
/// Licensing never touches the vault's keys or files: after the trial without a licence Satchel still unlocks
/// and exports every item; nothing is ever made unreadable.
public struct License: Equatable, Sendable {
    /// Only `single` is sold; `family` is still parsed so a key issued as one keeps working.
    public enum Plan: String, Sendable { case single, family }

    public static let prefix = "SATCHEL-"
    /// Each purchase includes this many years of updates; the version installed then is kept forever.
    public static let updateYears = 1

    public let plan: Plan
    public let purchased: Date
    public let id: String

    public init(plan: Plan, purchased: Date, id: String) {
        self.plan = plan
        self.purchased = purchased
        self.id = id
    }

    /// The last day a release may be published and still be covered by this licence.
    public var updatesUntil: Date {
        Self.calendar.date(byAdding: .year, value: Self.updateYears, to: purchased) ?? purchased
    }

    /// True when a release published at `date` is inside the update window. Unknown dates are covered:
    /// a feed that omits the date must not block an update (worst case, one free update).
    public func covers(release date: Date?) -> Bool {
        guard let date else { return true }
        return date <= updatesUntil
    }

    public var planName: String { "Satchel" }

    /// Whether Satchel may be used: with a licence, during the trial, or always in a build without a licence key.
    public static func allowsUse(enforced: Bool, license: License?, trial: Trial, now: Date = Date()) -> Bool {
        !enforced || license != nil || !trial.isOver(now: now)
    }

    /// The key in `satchel://activate?key=…` (the link on the thank-you page and in the purchase email).
    public static func key(fromActivationURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "satchel", url.host?.lowercased() == "activate",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty else { return nil }
        return key
    }

    /// The signed text. Changing it invalidates every key ever issued, so it stays exactly this.
    public var payload: String {
        "1|\(plan.rawValue)|\(Self.day(purchased))|\(id)"
    }

    /// Parses and verifies a key. Whitespace and line breaks (from pasting an email) are ignored.
    public static func parse(_ text: String, publicKey: String) -> License? {
        let key = text.filter { !$0.isWhitespace }
        guard key.hasPrefix(prefix), key.count < 512 else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let body = base64URLDecode(parts[0]), let sig = base64URLDecode(parts[1]),
              UpdateSignature.verify(body, signature: sig.base64EncodedString(), publicKey: publicKey) else { return nil }
        let fields = String(decoding: body, as: UTF8.self).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, fields[0] == "1", let plan = Plan(rawValue: fields[1]),
              let day = day(fields[2]), !fields[3].isEmpty else { return nil }
        return License(plan: plan, purchased: day, id: fields[3])
    }

    public enum Check: Equatable { case valid(License), testKey, invalid }

    /// Like `parse`, but tells a test key apart from a bad one. Test keys come from purchases with Paddle's test
    /// cards (its sandbox) and are signed with a separate key; they never activate a released app, or a test card
    /// would be a free licence. Recognising one lets the app say so instead of "not valid".
    public static func check(_ text: String, publicKey: String, testPublicKey: String) -> Check {
        if let license = parse(text, publicKey: publicKey) { return .valid(license) }
        if !testPublicKey.isEmpty, parse(text, publicKey: testPublicKey) != nil { return .testKey }
        return .invalid
    }

    /// Builds the key text from a payload and its signature (used by `scripts/license-key.swift` and tests).
    public static func keyText(payload: String, signature: Data) -> String {
        prefix + base64URLEncode(Data(payload.utf8)) + "." + base64URLEncode(signature)
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func day(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Strict `yyyy-MM-dd` in UTC; a day that does not exist (2026-02-30) is refused.
    static func day(_ text: String) -> Date? {
        let n = text.split(separator: "-").compactMap { Int($0) }
        guard n.count == 3, text.count == 10,
              let d = calendar.date(from: DateComponents(year: n[0], month: n[1], day: n[2])), day(d) == text else { return nil }
        return d
    }

    static func base64URLEncode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode<S: StringProtocol>(_ s: S) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }
}

/// The free trial: `days` days from the first launch, counted on this Mac only (start kept by `TrialStore`).
public struct Trial: Equatable, Sendable {
    public static let days = 7
    public let started: Date

    public init(started: Date) { self.started = started }

    public func ends(_ calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: Self.days, to: started) ?? started
    }

    public func isOver(now: Date = Date()) -> Bool { now >= ends() }

    /// Whole days left, rounded up, so "1 day left" lasts until the very end. Never negative, never above `days`.
    public func daysLeft(now: Date = Date()) -> Int {
        let seconds = ends().timeIntervalSince(now)
        return min(Self.days, max(0, Int((seconds / 86400).rounded(.up))))
    }
}
