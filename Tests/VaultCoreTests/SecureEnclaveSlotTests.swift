import LocalAuthentication
import XCTest
@testable import VaultCore

final class SecureEnclaveSlotTests: XCTestCase {
    /// Prompts Touch ID; run manually with `VAULT_SE_TEST=1 swift test --filter SecureEnclaveSlotTests`.
    func testRoundTripIfAvailable() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VAULT_SE_TEST"] == "1", "interactive")
        try XCTSkipUnless(SecureEnclaveSlot.isAvailable, "no Secure Enclave / biometrics")
        let vk = VaultKey.generate()
        let ctx = LAContext()
        ctx.localizedReason = "Vault test"
        let slot = try SecureEnclaveSlot.make(vaultKey: vk, context: ctx)
        XCTAssertTrue(slot.isSecureEnclave)
        XCTAssertEqual(try SecureEnclaveSlot.unwrap(slot, context: ctx), vk)
    }

    func testErrorMapping() {
        XCTAssertEqual(SecureEnclaveSlot.map(LAError(.userCancel)), .cancelled)
        XCTAssertEqual(SecureEnclaveSlot.map(LAError(.biometryNotEnrolled)), .biometryUnavailable)
        XCTAssertEqual(SecureEnclaveSlot.map(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))), .biometryChanged)
        XCTAssertEqual(SecureEnclaveSlot.map(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled))), .cancelled)
    }

    func testMalformedSlotRejected() {
        XCTAssertThrowsError(try SecureEnclaveSlot.unwrap(.secureEnclave(keyData: Data(), wrappedKey: Data(count: 10)), context: LAContext())) {
            XCTAssertEqual($0 as? VaultError, .corruptHeader)
        }
        XCTAssertThrowsError(try SecureEnclaveSlot.unwrap(.password(params: .fresh(), wrappedKey: Data()), context: LAContext())) {
            XCTAssertEqual($0 as? VaultError, .authenticationFailed)
        }
    }
}
