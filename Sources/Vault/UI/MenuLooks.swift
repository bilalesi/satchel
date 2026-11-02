import SwiftUI
import VaultCore

/// The built-in entries of the left menu (Overview, All items, Favorites, Recent and one per item type).
/// Each has a default look; the user can change its icon and colour, like a category's.
enum MenuEntry: String, CaseIterable, Identifiable {
    case home, all, favorites, recent
    case login, apiKey, dbCredential, webhook, secureNote, sshKey

    var id: String { rawValue }

    init?(selection: SidebarSelection) {
        switch selection {
        case .home: self = .home
        case .all: self = .all
        case .favorites: self = .favorites
        case .recent: self = .recent
        case .type(let t): self.init(type: t)
        case .tag, .category: return nil
        }
    }

    init?(type: ItemType) {
        switch type {
        case .login: self = .login
        case .apiKey: self = .apiKey
        case .dbCredential: self = .dbCredential
        case .webhook: self = .webhook
        case .secureNote: self = .secureNote
        case .sshKey: self = .sshKey
        case .category: return nil
        }
    }

    var title: String {
        switch self {
        case .home: return "Overview"
        case .all: return "All items"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .login: return ItemType.login.displayName
        case .apiKey: return ItemType.apiKey.displayName
        case .dbCredential: return ItemType.dbCredential.displayName
        case .webhook: return ItemType.webhook.displayName
        case .secureNote: return ItemType.secureNote.displayName
        case .sshKey: return ItemType.sshKey.displayName
        }
    }

    /// Icon (a `Codicon` case name) and colour (a `CategoryStyle.palette` name) it has until the user changes them.
    var defaultLook: MenuLook {
        switch self {
        case .home: return MenuLook(icon: "satchel.overview", color: "grey")
        case .all: return MenuLook(icon: "satchel.allItems", color: "blue")
        case .favorites: return MenuLook(icon: "satchel.favorites", color: "orange")
        case .recent: return MenuLook(icon: "satchel.recent", color: "green")
        case .login: return MenuLook(icon: "satchel.login", color: "blue")
        case .apiKey: return MenuLook(icon: "satchel.apiKey", color: "orange")
        case .dbCredential: return MenuLook(icon: "satchel.database", color: "green")
        case .webhook: return MenuLook(icon: "satchel.webhook", color: "purple")
        case .secureNote: return MenuLook(icon: "satchel.note", color: "grey")
        case .sshKey: return MenuLook(icon: "satchel.sshKey", color: "teal")
        }
    }
}

struct MenuLook: Codable, Equatable {
    var icon: String
    var color: String
}

/// The looks the user changed, kept on this Mac (UserDefaults, as JSON): a taste about this app, not
/// vault data, so it is neither encrypted nor synced. Only differences from the default are stored.
@MainActor
final class MenuLookStore: ObservableObject {
    static let shared = MenuLookStore()
    private static let key = "menuLooks"

    @Published private(set) var overrides: [String: MenuLook]
    /// Bumps on every change, so a preview can replay its motion when the icon changes.
    @Published private(set) var revision = 0

    private init() {
        overrides = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: MenuLook].self, from: $0) } ?? [:]
    }

    func look(_ entry: MenuEntry) -> MenuLook { overrides[entry.rawValue] ?? entry.defaultLook }
    func isCustomised(_ entry: MenuEntry) -> Bool { overrides[entry.rawValue] != nil }

    func set(_ entry: MenuEntry, icon: String? = nil, color: String? = nil) {
        var look = self.look(entry)
        if let icon { look.icon = icon }
        if let color { look.color = color }
        overrides[entry.rawValue] = look == entry.defaultLook ? nil : look
        changed()
    }

    func reset(_ entry: MenuEntry) {
        overrides[entry.rawValue] = nil
        changed()
    }

    private func changed() {
        revision += 1
        UserDefaults.standard.set(try? JSONEncoder().encode(overrides), forKey: Self.key)
    }
}

/// The tile of a built-in entry, in whatever look the user chose.
struct EntryTile: View {
    let entry: MenuEntry
    var size: CGFloat = 22
    @ObservedObject private var looks = MenuLookStore.shared

    var body: some View {
        let look = looks.look(entry)
        MotionTile(iconName: look.icon, colorName: look.color, size: size)
    }
}

/// Floating card to change the icon and colour of a built-in entry. Changes apply as you click.
struct MenuLookCard: View {
    let entry: MenuEntry
    let onDone: () -> Void
    @ObservedObject private var looks = MenuLookStore.shared

    var body: some View {
        let look = looks.look(entry)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                // The preview replays the icon's motion each time the icon changes.
                MotionTile(iconName: look.icon, colorName: look.color, size: 44)
                    .environment(\.iconPulse, looks.revision)
                Text(entry.title).font(Theme.headline)
                Spacer()
                if looks.isCustomised(entry) {
                    PillButton("Reset", icon: .refresh, kind: .ghost, compact: true) { looks.reset(entry) }
                }
            }
            StylePicker(iconName: Binding(get: { look.icon }, set: { looks.set(entry, icon: $0) }),
                        colorName: Binding(get: { look.color }, set: { looks.set(entry, color: $0) }))
            HStack {
                Spacer()
                PillButton("Done", icon: .check, kind: .primary, compact: true, action: onDone)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 300)
    }
}
