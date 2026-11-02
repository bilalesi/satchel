import SwiftUI
import VaultCore

private struct CategoryDraft {
    var name = ""
    var iconName = "folder"
    var colorName = "blue"
}

struct Sidebar: View {
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    @Binding var selection: SidebarSelection?
    @State private var draft: CategoryDraft?
    @State private var deleting: CategoryInfo?

    var tags: [String] {
        Array(Set(session.items.flatMap(\.tags))).sorted()
    }

    var body: some View {
        // The rows scroll in their own clipped area and the footer is a row under it, so a long
        // list can never run beneath the footer. (The system sidebar List ignored its bottom edge.)
        VStack(spacing: 0) {
            menuList
            SidebarFooter(vertical: false)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete category", role: .destructive) {
                if let deleting {
                    if selection == .category(deleting.id) { selection = .all }
                    session.deleteCategory(deleting.id)
                }
            }
        } message: { Text("Its items are kept and become uncategorized.") }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["SATCHEL_DEBUG_NEW_CATEGORY"] != nil { startDraft() } } // UI testing only
        #endif
        .onChange(of: session.newCategoryRequested) { _, requested in
            if requested { startDraft(); session.newCategoryRequested = false }
        }
    }

    private var menuList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                MenuHeader(title: "Vault")
                MenuRow(selection: $selection, target: .home, title: "Overview", entry: .home) { EntryTile(entry: .home) }
                MenuRow(selection: $selection, target: .all, title: "All items", count: session.items.count, entry: .all) { EntryTile(entry: .all) }
                MenuRow(selection: $selection, target: .favorites, title: "Favorites", count: session.items.filter(\.favorite).count, entry: .favorites) { EntryTile(entry: .favorites) }
                MenuRow(selection: $selection, target: .recent, title: "Recent", entry: .recent) { EntryTile(entry: .recent) }

                MenuHeader(title: "Categories") {
                    Button { startDraft() } label: { Icon(.add, size: 10) }
                        .buttonStyle(CircleButtonStyle(kind: .ghost, diameter: 22))
                        .help("New category")
                        .accessibilityLabel("New category")
                }
                ForEach(session.categories) { c in
                    CategoryRow(category: c, selection: $selection,
                                count: session.items.filter { $0.categoryID == c.id }.count) { deleting = c }
                }
                if draft != nil {
                    CategoryDraftRow(draft: Binding(get: { draft ?? CategoryDraft() }, set: { draft = $0 }),
                                     onCommit: commit, onCancel: { draft = nil })
                }

                MenuHeader(title: "Types")
                ForEach(ItemType.userTypes) { t in
                    if let entry = MenuEntry(type: t) {
                        MenuRow(selection: $selection, target: .type(t), title: t.displayName,
                                count: session.items.filter { $0.type == t }.count, entry: entry) { EntryTile(entry: entry) }
                    }
                }

                if !tags.isEmpty {
                    MenuHeader(title: "Tags")
                    ForEach(tags, id: \.self) { tag in
                        MenuRow(selection: $selection, target: .tag(tag), title: tag) {
                            Icon(.tag, size: 14).foregroundStyle(.secondary).frame(width: 18, height: 18)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.s)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
        .clipped()
    }

    private func startDraft() {
        draft = CategoryDraft(colorName: CategoryStyle.palette[session.categories.count % CategoryStyle.palette.count].name)
    }

    private func commit(_ d: CategoryDraft) {
        let name = d.name.trimmingCharacters(in: .whitespaces)
        draft = nil
        guard !name.isEmpty, let id = session.saveCategory(id: nil, name: name, iconName: d.iconName, colorName: d.colorName) else { return }
        selection = .category(id)
    }
}

/// Section title of the menu ("Vault", "Categories"), with an optional control at its right edge.
private struct MenuHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title).font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            accessory
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: 22)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, 2)
    }
}

extension MenuHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// One selectable row of the menu: a leading tile, the title, an optional count. Selected rows are
/// filled; the row under the pointer is lightly filled. The tile plays its motion when the pointer
/// arrives and when the row becomes selected. A built-in `entry` can be given another icon and colour
/// from the row's context menu.
private struct MenuRow<Leading: View>: View {
    @Binding var selection: SidebarSelection?
    let target: SidebarSelection
    let title: String
    var count: Int?
    var trailing: AnyView?
    var entry: MenuEntry?
    @ViewBuilder var leading: Leading
    @State private var hovering = false
    @State private var pulse = 0
    @State private var anchor = AnchorBox()
    @ObservedObject private var looks = MenuLookStore.shared

    var body: some View {
        if let entry {
            row.contextMenu {
                Button("Change icon and colour…") { MenuLookEditor.show(entry, anchor: anchor.view) }
                if looks.isCustomised(entry) { Button("Reset to default") { looks.reset(entry) } }
            }
        } else {
            row
        }
    }

    private var row: some View {
        let selected = selection == target
        return Button { selection = target } label: {
            HStack(spacing: Theme.Space.s + 2) {
                leading.environment(\.iconPulse, pulse)
                Text(title).font(Theme.body).lineLimit(1)
                if let trailing { trailing }
                Spacer(minLength: Theme.Space.xs)
                if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 34)
            .background(selected ? Color.primary.opacity(0.10) : (hovering ? Color.primary.opacity(0.05) : .clear),
                        in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0; if $0 { pulse += 1 } }
        .onChange(of: selected) { _, now in if now { pulse += 1 } }
        .background(AnchorReader(box: anchor))
        .accessibilityAddTraits(selected ? .isSelected : [])
        #if DEBUG
        .onAppear { // UI testing only: open this entry's look card at launch
            guard let entry, ProcessInfo.processInfo.environment["SATCHEL_DEBUG_LOOK_EDITOR"] == entry.rawValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MenuLookEditor.show(entry, anchor: anchor.view) }
        }
        #endif
    }
}

/// Opens the card that changes a built-in entry's icon and colour, beside the menu.
enum MenuLookEditor {
    @MainActor
    static func show(_ entry: MenuEntry, anchor: NSView?) {
        guard let anchor else { return }
        MenuPanelController.shared.showContent(anchor: anchor, placement: .trailing) { close in
            MenuLookCard(entry: entry, onDone: close)
        }
    }
}

/// An existing category: edit its name and look in a card, choose whether this Mac syncs it, delete it.
private struct CategoryRow: View {
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    let category: CategoryInfo
    @Binding var selection: SidebarSelection?
    let count: Int
    let onDelete: () -> Void
    @State private var anchor = AnchorBox()

    var body: some View {
        let synced = sync.isSynced(category: category.id)
        MenuRow(selection: $selection, target: .category(category.id), title: category.name, count: count,
                trailing: sync.isConfigured && !synced
                    ? AnyView(Icon(.lock, size: 10).foregroundStyle(.tertiary).help("Stays on this Mac")) : nil) {
            MotionTile(iconName: category.iconName, colorName: category.colorName, size: 22)
        }
        .background(AnchorReader(box: anchor))
        .contextMenu {
            Button("Edit…") { edit() }
            if sync.isConfigured {
                Button(synced ? "Keep on this Mac only" : "Sync this category") { sync.setSynced(category: category.id, !synced) }
            }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    private func edit() {
        guard let view = anchor.view else { return }
        let c = category
        MenuPanelController.shared.showContent(anchor: view, placement: .trailing) { close in
            LookEditorCard(title: "Edit category", confirmTitle: "Save", namePlaceholder: "Category name",
                           name: c.name, iconName: c.iconName, colorName: c.colorName,
                           onConfirm: { name, icon, color in close(); session.saveCategory(id: c.id, name: name, iconName: icon, colorName: color) },
                           onCancel: close)
        }
    }
}

/// The row that appears when you press +: type the name and press Return. The tile is a button for
/// the icon and colour, already set to something that looks fine.
private struct CategoryDraftRow: View {
    @Binding var draft: CategoryDraft
    let onCommit: (CategoryDraft) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    @State private var anchor = AnchorBox()

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                guard let view = anchor.view else { return }
                // The card is anchored to the whole row, so it opens beside the menu and never covers
                // the field being typed in; typing resumes where it was when the card closes.
                MenuPanelController.shared.showContent(anchor: view, placement: .trailing, onDismiss: { focused = true }) { _ in
                    StylePickerCard(iconName: $draft.iconName, colorName: $draft.colorName)
                }
            } label: { LookTile(iconName: draft.iconName, colorName: draft.colorName, size: 22) }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .tooltip("Choose icon and colour")
            TextField("Name, then Return", text: $draft.name)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .onExitCommand(perform: onCancel)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .background(AnchorReader(box: anchor))
        .onAppear { focused = true }
    }
}

/// Bottom of the sidebar: the avatar that opens the main menu, then the update icon (only when
/// there is something to do) and Settings.
struct SidebarFooter: View {
    /// Stacked for the narrow collapsed rail, in a row for the full menu.
    let vertical: Bool
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    @EnvironmentObject var updates: UpdateManager
    @Environment(\.openSettings) private var openSettings
    @State private var anchor = AnchorBox()

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: Theme.Space.s)) : AnyLayout(HStackLayout(spacing: Theme.Space.s))
        layout {
            Button(action: openMenu) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 28, height: 28)
                    Circle().fill(syncColor).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2)).offset(x: 2, y: 2)
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .background(AnchorReader(box: anchor))
            .railHint(syncHelp)
            .accessibilityLabel("\(AppIdentity.name) menu")
            if !vertical { Spacer() }
            UpdateIconButton()
            Button { openSettingsTab(nil) } label: { Icon(.settingsGear, size: 14) }
                .buttonStyle(CircleButtonStyle(kind: .ghost, diameter: 28))
                .railHint("Settings")
                .accessibilityLabel("Settings")
        }
        .environment(\.sideTips, vertical)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .top) { Divider().padding(.horizontal, Theme.Space.s) }
    }

    private func openSettingsTab(_ tab: SettingsView.Tab?) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
        openSettings()
    }

    private func openMenu() {
        guard let view = anchor.view else { return }
        let content = MainMenuCard.Content(
            workspaceName: session.activeWorkspace.name, statusText: syncText, shortcutLabel: HotKey.shared.label,
            updateText: updateText, syncAvailable: sync.isConfigured, syncing: sync.status == .syncing)
        MenuPanelController.shared.showContent(anchor: view, placement: vertical ? .trailing : .above) { close in
            MainMenuCard(content: content,
                         syncNow: { Task { await sync.syncNow(announce: true) } },
                         quickAccess: { QuickAccessController.shared.toggle() },
                         checkForUpdates: { Task { await updates.check(manual: true) } },
                         workspaces: { openSettingsTab(.vault) },
                         settings: { openSettingsTab(nil) },
                         lock: { session.lock() },
                         quit: { NSApp.terminate(nil) },
                         close: close)
        }
    }

    private var syncColor: Color {
        switch sync.status {
        case .off: return .gray.opacity(0.6)
        case .idle: return .green
        case .syncing: return .blue
        case .error: return .red
        }
    }

    private var syncText: String {
        switch sync.status {
        case .off: return session.touchIDEnabled ? "Touch ID on · no sync" : "No sync"
        case .idle:
            if let d = sync.lastSyncAt { return "Synced " + d.formatted(.relative(presentation: .named)) }
            return "Sync ready"
        case .syncing: return "Syncing…"
        case .error: return "Sync error"
        }
    }

    private var syncHelp: String {
        if case .error(let m) = sync.status { return m }
        return "\(session.activeWorkspace.name): \(syncText)"
    }

    private var updateText: String {
        switch updates.state {
        case .available(let o), .downloading(let o, _), .ready(let o, _): return "\(o.version) available"
        case .checking: return "Checking…"
        case .failed: return "Failed"
        default: return updates.isAvailable ? "Up to date" : "Off"
        }
    }
}


/// The menu when collapsed: a slim rail of icons, like the left rail of the Codex app. The same
/// choices as the full menu, one glyph each, with the name in the tooltip. The glyphs play their motion
/// like the tiles of the full menu, and wear the same icon and colour.
struct CollapsedMenu: View {
    @EnvironmentObject var session: VaultSession
    @Binding var selection: SidebarSelection?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: Theme.Space.xs) {
                    ForEach([MenuEntry.home, .all, .favorites, .recent]) { entry in
                        RailItem(selection: $selection, target: selection(of: entry), title: entry.title, entry: entry)
                    }
                    if !session.categories.isEmpty {
                        rule
                        ForEach(session.categories) { c in
                            RailItem(selection: $selection, target: .category(c.id), title: c.name, iconName: c.iconName, colorName: c.colorName)
                        }
                    }
                    rule
                    ForEach(ItemType.userTypes) { t in
                        if let entry = MenuEntry(type: t) {
                            RailItem(selection: $selection, target: .type(t), title: t.displayName, entry: entry)
                        }
                    }
                }
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            SidebarFooter(vertical: true)
        }
    }

    private func selection(of entry: MenuEntry) -> SidebarSelection {
        switch entry {
        case .home: return .home
        case .all: return .all
        case .favorites: return .favorites
        default: return .recent
        }
    }

    private var rule: some View {
        Divider().padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
    }
}

/// One icon of the collapsed rail. A built-in entry takes its look from the store (and can be changed from
/// the context menu); a category brings its own.
private struct RailItem: View {
    @Binding var selection: SidebarSelection?
    let target: SidebarSelection
    let title: String
    var entry: MenuEntry?
    var iconName = ""
    var colorName = ""
    @ObservedObject private var looks = MenuLookStore.shared
    @State private var hovering = false
    @State private var pulse = 0
    @State private var anchor = AnchorBox()

    var body: some View {
        let selected = selection == target
        let look = entry.map { looks.look($0) } ?? MenuLook(icon: iconName, color: colorName)
        Button { selection = target } label: {
            MotionTile(iconName: look.icon, colorName: look.color, size: 28)
                .environment(\.iconPulse, pulse)
                .frame(width: 40, height: 38)
                .background(selected ? Color.primary.opacity(0.10) : (hovering ? Color.primary.opacity(0.05) : .clear),
                            in: RoundedRectangle(cornerRadius: Theme.rowRadius + 2, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0; if $0 { pulse += 1 } }
        .onChange(of: selected) { _, now in if now { pulse += 1 } }
        .background(AnchorReader(box: anchor))
        .sideTip(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if let entry {
                Button("Change icon and colour…") { MenuLookEditor.show(entry, anchor: anchor.view) }
                if looks.isCustomised(entry) { Button("Reset to default") { looks.reset(entry) } }
            }
        }
    }
}

/// The column of the menu: the full menu, or the icon rail, on one glass panel. It stays
/// rounded and a little inset from the window edges, as the system's floating sidebars do.
struct MenuColumn: View {
    @Binding var selection: SidebarSelection?
    let expanded: Bool

    static let expandedWidth: CGFloat = 232
    static let collapsedWidth: CGFloat = 56

    var body: some View {
        ZStack {
            if expanded {
                Sidebar(selection: $selection).transition(.opacity)
            } else {
                CollapsedMenu(selection: $selection).transition(.opacity)
            }
        }
        .frame(width: expanded ? Self.expandedWidth : Self.collapsedWidth)
        .clipShape(RoundedRectangle(cornerRadius: Theme.blockRadius, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: Theme.blockRadius, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 1)
    }
}
