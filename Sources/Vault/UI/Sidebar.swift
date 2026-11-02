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
                MenuRow(selection: $selection, target: .home, title: "Overview") { tile(.dashboard, .secureNote) }
                MenuRow(selection: $selection, target: .all, title: "All items", count: session.items.count) { tile(.inbox, .login) }
                MenuRow(selection: $selection, target: .favorites, title: "Favorites", count: session.items.filter(\.favorite).count) { tile(.starFull, .apiKey) }
                MenuRow(selection: $selection, target: .recent, title: "Recent") { tile(.history, .dbCredential) }

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
                    MenuRow(selection: $selection, target: .type(t), title: t.displayName,
                            count: session.items.filter { $0.type == t }.count) { IconTile(type: t, size: 18) }
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

    private func tile(_ icon: Codicon, _ tint: ItemType) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Theme.accent(tint))
            .frame(width: 18, height: 18)
            .overlay(Icon(icon, size: 11).foregroundStyle(.white))
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
/// filled; the row under the pointer is lightly filled.
private struct MenuRow<Leading: View>: View {
    @Binding var selection: SidebarSelection?
    let target: SidebarSelection
    let title: String
    var count: Int?
    var trailing: AnyView?
    @ViewBuilder var leading: Leading
    @State private var hovering = false

    var body: some View {
        let selected = selection == target
        Button { selection = target } label: {
            HStack(spacing: Theme.Space.s + 2) {
                leading
                Text(title).font(Theme.body).lineLimit(1)
                if let trailing { trailing }
                Spacer(minLength: Theme.Space.xs)
                if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 30)
            .background(selected ? Color.primary.opacity(0.10) : (hovering ? Color.primary.opacity(0.05) : .clear),
                        in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            CategoryTile(category: category)
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
                MenuPanelController.shared.showContent(anchor: view, placement: .trailing) { _ in
                    StylePickerCard(iconName: $draft.iconName, colorName: $draft.colorName)
                }
            } label: { LookTile(iconName: draft.iconName, colorName: draft.colorName, size: 18) }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .background(AnchorReader(box: anchor))
                .help("Choose icon and colour")
            TextField("Name, then Return", text: $draft.name)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .onExitCommand(perform: onCancel)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
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
            .help(syncHelp)
            .accessibilityLabel("\(AppIdentity.name) menu")
            if !vertical { Spacer() }
            UpdateIconButton()
            Button { openSettingsTab(nil) } label: { Icon(.settingsGear, size: 14) }
                .buttonStyle(CircleButtonStyle(kind: .ghost, diameter: 28))
                .help("Settings")
                .accessibilityLabel("Settings")
        }
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
                         syncNow: { Task { await sync.syncNow() } },
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
/// choices as the full menu, one glyph each, with the name in the tooltip.
struct CollapsedMenu: View {
    @EnvironmentObject var session: VaultSession
    @Binding var selection: SidebarSelection?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: Theme.Space.xs) {
                    item(.home, .dashboard, "Overview")
                    item(.all, .inbox, "All items")
                    item(.favorites, .starFull, "Favorites")
                    item(.recent, .history, "Recent")
                    if !session.categories.isEmpty {
                        rule
                        ForEach(session.categories) { c in
                            item(.category(c.id), c.icon, c.name, tint: c.color)
                        }
                    }
                    rule
                    ForEach(ItemType.userTypes) { t in
                        item(.type(t), Theme.icon(t), t.displayName, tint: Theme.accent(t))
                    }
                }
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            SidebarFooter(vertical: true)
        }
    }

    private var rule: some View {
        Divider().padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
    }

    private func item(_ sel: SidebarSelection, _ icon: Codicon, _ title: String, tint: Color? = nil) -> some View {
        let selected = selection == sel
        return Button { selection = sel } label: {
            Icon(icon, size: 15)
                .foregroundStyle(tint ?? (selected ? Color.primary : Color.secondary))
                .frame(width: 36, height: 34)
                .background(selected ? Color.primary.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.rowRadius + 2, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
