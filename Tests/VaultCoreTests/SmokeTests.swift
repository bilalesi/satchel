import XCTest
@testable import VaultCore

final class SmokeTests: XCTestCase {
    func testIdentity() {
        XCTAssertEqual(AppIdentity.bundleID, "com.bilalesi.satchel")
        XCTAssertTrue(AppIdentity.defaultVaultURL.path.hasSuffix("/Satchel/default.vault"))
    }
}
