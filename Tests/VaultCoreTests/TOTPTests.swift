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

import CoreImage
@testable import VaultCore

final class AuthenticatorImportTests: XCTestCase {
    func testLabelFromOtpauthLink() {
        XCTAssertEqual(TOTP.label(of: "otpauth://totp/GitHub:alex-dev?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"),
                       TOTP.Label(issuer: "GitHub", account: "alex-dev"))
        XCTAssertEqual(TOTP.label(of: "otpauth://totp/alex%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Google%20Workspace"),
                       TOTP.Label(issuer: "Google Workspace", account: "alex@example.com"))
        XCTAssertEqual(TOTP.label(of: "otpauth://totp/Acme%20Corp:bob@corp.example?secret=JBSWY3DPEHPK3PXP"),
                       TOTP.Label(issuer: "Acme Corp", account: "bob@corp.example"))
        XCTAssertNil(TOTP.label(of: "JBSWY3DPEHPK3PXP"))
    }

    /// Draws a real QR code and reads it back, the way a screenshot of a site's 2FA page would be read.
    func testQRCodeRoundTrip() throws {
        let link = "otpauth://totp/Satchel:test@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Satchel"
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(link.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let cg = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        XCTAssertEqual(QRCode.decode(cg), [link])

        let png = try XCTUnwrap(NSBitmapImageRepCompat.png(cg))
        XCTAssertEqual(QRCode.decode(data: png), [link])
        XCTAssertNotNil(TOTP(link))
    }

    func testNoQRCodeInAnEmptyImage() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(QRCode.decode(try XCTUnwrap(ctx.makeImage())), [])
        XCTAssertEqual(QRCode.decode(data: Data("not an image".utf8)), [])
    }
}

private enum NSBitmapImageRepCompat {
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
