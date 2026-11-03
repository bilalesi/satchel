import Foundation
import Synchronization

/// How far this Mac's clock is from real time, so one-time codes match the site's.
///
/// A code changes every 30 seconds. A clock a few seconds slow keeps producing the previous code at the start of
/// each window, and its countdown shows time left on a code the site has already dropped. macOS normally keeps time
/// with network time, but a Mac with that off, or one that has not synced for a while, drifts.
///
/// The measurement comes from a request Satchel makes anyway (the update check): the server's `Date` header against
/// the local time halfway through the request. Nothing extra is sent anywhere. With update checks off, no correction.
public enum ClockSkew {
    /// Seconds to add to the local clock. 0 until measured, and while the measured error is too small to matter.
    private static let stored = Mutex<TimeInterval>(0)

    /// The Date header has one-second resolution and the request takes time: smaller errors are noise.
    static let threshold: TimeInterval = 2
    /// Beyond this the header is wrong (a proxy, a cached answer), not the clock: the reading is ignored.
    static let limit: TimeInterval = 600
    /// A slow request cannot place the server's time precisely enough.
    static let slowest: TimeInterval = 5

    public static var offset: TimeInterval { stored.withLock { $0 } }

    /// Real time as best known: the local clock plus the measured error.
    public static var now: Date { Date().addingTimeInterval(offset) }

    /// A local time (a TimelineView tick, for example) moved onto real time.
    public static func corrected(_ date: Date) -> Date { date.addingTimeInterval(offset) }

    /// Records a reading from a response. A reading that cannot be trusted leaves the previous one in place.
    @discardableResult
    public static func record(dateHeader: String?, age: String?, sent: Date, received: Date) -> TimeInterval? {
        guard let measured = measure(dateHeader: dateHeader, age: age, sent: sent, received: received) else { return nil }
        let applied = abs(measured) < threshold ? 0 : measured
        stored.withLock { $0 = applied }
        return applied
    }

    /// The clock's error from one response, or nil when the response cannot tell (pure, for tests).
    static func measure(dateHeader: String?, age: String?, sent: Date, received: Date) -> TimeInterval? {
        guard let dateHeader, let server = httpDate.date(from: dateHeader) else { return nil }
        // A cached answer carries the Date of when it was made, not of now.
        if let age, let seconds = Int(age.trimmingCharacters(in: .whitespaces)), seconds > 0 { return nil }
        let trip = received.timeIntervalSince(sent)
        guard trip >= 0, trip <= slowest else { return nil }
        // The header is truncated to the second: the server's real time is, on average, half a second later.
        let midpoint = sent.addingTimeInterval(trip / 2)
        let error = server.addingTimeInterval(0.5).timeIntervalSince(midpoint)
        return abs(error) > limit ? nil : error
    }

    /// RFC 9110 date, e.g. "Tue, 03 Nov 2026 15:35:28 GMT".
    nonisolated(unsafe) private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    #if DEBUG
    /// Tests only.
    static func reset() { stored.withLock { $0 = 0 } }
    #endif
}
