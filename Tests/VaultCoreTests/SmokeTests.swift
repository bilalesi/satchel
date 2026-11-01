import XCTest
@testable import VaultCore

final class SmokeTests: XCTestCase {
    func testIdentity() {
        XCTAssertEqual(AppIdentity.bundleID, "com.bilalesi.vault")
        XCTAssertTrue(AppIdentity.defaultVaultURL.path.hasSuffix("/Vault/default.vault"))
    }
}
