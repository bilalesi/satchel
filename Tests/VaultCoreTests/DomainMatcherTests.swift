import XCTest
@testable import VaultCore

final class DomainMatcherTests: XCTestCase {
    let m = DomainMatcher.shared

    func testBundledListLoads() {
        XCTAssertGreaterThan(m.ruleCount, 9000)
    }

    func testRegistrableDomains() {
        XCTAssertEqual(m.registrableDomain(of: "mail.google.com"), "google.com")
        XCTAssertEqual(m.registrableDomain(of: "Accounts.Google.com."), "google.com")
        XCTAssertEqual(m.registrableDomain(of: "a.b.co.uk"), "b.co.uk")
        XCTAssertEqual(m.publicSuffix(of: "a.b.co.uk"), "co.uk")
        XCTAssertEqual(m.registrableDomain(of: "www.ck"), "www.ck")          // exception !www.ck
        XCTAssertEqual(m.publicSuffix(of: "foo.bar.ck"), "bar.ck")           // wildcard *.ck
        XCTAssertEqual(m.registrableDomain(of: "foo.bar.ck"), "foo.bar.ck")
        XCTAssertEqual(m.registrableDomain(of: "user.github.io"), "user.github.io") // private section
        XCTAssertEqual(m.registrableDomain(of: "app.user.github.io"), "user.github.io")
        XCTAssertEqual(m.registrableDomain(of: "localhost"), "localhost")
        XCTAssertEqual(m.registrableDomain(of: "192.168.0.1"), "192.168.0.1")
        XCTAssertEqual(m.registrableDomain(of: "example.unknowntld"), "example.unknowntld")
        XCTAssertEqual(m.registrableDomain(of: "com"), "com")
    }

    func testPhishingLookalikeDoesNotMatch() {
        XCTAssertFalse(m.sameSite("accounts.google.com.evil.io", "accounts.google.com"))
        XCTAssertFalse(m.sameSite("google.com.au", "google.com"))
        XCTAssertFalse(m.sameSite("notgoogle.com", "google.com"))
        XCTAssertTrue(m.sameSite("accounts.google.com", "mail.google.com"))
    }

    func item(_ title: String, _ urls: [String], fav: Bool = false, type: ItemType = .login) -> ItemOverview {
        ItemOverview(type: type, title: title, urls: urls, favorite: fav)
    }

    func testRankingExactHostFirstAndLookalikesExcluded() {
        let items = [
            item("Google (mail)", ["https://mail.google.com"]),
            item("Google (accounts)", ["https://accounts.google.com/signin"], fav: true),
            item("Evil", ["https://accounts.google.com.evil.io"]),
            item("GitHub", ["github.com"]),
            item("Google API key", ["https://accounts.google.com"], type: .apiKey),
        ]
        let ranked = BrowserMatch.rank(items, for: URL(string: "https://accounts.google.com/v3/signin")!)
        XCTAssertEqual(ranked.map(\.title), ["Google (accounts)", "Google (mail)"])
        XCTAssertEqual(BrowserMatch.rank(items, for: URL(string: "https://accounts.google.com.evil.io/")!).map(\.title), ["Evil"])
        XCTAssertEqual(BrowserMatch.rank(items, for: URL(string: "https://www.github.com/login")!).map(\.title), ["GitHub"])
        XCTAssertEqual(BrowserMatch.rank(items, for: URL(string: "https://example.org")!), [])
    }

    func testHttpRules() {
        let secure = item("Router", ["https://192.168.1.1"])
        let plainRouter = item("Router plain", ["http://192.168.1.1"])
        let local = item("Dev", ["http://localhost:3000"])
        XCTAssertFalse(BrowserMatch.allowed(URL(string: "http://192.168.1.1/")!, for: secure))
        XCTAssertTrue(BrowserMatch.allowed(URL(string: "http://192.168.1.1/")!, for: plainRouter))
        XCTAssertTrue(BrowserMatch.allowed(URL(string: "http://localhost:3000/login")!, for: local))
        XCTAssertTrue(BrowserMatch.allowed(URL(string: "https://anything.example")!, for: secure))
        XCTAssertFalse(BrowserMatch.allowed(URL(string: "ftp://example.com")!, for: secure))
        XCTAssertEqual(BrowserMatch.rank([plainRouter, secure], for: URL(string: "http://192.168.1.1/")!).map(\.title), ["Router plain"])
    }

    func testFramingRoundTripAndLimits() throws {
        let a = Data(#"{"id":1}"#.utf8), b = Data(#"{"id":2,"x":"yy"}"#.utf8)
        let wire = NativeMessageFraming.frame(a) + NativeMessageFraming.frame(b)
        var dec = NativeMessageFraming.Decoder()
        // Feed in awkward chunks: frame a is 4 + 8 = 12 bytes, frame b is 4 + 17 = 21 bytes.
        dec.append(wire.prefix(3))
        XCTAssertNil(try dec.next())
        dec.append(wire.subdata(in: 3..<11))
        XCTAssertNil(try dec.next())
        dec.append(wire.subdata(in: 11..<15)) // completes a, starts b's header
        XCTAssertEqual(try dec.next(), a)
        XCTAssertNil(try dec.next())
        dec.append(wire.suffix(from: 15))
        XCTAssertEqual(try dec.next(), b)
        XCTAssertNil(try dec.next())
        // Three frames in one chunk drain in order.
        var dec2 = NativeMessageFraming.Decoder()
        dec2.append(wire + NativeMessageFraming.frame(a))
        XCTAssertEqual(try dec2.next(), a)
        XCTAssertEqual(try dec2.next(), b)
        XCTAssertEqual(try dec2.next(), a)
        XCTAssertNil(try dec2.next())
        var huge = NativeMessageFraming.Decoder()
        var len = UInt32(NativeMessageFraming.maxLength + 1).littleEndian
        huge.append(Data(bytes: &len, count: 4))
        XCTAssertThrowsError(try huge.next())
    }
}
