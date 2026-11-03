import XCTest
@testable import VaultCore

final class LegacyIdentityTests: XCTestCase {
    let old = "com.example.old.\(UUID().uuidString)"
    let new = "com.example.new.\(UUID().uuidString)"
    let defaults = UserDefaults.standard

    override func tearDown() {
        defaults.removePersistentDomain(forName: old)
        defaults.removePersistentDomain(forName: new)
    }

    func testCopiesOldPreferencesAndRenamesBundleKeyedOnes() {
        defaults.setPersistentDomain(["licenseKey": "SATCHEL-x", "\(old).deviceID": "id-1"], forName: old)
        XCTAssertTrue(LegacyIdentity.migrateDefaults(from: old, to: new, defaults: defaults))
        let moved = defaults.persistentDomain(forName: new) ?? [:]
        XCTAssertEqual(moved["licenseKey"] as? String, "SATCHEL-x")
        XCTAssertEqual(moved["\(new).deviceID"] as? String, "id-1")
        XCTAssertNil(moved["\(old).deviceID"])
    }

    func testLeavesExistingNewPreferencesAlone() {
        defaults.setPersistentDomain(["licenseKey": "old"], forName: old)
        defaults.setPersistentDomain(["licenseKey": "new"], forName: new)
        XCTAssertFalse(LegacyIdentity.migrateDefaults(from: old, to: new, defaults: defaults))
        XCTAssertEqual(defaults.persistentDomain(forName: new)?["licenseKey"] as? String, "new")
    }

    func testNothingToCopy() {
        XCTAssertFalse(LegacyIdentity.migrateDefaults(from: old, to: new, defaults: defaults))
        XCTAssertNil(defaults.persistentDomain(forName: new))
    }
}
