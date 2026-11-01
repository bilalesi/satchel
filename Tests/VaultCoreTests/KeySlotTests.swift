import XCTest
@testable import VaultCore

final class KeySlotTests: XCTestCase {
    func testAEADRoundTripAndTamperDetection() throws {
        let key = VaultKey.generate()
        let msg = SecureBytes(utf8: "top secret")
        let aad = Data("header".utf8)
        let box = try AEAD.seal(msg, key: key, aad: aad)
        XCTAssertEqual(box.count, AEAD.nonceBytes + msg.count + AEAD.tagBytes)
        XCTAssertEqual(try AEAD.open(box, key: key, aad: aad), msg)

        // Wrong AAD
        XCTAssertThrowsError(try AEAD.open(box, key: key, aad: Data("other".utf8))) {
            XCTAssertEqual($0 as? VaultError, .authenticationFailed)
        }
        // Flipped ciphertext bit
        var bad = box
        bad[AEAD.nonceBytes] ^= 0x01
        XCTAssertThrowsError(try AEAD.open(bad, key: key, aad: aad))
        // Too short
        XCTAssertThrowsError(try AEAD.open(Data(count: 10), key: key, aad: aad)) {
            XCTAssertEqual($0 as? VaultError, .authenticationFailed)
        }
        // Empty plaintext is fine
        let empty = try AEAD.seal(SecureBytes(count: 0), key: key, aad: Data())
        XCTAssertEqual(try AEAD.open(empty, key: key, aad: Data()).count, 0)
    }

    func testSubkeysAreDistinctAndDeterministic() {
        let vk = VaultKey.generate()
        let a = VaultKey.subkey(vk, info: "item")
        let b = VaultKey.subkey(vk, info: "overview")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, VaultKey.subkey(vk, info: "item"))
        XCTAssertEqual(a.count, 32)
    }

    func testPasswordSlotRoundTripAndWrongPassword() throws {
        let vk = VaultKey.generate()
        let slot = try KeySlot.makePassword(SecureBytes(utf8: "correct horse"), vaultKey: vk)

        guard case let .password(params, wrapped) = slot else { return XCTFail("expected password slot") }
        XCTAssertEqual(params.memoryKiB, 262144)
        XCTAssertEqual(params.iterations, 3)
        XCTAssertEqual(params.parallelism, 1)
        XCTAssertEqual(params.salt.count, 16)
        XCTAssertEqual(wrapped.count, AEAD.nonceBytes + 32 + AEAD.tagBytes)

        XCTAssertEqual(try slot.unwrap(password: SecureBytes(utf8: "correct horse")), vk)
        XCTAssertThrowsError(try slot.unwrap(password: SecureBytes(utf8: "correct horsf"))) {
            XCTAssertEqual($0 as? VaultError, .authenticationFailed)
        }
    }

    func testHeaderRoundTripAndRejectsGarbage() throws {
        let vk = VaultKey.generate()
        let cheap = KDFParams(memoryKiB: 8192, iterations: 1, salt: Data(repeating: 7, count: 16))
        let slot = try KeySlot.makePassword(SecureBytes(utf8: "pw"), vaultKey: vk, params: cheap)
        let header = VaultHeader(slots: [slot])
        let data = try header.encoded()
        let back = try VaultHeader.decode(data)
        XCTAssertEqual(back, header)
        XCTAssertEqual(back.slots.count, 1)
        XCTAssertTrue(back.slots[0].isPassword)
        XCTAssertThrowsError(try VaultHeader.decode(Data("{}".utf8))) {
            XCTAssertEqual($0 as? VaultError, .corruptHeader)
        }
    }
}
