import XCTest
import CryptoKit
@testable import VaultCore

final class UpdateFeedTests: XCTestCase {
    let repo = "me/satchel"

    func release(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                 dmgURL: String? = nil, sigURL: String? = nil, size: Int = 12_000_000, dmgName: String? = nil) -> Data {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let base = "https://github.com/\(repo)/releases/download/\(tag)/"
        let json: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "body": "notes", "html_url": "https://github.com/\(repo)/releases/tag/\(tag)",
            "assets": [
                ["name": dmgName ?? "Satchel-\(v).dmg", "browser_download_url": dmgURL ?? base + "Satchel-\(v).dmg", "size": size],
                ["name": "Satchel-\(v).dmg.sig", "browser_download_url": sigURL ?? base + "Satchel-\(v).dmg.sig", "size": 90],
            ],
        ]
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
        let offer = UpdateFeed.parse(release(), current: AppVersion("0.1.5")!, repository: repo)
        XCTAssertEqual(offer?.version, AppVersion("0.2.0"))
        XCTAssertEqual(offer?.dmgURL.lastPathComponent, "Satchel-0.2.0.dmg")
        XCTAssertEqual(offer?.signatureURL.lastPathComponent, "Satchel-0.2.0.dmg.sig")
    }

    func testIgnoresSameOlderDraftAndPrerelease() {
        let cur = AppVersion("0.2.0")!
        XCTAssertNil(UpdateFeed.parse(release(), current: cur, repository: repo))
        XCTAssertNil(UpdateFeed.parse(release(tag: "v0.1.0"), current: cur, repository: repo))
        XCTAssertNil(UpdateFeed.parse(release(tag: "v0.3.0", draft: true), current: cur, repository: repo))
        XCTAssertNil(UpdateFeed.parse(release(tag: "v0.3.0", prerelease: true), current: cur, repository: repo))
    }

    func testRejectsAssetsFromOtherHostsOrRepositories() {
        let cur = AppVersion("0.1.0")!
        XCTAssertNil(UpdateFeed.parse(release(dmgURL: "https://evil.example.com/Satchel-0.2.0.dmg"), current: cur, repository: repo))
        XCTAssertNil(UpdateFeed.parse(release(dmgURL: "http://github.com/\(repo)/releases/download/v0.2.0/Satchel-0.2.0.dmg"), current: cur, repository: repo))
        XCTAssertNil(UpdateFeed.parse(release(dmgURL: "https://github.com/other/repo/releases/download/v0.2.0/Satchel-0.2.0.dmg"), current: cur, repository: repo))
        XCTAssertNil(UpdateFeed.parse(release(sigURL: "https://evil.example.com/x.sig"), current: cur, repository: repo))
    }

    func testRejectsMismatchedNamesAndHugeDownloads() {
        let cur = AppVersion("0.1.0")!
        XCTAssertNil(UpdateFeed.parse(release(dmgName: "Satchel-0.9.9.dmg"), current: cur, repository: repo))
        XCTAssertNil(UpdateFeed.parse(release(size: UpdateFeed.maxDownloadBytes + 1), current: cur, repository: repo))
        XCTAssertNil(UpdateFeed.parse(Data("not json".utf8), current: cur, repository: repo))
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
