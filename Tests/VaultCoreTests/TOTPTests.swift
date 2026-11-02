import XCTest
@testable import VaultCore

final class TOTPTests: XCTestCase {
    // RFC 6238 Appendix B vectors (8 digits). SHA1 secret is "12345678901234567890".
    let sha1Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    func testRFC6238VectorsSHA1() {
        let t = TOTP(secret: TOTP.base32Decode(sha1Secret)!, digits: 8)
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 59)), "94287082")
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 1111111109)), "07081804")
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 1234567890)), "89005924")
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 20000000000)), "65353130")
    }

    func testRFC6238VectorsSHA256AndSHA512() {
        let s256 = Data("12345678901234567890123456789012".utf8)
        let s512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)
        XCTAssertEqual(TOTP(secret: s256, digits: 8, algorithm: .sha256).code(at: Date(timeIntervalSince1970: 59)), "46119246")
        XCTAssertEqual(TOTP(secret: s512, digits: 8, algorithm: .sha512).code(at: Date(timeIntervalSince1970: 59)), "90693936")
    }

    func testParsingBase32AndURI() {
        XCTAssertEqual(TOTP("gezd gnbv-gy3t qojq GEZDGNBVGY3TQOJQ")?.secret, Data("12345678901234567890".utf8))
        XCTAssertNil(TOTP("not base32 !!"))
        XCTAssertNil(TOTP(""))
        let uri = TOTP("otpauth://totp/Example:me%40x.com?secret=\(sha1Secret)&issuer=Example&digits=8&period=60&algorithm=SHA256")
        XCTAssertEqual(uri?.digits, 8)
        XCTAssertEqual(uri?.period, 60)
        XCTAssertEqual(uri?.algorithm, .sha256)
        XCTAssertEqual(TOTP("otpauth://totp/x?issuer=none"), nil)
    }

    func testSixDigitDefaultAndCountdown() {
        let t = TOTP(sha1Secret)!
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 59)).count, 6)
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(t.secondsRemaining(at: Date(timeIntervalSince1970: 59)), 1)
        XCTAssertEqual(t.secondsRemaining(at: Date(timeIntervalSince1970: 60)), 30)
    }
}
