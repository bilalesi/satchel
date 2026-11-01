import XCTest
@testable import VaultCore

final class ItemFileTests: XCTestCase {
    let keys = VaultKeys(vaultKey: VaultKey.generate())

    func sample() -> (ItemOverview, ItemDetails) {
        let o = ItemOverview(type: .login, title: "Gmail", username: "me@gmail.com",
                             urls: ["https://mail.google.com/x", "accounts.google.com"], tags: ["mail"])
        let d = ItemDetails(fields: ["password": "hunter2", "notes": "personal"])
        return (o, d)
    }

    func testRoundTrip() throws {
        let (o, d) = sample()
        let data = try ItemFile.encode(overview: o, details: d, version: 3, deleted: false, keys: keys)
        let header = try ItemFile.decodeHeader(data)
        XCTAssertEqual(header, ItemFileHeader(id: o.id, version: 3, updatedAt: o.updatedAt, deleted: false))
        let (h2, o2) = try ItemFile.decodeOverview(data, keys: keys)
        XCTAssertEqual(h2, header)
        XCTAssertEqual(o2, o)
        XCTAssertEqual(o2.hosts, ["mail.google.com", "accounts.google.com"])
        XCTAssertEqual(try ItemFile.decodeDetails(data, keys: keys), d)
    }

    func testSwappedIDFailsToDecrypt() throws {
        let (o, d) = sample()
        var data = try ItemFile.encode(overview: o, details: d, version: 1, deleted: false, keys: keys)
        data[4] ^= 0xff // first byte of the uuid inside the header (AAD)
        XCTAssertThrowsError(try ItemFile.decodeOverview(data, keys: keys)) {
            XCTAssertEqual($0 as? VaultError, .authenticationFailed)
        }
        XCTAssertThrowsError(try ItemFile.decodeDetails(data, keys: keys))
    }

    func testBumpedVersionFailsToDecrypt() throws {
        let (o, d) = sample()
        var data = try ItemFile.encode(overview: o, details: d, version: 1, deleted: false, keys: keys)
        data[27] = 9 // low byte of the big-endian version
        XCTAssertEqual(try ItemFile.decodeHeader(data).version, 9)
        XCTAssertThrowsError(try ItemFile.decodeOverview(data, keys: keys))
    }

    func testTombstoneHasNoDetails() throws {
        let (o, _) = sample()
        let data = try ItemFile.encode(overview: o, details: nil, version: 2, deleted: true, keys: keys)
        XCTAssertTrue(try ItemFile.decodeHeader(data).deleted)
        XCTAssertEqual(try ItemFile.decodeOverview(data, keys: keys).overview, o)
        XCTAssertThrowsError(try ItemFile.decodeDetails(data, keys: keys)) {
            XCTAssertEqual($0 as? VaultError, .corruptItemData)
        }
    }

    func testOverviewDoesNotNeedDetailsBytes() throws {
        let (o, d) = sample()
        let data = try ItemFile.encode(overview: o, details: d, version: 1, deleted: false, keys: keys)
        let overviewLen = Int(UInt32(bigEndianBytes: data[41..<45]))
        let truncated = data.prefix(45 + overviewLen)
        XCTAssertEqual(try ItemFile.decodeOverview(truncated, keys: keys).overview, o)
        XCTAssertThrowsError(try ItemFile.decodeDetails(truncated, keys: keys))
    }

    func testGarbageIsRejectedCleanly() {
        XCTAssertThrowsError(try ItemFile.decodeHeader(Data())) { XCTAssertEqual($0 as? VaultError, .corruptItemData) }
        XCTAssertThrowsError(try ItemFile.decodeOverview(Sodium.randomData(10), keys: keys))
        XCTAssertThrowsError(try ItemFile.decodeOverview(Sodium.randomData(200), keys: keys))
        var bad = Data("VIT1".utf8) + Data(count: 37)
        bad.append(contentsOf: UInt32(1_000_000).bigEndianBytes) // length past the end
        XCTAssertThrowsError(try ItemFile.decodeOverview(bad, keys: keys)) { XCTAssertEqual($0 as? VaultError, .corruptItemData) }
    }

    func testHistoryRecordsChangedSecretsOnly() {
        let old = ItemDetails(fields: ["password": "a", "notes": "n", "totpSeed": "s"])
        let new = ItemDetails(fields: ["password": "b", "notes": "changed note", "totpSeed": "s"])
        let merged = new.recordingChanges(from: old)
        XCTAssertEqual(merged.history.count, 1)
        XCTAssertEqual(merged.history[0].field, "password")
        XCTAssertEqual(merged.history[0].value, "a")
        // Cap at 10
        var d = old
        for i in 0..<15 {
            d = ItemDetails(fields: ["password": "p\(i)"]).recordingChanges(from: d)
        }
        XCTAssertEqual(d.history.count, ItemDetails.historyCap)
        XCTAssertEqual(d.history.first?.value, "p13")
    }
}
