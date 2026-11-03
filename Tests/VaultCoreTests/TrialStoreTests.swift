import XCTest
@testable import VaultCore

final class TrialStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var store: TrialStore!
    let suite = "satchel-trial-tests-\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)!
        store = TrialStore(defaults: defaults, service: "com.ekhodev.satchel.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        store.removeFromKeychain()
        defaults.removePersistentDomain(forName: suite)
    }

    func requireKeychain() throws {
        guard store.saveToKeychain(Date()) else { throw XCTSkip("no login keychain available here") }
        store.removeFromKeychain()
    }

    func testFirstLaunchRecordsNowInBothPlaces() throws {
        try requireKeychain()
        let now = Date(timeIntervalSince1970: 1_800_000_000.5)
        XCTAssertEqual(store.start(now: now), now)
        XCTAssertEqual(defaults.object(forKey: TrialStore.key) as? Date, now)
        XCTAssertEqual(store.keychainDate(), now, "the Keychain copy round-trips exactly")
        XCTAssertEqual(store.start(now: now + 86400), now, "later launches keep the first date")
    }

    func testDeletedPreferencesDoNotRestartTheTrial() throws {
        try requireKeychain()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        _ = store.start(now: first)
        defaults.removeObject(forKey: TrialStore.key) // `defaults delete`, or a reinstall that clears preferences
        XCTAssertEqual(store.start(now: first + 10 * 86400), first)
        XCTAssertEqual(defaults.object(forKey: TrialStore.key) as? Date, first, "the preference copy is restored")
    }

    func testEarliestCopyWins() throws {
        try requireKeychain()
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        store.saveToKeychain(early + 5 * 86400)
        defaults.set(early, forKey: TrialStore.key)
        XCTAssertEqual(store.start(now: early + 6 * 86400), early)
        defaults.removeObject(forKey: TrialStore.key)
        store.removeFromKeychain()
        store.saveToKeychain(early)
        defaults.set(early + 5 * 86400, forKey: TrialStore.key)
        XCTAssertEqual(store.start(now: early + 6 * 86400), early)
    }

    func testAStartInTheFutureIsPulledBackToNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(now + 365 * 86400, forKey: TrialStore.key) // first launch with the clock set a year ahead
        XCTAssertEqual(store.start(now: now), now)
        XCTAssertTrue(Trial(started: store.start(now: now)).isOver(now: now + 8 * 86400))
    }

    func testLaterLaunchesKeepTheStart() {
        // Also where the Keychain refuses (no login keychain), the preference copy alone keeps the trial running.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(store.start(now: now), now)
        XCTAssertEqual(store.start(now: now + 3600), now)
    }
}
