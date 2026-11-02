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
    ]

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

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(category.color.gradient)
            .frame(width: size, height: size)
            .overlay(Icon(category.icon, size: (size * 0.58).rounded()).foregroundStyle(.white))
    }
}

/// Create or edit a category: name, icon, colour, and whether this Mac syncs it.
struct CategorySheet: View {
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    let existing: CategoryInfo?
    var onSaved: (UUID) -> Void = { _ in }

    @State private var name: String
    @State private var iconName: String
    @State private var colorName: String
    @State private var synced: Bool
    @State private var confirmDelete = false

    init(existing: CategoryInfo?, synced: Bool, onSaved: @escaping (UUID) -> Void = { _ in }) {
        self.existing = existing
        self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _iconName = State(initialValue: existing?.iconName ?? "folder")
        _colorName = State(initialValue: existing?.colorName ?? "blue")
        _synced = State(initialValue: synced)
    }

    private var preview: CategoryInfo {
        CategoryInfo(id: existing?.id ?? UUID(), name: name, iconName: iconName, colorName: colorName)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                CategoryTile(category: preview, size: 28)
                Text(existing == nil ? "New category" : "Edit category").font(Theme.headline)
                Spacer()
            }
            .padding(Theme.Space.l)
            Divider()
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Work, Personal, Servers…"))
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: Theme.Space.s), count: 8), spacing: Theme.Space.s) {
                        ForEach(CategoryStyle.icons, id: \.self) { icon in
                            Button { iconName = "\(icon)" } label: {
                                Icon(icon, size: 15)
                                    .frame(width: 36, height: 30)
                                    .background(iconName == "\(icon)" ? Color.accentColor.opacity(0.18) : Theme.hover,
                                                in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .pointerStyle(.link)
                            .accessibilityLabel("\(icon)")
                        }
                    }
                }
                Section("Colour") {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(CategoryStyle.palette, id: \.name) { entry in
                            Button { colorName = entry.name } label: {
                                Circle().fill(entry.color).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(colorName == entry.name ? 0.9 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .pointerStyle(.link)
                            .accessibilityLabel(entry.name)
                        }
                    }
                }
                if sync.isConfigured {
                    Section {
                        Toggle("Sync this category on this Mac", isOn: $synced)
                        Text("Leave it off to keep these items on this Mac only. Other Macs choose for themselves.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: Theme.Space.s) {
                if existing != nil {
                    PillButton("Delete", icon: .trash, kind: .danger) { confirmDelete = true }
                }
                Spacer()
                PillButton("Cancel", icon: .close, kind: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
                PillButton("Save", icon: .check, kind: .primary) { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 440, height: sync.isConfigured ? 560 : 480)
        .excludedFromCapture()
        .confirmationDialog("Delete “\(existing?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete category", role: .destructive) {
                if let existing { session.deleteCategory(existing.id) }
                dismiss()
            }
        } message: { Text("Its items are kept and become uncategorized.") }
    }

    private func save() {
        guard let id = session.saveCategory(id: existing?.id, name: name.trimmingCharacters(in: .whitespaces),
                                            iconName: iconName, colorName: colorName) else { return }
        sync.setSynced(category: id, synced)
        onSaved(id)
        dismiss()
    }
}
