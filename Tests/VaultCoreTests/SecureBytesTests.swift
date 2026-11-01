import XCTest
@testable import VaultCore

final class SecureBytesTests: XCTestCase {
    func testRoundTrip() {
        let b = SecureBytes(copying: [1, 2, 3, 250])
        XCTAssertEqual(b.count, 4)
        XCTAssertEqual(Array(b.toData()), [1, 2, 3, 250])
        XCTAssertEqual(SecureBytes(utf8: "héllo").utf8String(), "héllo")
    }

    func testWipeZeroes() {
        let b = SecureBytes(copying: [9, 9, 9])
        XCTAssertFalse(b.isAllZero)
        b.wipe()
        XCTAssertTrue(b.isAllZero)
        XCTAssertEqual(Array(b.toData()), [0, 0, 0])
    }

    func testConstantTimeEquality() {
        XCTAssertEqual(SecureBytes(copying: [1, 2]), SecureBytes(copying: [1, 2]))
        XCTAssertNotEqual(SecureBytes(copying: [1, 2]), SecureBytes(copying: [1, 3]))
        XCTAssertNotEqual(SecureBytes(copying: [1, 2]), SecureBytes(copying: [1, 2, 3]))
        XCTAssertEqual(SecureBytes(count: 0), SecureBytes(count: 0))
    }

    func testRandomIsNotZero() {
        XCTAssertFalse(Sodium.random(32).isAllZero)
        XCTAssertNotEqual(Sodium.random(32), Sodium.random(32))
    }
}
