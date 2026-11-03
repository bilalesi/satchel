import XCTest
import CryptoKit
@testable import VaultCore

final class LicenseTests: XCTestCase {
    let signer = Curve25519.Signing.PrivateKey()
    var publicKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }

    func issue(_ payload: String, with key: Curve25519.Signing.PrivateKey? = nil) -> String {
        License.keyText(payload: payload, signature: try! (key ?? signer).signature(for: Data(payload.utf8)))
    }

    func day(_ s: String) -> Date { License.day(s)! }

    func testParsesAValidKey() {
        let l = License.parse(issue("1|family|2026-11-03|ord_42"), publicKey: publicKey)
        XCTAssertEqual(l, License(plan: .family, purchased: day("2026-11-03"), id: "ord_42"))
        XCTAssertEqual(l?.payload, "1|family|2026-11-03|ord_42")
        XCTAssertEqual(License.day(l!.updatesUntil), "2027-11-03")
    }

    func testToleratesWhitespaceFromAnEmail() {
        let key = issue("1|single|2026-01-31|a")
        let wrapped = "  " + key.prefix(20) + "\n" + key.dropFirst(20) + "\n"
        XCTAssertEqual(License.parse(String(wrapped), publicKey: publicKey)?.plan, .single)
    }

    func testRefusesBadSignatures() {
        let good = issue("1|single|2026-11-03|x")
        // Signed by another key.
        XCTAssertNil(License.parse(issue("1|single|2026-11-03|x", with: .init()), publicKey: publicKey))
        // Payload changed after signing (single → family), signature kept.
        let sig = good.split(separator: ".")[1]
        let forged = License.prefix + License.base64URLEncode(Data("1|family|2026-11-03|x".utf8)) + "." + sig
        XCTAssertNil(License.parse(forged, publicKey: publicKey))
        // No public key in the build, truncated, wrong prefix, garbage.
        XCTAssertNil(License.parse(good, publicKey: ""))
        XCTAssertNil(License.parse(String(good.dropLast(4)), publicKey: publicKey))
        XCTAssertNil(License.parse("VAULT-" + good.dropFirst(License.prefix.count), publicKey: publicKey))
        XCTAssertNil(License.parse("SATCHEL-...", publicKey: publicKey))
        XCTAssertNil(License.parse("", publicKey: publicKey))
    }

    func testRefusesSignedButMalformedPayloads() {
        for p in ["2|single|2026-11-03|x", "1|team|2026-11-03|x", "1|single|2026-02-30|x", "1|single|26-11-03|x",
                  "1|single|2026-11-03|", "1|single|2026-11-03", "1|single|2026-11-03|x|y"] {
            XCTAssertNil(License.parse(issue(p), publicKey: publicKey), p)
        }
    }

    func testUpdateWindow() {
        let l = License(plan: .single, purchased: day("2026-11-03"), id: "x")
        XCTAssertTrue(l.covers(release: day("2026-11-03")))
        XCTAssertTrue(l.covers(release: day("2027-11-03")))
        XCTAssertFalse(l.covers(release: day("2027-11-03").addingTimeInterval(1)))
        XCTAssertFalse(l.covers(release: day("2028-06-01")))
        XCTAssertTrue(l.covers(release: nil), "a feed without a date must not block an update")
    }

    func testFeedPublishDateDecidesRenewal() {
        let json: [String: Any] = [
            "version": "0.3.0", "url": "https://satchel.echospace.dev/download/Satchel-0.3.0.dmg", "size": 100,
            "sha256": String(repeating: "0", count: 64), "signature": Data(count: 64).base64EncodedString(),
            "published": "2027-12-01T10:00:00Z",
        ]
        let offer = UpdateFeed.parse(try! JSONSerialization.data(withJSONObject: json), current: AppVersion("0.2.0")!)
        XCTAssertNotNil(offer?.published)
        XCTAssertFalse(License(plan: .single, purchased: day("2026-11-03"), id: "x").covers(release: offer?.published))
        XCTAssertTrue(License(plan: .single, purchased: day("2027-01-01"), id: "x").covers(release: offer?.published))
    }

    func testTrialClock() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let t = Trial(started: start)
        let h: TimeInterval = 3600
        XCTAssertEqual(Trial.days, 7)
        XCTAssertEqual(t.daysLeft(now: start), 7)
        XCTAssertEqual(t.daysLeft(now: start + h), 7)
        XCTAssertEqual(t.daysLeft(now: start + 24 * h), 6)
        XCTAssertEqual(t.daysLeft(now: start + 6 * 24 * h + 1), 1)
        XCTAssertFalse(t.isOver(now: start + 6 * 24 * h + 1))
        XCTAssertTrue(t.isOver(now: t.ends()))
        XCTAssertEqual(t.daysLeft(now: t.ends()), 0)
        XCTAssertEqual(t.daysLeft(now: start + 400 * 24 * h), 0)
        XCTAssertEqual(t.daysLeft(now: start - 30 * 24 * h), 7, "a clock set back never shows more than 7 days")
    }

    func testTrialEndGate() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trial = Trial(started: start)
        let during = start + 3 * 86400, after = trial.ends() + 1
        let l = License(plan: .single, purchased: start, id: "x")
        XCTAssertTrue(License.allowsUse(enforced: true, license: nil, trial: trial, now: during))
        XCTAssertFalse(License.allowsUse(enforced: true, license: nil, trial: trial, now: after), "trial over, no licence: blocked")
        XCTAssertFalse(License.allowsUse(enforced: true, license: nil, trial: trial, now: trial.ends()))
        XCTAssertTrue(License.allowsUse(enforced: true, license: l, trial: trial, now: after))
        // A licence whose year of updates is over still allows use: you keep the version you have.
        XCTAssertTrue(License.allowsUse(enforced: true, license: l, trial: trial, now: l.updatesUntil + 400 * 86400))
        XCTAssertTrue(License.allowsUse(enforced: false, license: nil, trial: trial, now: after), "a build without a licence key checks nothing")
    }

    func testActivationLink() {
        let key = issue("1|single|2026-11-03|ord_7")
        let url = URL(string: "satchel://activate?key=\(key)")!
        XCTAssertEqual(License.key(fromActivationURL: url), key)
        XCTAssertEqual(License.parse(License.key(fromActivationURL: url)!, publicKey: publicKey)?.id, "ord_7")
        XCTAssertEqual(License.key(fromActivationURL: URL(string: "SATCHEL://Activate?ref=mail&key=\(key)")!), key)
        // Percent-encoded, as a mail client may rewrite it.
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(License.key(fromActivationURL: URL(string: "satchel://activate?key=\(encoded)")!), key)
        for other in ["satchel://activate", "satchel://activate?key=", "satchel://open?key=\(key)",
                      "https://activate?key=\(key)", "https://satchel.echospace.dev/activate?key=\(key)"] {
            XCTAssertNil(License.key(fromActivationURL: URL(string: other)!), other)
        }
    }

    func testFamilyKeysStillWorkButOnlyOnePlanIsShown() {
        let l = License.parse(issue("1|family|2026-11-03|old"), publicKey: publicKey)
        XCTAssertEqual(l?.plan, .family)
        XCTAssertEqual(l?.planName, "Satchel")
        XCTAssertEqual(License(plan: .single, purchased: day("2026-11-03"), id: "x").planName, "Satchel")
    }
}
