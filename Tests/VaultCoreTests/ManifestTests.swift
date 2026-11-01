import XCTest
@testable import VaultCore

final class ManifestTests: XCTestCase {
    let keys = VaultKeys(vaultKey: VaultKey.generate())

    func testMACRoundTripAndTamperRejected() throws {
        var m = Manifest(generation: 4, deviceID: UUID(), headerHash: ManifestFile.sha256(Data("hdr".utf8)))
        let id = UUID()
        m.set(version: 7, for: id)
        let data = try ManifestFile.encode(m, key: keys.manifest)
        let back = try ManifestFile.decode(data, key: keys.manifest)
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.version(of: id), 7)
        XCTAssertEqual(back.itemIDs, [id])

        var tampered = data
        tampered[2] ^= 0x01
        XCTAssertThrowsError(try ManifestFile.decode(tampered, key: keys.manifest)) {
            XCTAssertEqual($0 as? VaultError, .corruptManifest)
        }
        XCTAssertThrowsError(try ManifestFile.decode(data, key: keys.item)) {
            XCTAssertEqual($0 as? VaultError, .corruptManifest)
        }
        XCTAssertThrowsError(try ManifestFile.decode(Data(count: 5), key: keys.manifest))
    }

    func testRollbackDetected() {
        let m = Manifest(generation: 3, deviceID: UUID(), headerHash: Data())
        XCTAssertNoThrow(try m.checkNotRolledBack(against: 3))
        XCTAssertNoThrow(try m.checkNotRolledBack(against: 2))
        XCTAssertThrowsError(try m.checkNotRolledBack(against: 4)) {
            XCTAssertEqual($0 as? VaultError, .rollbackDetected(local: 4, remote: 3))
        }
    }

    func testSHA256KnownAnswer() {
        XCTAssertEqual(ManifestFile.sha256(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
