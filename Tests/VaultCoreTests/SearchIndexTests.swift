import XCTest
@testable import VaultCore

final class SearchIndexTests: XCTestCase {
    let now = Date()

    func item(_ title: String, user: String? = nil, urls: [String] = [], apps: [String] = [],
              tags: [String] = [], fav: Bool = false, ageDays: Double = 0) -> ItemOverview {
        ItemOverview(type: .login, title: title, username: user, urls: urls, bundleIDs: apps, tags: tags,
                     favorite: fav, updatedAt: now.addingTimeInterval(-ageDays * 86400))
    }

    func testBundleIDMatchRanksFirstEvenWithEmptyQuery() {
        let idx = SearchIndex([
            item("Gmail", urls: ["mail.google.com"], fav: true),
            item("Discord", apps: ["com.hnc.Discord"], ageDays: 30),
            item("GitHub", ageDays: 1),
        ])
        XCTAssertEqual(idx.query("", frontmostBundleID: "com.hnc.Discord").map(\.title), ["Discord", "Gmail", "GitHub"])
        XCTAssertEqual(idx.query("").map(\.title), ["Gmail", "GitHub", "Discord"])
    }

    func testPrefixBeatsSubsequenceAndHostMatches() {
        let idx = SearchIndex([
            item("Gumroad login", ageDays: 0),            // "gml" subsequence
            item("Gmail", urls: ["mail.google.com"]),      // title prefix for "gm"
            item("Google Mail", urls: ["https://mail.google.com/mail/u/0"], ageDays: 2),
        ])
        XCTAssertEqual(idx.query("gm").first?.title, "Gmail")
        XCTAssertEqual(idx.query("google").map(\.title).first, "Google Mail")
        XCTAssertTrue(idx.query("mail.google").map(\.title).contains("Gmail"))
        // "gma" is a title prefix of Gmail only; a subsequence of the other two.
        XCTAssertEqual(idx.query("gma").map(\.title).first, "Gmail")
        XCTAssertEqual(idx.query("gma").count, 3)
        XCTAssertEqual(idx.query("gml").count, 3)
    }

    func testMultiTokenIsAndAndNoMatchIsEmpty() {
        let idx = SearchIndex([
            item("Gmail", user: "work@corp.com"),
            item("Gmail", user: "me@gmail.com"),
        ])
        XCTAssertEqual(idx.query("gmail work").map { $0.username ?? "" }, ["work@corp.com"])
        XCTAssertEqual(idx.query("gmail xyz").count, 0)
        XCTAssertEqual(idx.query("zzz").count, 0)
    }

    func testPasswordGenerator() {
        let p = PasswordGenerator.generate(length: 32)
        XCTAssertEqual(p.count, 32)
        XCTAssertNotEqual(p, PasswordGenerator.generate(length: 32))
        let noSym = PasswordGenerator.generate(length: 200, symbols: false)
        XCTAssertTrue(noSym.allSatisfy { $0.isLetter || $0.isNumber })
    }
}
