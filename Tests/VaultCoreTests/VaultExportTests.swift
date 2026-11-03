import XCTest
@testable import VaultCore

final class VaultExportTests: XCTestCase {
    func testExportsEveryItemWithItsFieldsAndCategory() throws {
        let work = UUID()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let login = ItemOverview(type: .login, title: "GitHub", username: "me@example.com", urls: ["https://github.com"],
                                 tags: ["dev"], categoryID: work, favorite: true, createdAt: created, updatedAt: created)
        let note = ItemOverview(type: .secureNote, title: "Wi-Fi", categoryID: UUID(), createdAt: created, updatedAt: created)
        let data = try VaultExport.json(
            workspace: "Personal",
            items: [(login, ItemDetails(fields: ["password": "hunter2", "totpSeed": "", "notes": "a/b \"c\""],
                                        history: [SecretRevision(field: "password", value: "old")])),
                    (note, ItemDetails(fields: ["notes": "pass: 1234"]))],
            categories: [work: "Work"], now: created)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(VaultExport.File.self, from: data)
        XCTAssertEqual(file.format, "satchel-export")
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.workspace, "Personal")
        XCTAssertEqual(file.exportedAt, created)
        XCTAssertEqual(file.items.count, 2)
        let g = file.items[0]
        XCTAssertEqual(g.type, .login)
        XCTAssertEqual(g.title, "GitHub")
        XCTAssertEqual(g.username, "me@example.com")
        XCTAssertEqual(g.urls, ["https://github.com"])
        XCTAssertEqual(g.tags, ["dev"])
        XCTAssertEqual(g.category, "Work")
        XCTAssertTrue(g.favorite)
        XCTAssertEqual(g.fields, ["password": "hunter2", "notes": "a/b \"c\""], "empty fields are dropped")
        XCTAssertNil(file.items[1].category, "a category that no longer exists is left out")
        XCTAssertEqual(file.items[1].fields["notes"], "pass: 1234")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("old"), "secret history is not exported")
    }
}
