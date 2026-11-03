import XCTest
import CryptoKit
@testable import VaultCore

final class UpdateFeedTests: XCTestCase {
    let sha = String(repeating: "ab", count: 32)
    let sig = Data(repeating: 7, count: 64).base64EncodedString()

    func feed(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var json: [String: Any] = [
            "version": "0.2.0", "url": "https://satchel.echospace.dev/download/Satchel-0.2.0.dmg", "size": 12_000_000,
            "sha256": sha, "signature": sig, "notes": "notes", "published": "2026-11-03T10:00:00Z",
        ]
        change(&json)
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testVersionOrdering() {
        XCTAssertTrue(AppVersion("0.1.9")! < AppVersion("0.1.10")!)
        XCTAssertTrue(AppVersion("v0.2")! > AppVersion("0.1.99")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertNil(AppVersion("1.x"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1.2.3.4.5"))
    }

    func testOffersANewerRelease() {
        let offer = UpdateFeed.parse(feed(), current: AppVersion("0.1.5")!)
        XCTAssertEqual(offer?.version, AppVersion("0.2.0"))
        XCTAssertEqual(offer?.dmgURL.absoluteString, "https://satchel.echospace.dev/download/Satchel-0.2.0.dmg")
        XCTAssertEqual(offer?.size, 12_000_000)
        XCTAssertEqual(offer?.sha256, sha)
        XCTAssertEqual(offer?.signature, sig)
        XCTAssertEqual(offer?.notes, "notes")
        XCTAssertEqual(offer?.published, ISO8601DateFormatter().date(from: "2026-11-03T10:00:00Z"))
        // Upper-case digest is accepted and normalised; JavaScript's toISOString() date too.
        let js = UpdateFeed.parse(feed { $0["sha256"] = self.sha.uppercased(); $0["published"] = "2026-11-03T10:00:00.250Z" }, current: AppVersion("0.1.5")!)
        XCTAssertEqual(js?.sha256, sha)
        XCTAssertNotNil(js?.published)
        // A feed without notes or a date still offers the update.
        XCTAssertNotNil(UpdateFeed.parse(feed { $0["notes"] = nil; $0["published"] = nil }, current: AppVersion("0.1.5")!))
    }

    func testIgnoresSameAndOlderVersions() {
        XCTAssertNil(UpdateFeed.parse(feed(), current: AppVersion("0.2.0")!))
        XCTAssertNil(UpdateFeed.parse(feed(), current: AppVersion("0.3.0")!))
    }

    func testRejectsDownloadsFromAnywhereElse() {
        let cur = AppVersion("0.1.0")!
        for url in ["https://evil.example.com/download/Satchel-0.2.0.dmg",
                    "http://satchel.echospace.dev/download/Satchel-0.2.0.dmg",
                    "https://satchel.echospace.dev:8443/download/Satchel-0.2.0.dmg",
                    "https://satchel.echospace.dev.evil.com/download/Satchel-0.2.0.dmg",
                    "https://github.com/ekhodev/satchel/releases/download/v0.2.0/Satchel-0.2.0.dmg",
                    "https://satchel.echospace.dev/download/Satchel-0.9.9.dmg",
                    "https://satchel.echospace.dev/other/Satchel-0.2.0.dmg",
                    "http://localhost:8000/Satchel-0.2.0.dmg"] {
            XCTAssertNil(UpdateFeed.parse(feed { $0["url"] = url }, current: cur), url)
        }
        XCTAssertNotNil(UpdateFeed.parse(feed { $0["url"] = "http://localhost:8000/Satchel-0.2.0.dmg" }, current: cur, allowLocal: true))
    }

    func testRejectsMalformedFeeds() {
        let cur = AppVersion("0.1.0")!
        let broken: [(inout [String: Any]) -> Void] = [
            { $0["version"] = "latest" }, { $0["version"] = nil }, { $0["url"] = nil },
            { $0["size"] = 0 }, { $0["size"] = UpdateFeed.maxDownloadBytes + 1 }, { $0["size"] = "12" },
            { $0["sha256"] = "abc" }, { $0["sha256"] = String(repeating: "zz", count: 32) }, { $0["sha256"] = nil },
            { $0["signature"] = "not base64!" }, { $0["signature"] = Data(count: 10).base64EncodedString() }, { $0["signature"] = nil },
        ]
        for (i, change) in broken.enumerated() { XCTAssertNil(UpdateFeed.parse(feed(change), current: cur), "case \(i)") }
        XCTAssertNil(UpdateFeed.parse(Data("not json".utf8), current: cur))
        XCTAssertNil(UpdateFeed.parse(Data("[]".utf8), current: cur))
    }

    func testSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let file = Data((0..<4096).map { UInt8($0 % 251) })
        let sig = try key.signature(for: file).base64EncodedString()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(UpdateSignature.verify(file, signature: sig, publicKey: pub))
        var tampered = file; tampered[10] ^= 1
        XCTAssertFalse(UpdateSignature.verify(tampered, signature: sig, publicKey: pub))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateSignature.verify(file, signature: sig, publicKey: other))
        XCTAssertFalse(UpdateSignature.verify(file, signature: "!!", publicKey: pub))
        XCTAssertFalse(UpdateSignature.verify(file, signature: sig, publicKey: ""))
    }
}
