import SwiftUI
import VaultCore

/// The strip along the top of the window, level with the traffic lights: menu toggle on the left,
/// search in the middle, the actions on the right. Everything below it is columns. The strip is
/// 40 pt because that is where the system draws the window buttons, so they sit centred in it.
struct TitleBand: View {
    static let height: CGFloat = 40

    @EnvironmentObject var session: VaultSession
    @Binding var query: String
    @Binding var menuExpanded: Bool
    let onNew: (ItemType) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: Theme.Space.s) {
                Color.clear.frame(width: 72) // the traffic lights
                IconButton(menuExpanded ? .layoutSidebarLeft : .layoutSidebarLeftOff,
                           help: menuExpanded ? "Collapse the menu (⌃⌘S)" : "Expand the menu (⌃⌘S)", diameter: 28) {
                    withAnimation(.snappy(duration: 0.25)) { menuExpanded.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Spacer(minLength: Theme.Space.l)
                MenuButton(title: "New", icon: .add, kind: .primary) {
                    ItemType.userTypes.map { t in
                        MenuItem(title: t.displayName, icon: Theme.icon(t)) { onNew(t) }
                    } + [MenuItem(title: "Category", icon: .folder) { session.newCategoryRequested = true }]
                }
                .help("New item")
                Button { session.lock() } label: {
                    Icon(.lock, size: 14).frame(width: 30, height: 30).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassSurface(Circle(), interactive: true)
                .pointerStyle(.link)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Lock the vault (⇧⌘L)")
                .accessibilityLabel("Lock")
            }
            .padding(.horizontal, Theme.Space.m)
            search
        }
        .frame(height: Self.height)
    }

    private var search: some View {
        HStack(spacing: Theme.Space.s) {
            Icon(.search, size: 13).foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Icon(.close, size: 11).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).pointerStyle(.link).help("Clear").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 30)
        .frame(maxWidth: 380)
        .glassSurface(Capsule())
        .background { // ⌘F from anywhere
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        }
    }
}
