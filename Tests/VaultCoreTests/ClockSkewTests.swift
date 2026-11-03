import XCTest
@testable import VaultCore

final class ClockSkewTests: XCTestCase {
    // "Tue, 03 Nov 2026 15:35:28 GMT"
    let header = "Tue, 03 Nov 2026 15:35:28 GMT"
    let server = Date(timeIntervalSince1970: 1_793_720_128)

    override func tearDown() { ClockSkew.reset() }

    func testASlowClockIsMeasured() {
        // The Mac thinks it is 7 s earlier than the server; the request took 0.2 s.
        let sent = server.addingTimeInterval(-7.1), received = sent.addingTimeInterval(0.2)
        let error = ClockSkew.measure(dateHeader: header, age: nil, sent: sent, received: received)!
        XCTAssertEqual(error, 7.5, accuracy: 0.01) // 7.1 - 0.1 (half the trip) + 0.5 (header truncated to the second)
    }

    func testCodesFollowTheCorrection() {
        let totp = TOTP(secret: Data("12345678901234567890".utf8)) // RFC 6238 test secret
        let sent = server.addingTimeInterval(-20), received = sent
        ClockSkew.record(dateHeader: header, age: nil, sent: sent, received: received)
        XCTAssertEqual(ClockSkew.offset, 20.5, accuracy: 0.01)
        let local = Date()
        XCTAssertEqual(totp.code(at: ClockSkew.corrected(local)), totp.code(at: local.addingTimeInterval(20.5)))
    }

    func testSmallErrorsAreNoise() {
        ClockSkew.record(dateHeader: header, age: nil, sent: server.addingTimeInterval(-0.8), received: server.addingTimeInterval(-0.8))
        XCTAssertEqual(ClockSkew.offset, 0)
    }

    func testUntrustworthyReadingsAreIgnored() {
        let near = server.addingTimeInterval(-7)
        XCTAssertNil(ClockSkew.measure(dateHeader: header, age: "120", sent: near, received: near)) // cached answer
        XCTAssertNil(ClockSkew.measure(dateHeader: header, age: nil, sent: near, received: near.addingTimeInterval(9))) // slow trip
        XCTAssertNil(ClockSkew.measure(dateHeader: header, age: nil, sent: server.addingTimeInterval(-3600), received: server.addingTimeInterval(-3600))) // absurd
        XCTAssertNil(ClockSkew.measure(dateHeader: "yesterday", age: nil, sent: near, received: near))
        XCTAssertNil(ClockSkew.measure(dateHeader: nil, age: nil, sent: near, received: near))
        // An ignored reading keeps the last good one.
        ClockSkew.record(dateHeader: header, age: nil, sent: near, received: near)
        ClockSkew.record(dateHeader: header, age: "60", sent: near, received: near)
        XCTAssertEqual(ClockSkew.offset, 7.5, accuracy: 0.01)
    }
}
