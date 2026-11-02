import SwiftUI
import VaultCore

/// A user category as the UI sees it. Stored in the vault as an item of type `.category`
/// (title = name, fields `icon` and `color`), so it syncs like any other item.
struct CategoryInfo: Identifiable, Equatable {
    let id: UUID
    var name: String
    var iconName: String
    var colorName: String

    var icon: Codicon { CategoryStyle.icon(named: iconName) }
    var color: Color { CategoryStyle.color(named: colorName) }
}

enum CategoryStyle {
    static let icons: [Codicon] = [
        .folder, .briefcase, .home, .heart, .bookmark, .rocket, .flame, .globe, .key, .shield, .database, .server,
        .cloud, .terminal, .law, .mail, .creditCard, .gift, .book, .beaker, .organization, .layers, .tools,
        .library, .game, .mortarBoard, .lightbulb, .coffee, .package,
        .dashboard, .inbox, .starFull, .history, .account, .link, .note,
    ]

    /// Every icon the picker offers: Satchel's drawn ones first, then the stock set.
    static var allIconNames: [String] { SatchelGlyph.allCases.map(\.name) + icons.map { "\($0)" } }

    static let palette: [(name: String, color: Color)] = [
        ("blue", Color(red: 0.20, green: 0.47, blue: 0.96)),
        ("orange", Color(red: 0.96, green: 0.56, blue: 0.14)),
        ("green", Color(red: 0.20, green: 0.68, blue: 0.38)),
        ("purple", Color(red: 0.58, green: 0.38, blue: 0.90)),
        ("teal", Color(red: 0.12, green: 0.62, blue: 0.68)),
        ("red", Color(red: 0.90, green: 0.30, blue: 0.30)),
        ("pink", Color(red: 0.92, green: 0.40, blue: 0.64)),
        ("grey", Color(red: 0.52, green: 0.54, blue: 0.60)),
    ]

    static func icon(named name: String) -> Codicon { icons.first { "\($0)" == name } ?? .folder }
    static func color(named name: String) -> Color { palette.first { $0.name == name }?.color ?? palette[0].color }
}

struct CategoryTile: View {
    let category: CategoryInfo
    var size: CGFloat = 18

    var body: some View { LookTile(iconName: category.iconName, colorName: category.colorName, size: size) }
}
