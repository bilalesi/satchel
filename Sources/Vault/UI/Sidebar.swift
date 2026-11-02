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
        // The footer is a row under the list, not an overlay on it: rows never slide beneath it.
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
    }

    private var menuList: some View {
        List(selection: $selection) {
            Section("Vault") {
                row(.home, "Overview", .dashboard, .secureNote, nil)
                row(.all, "All items", .inbox, .login, session.items.count)
                row(.favorites, "Favorites", .starFull, .apiKey, session.items.filter(\.favorite).count)
                row(.recent, "Recent", .history, .dbCredential, nil)
            }
            Section {
                ForEach(session.categories) { c in
                    CategoryRow(category: c, count: session.items.filter { $0.categoryID == c.id }.count) { deleting = c }
                        .tag(SidebarSelection.category(c.id))
                }
                if draft != nil {
                    CategoryDraftRow(draft: Binding(get: { draft ?? CategoryDraft() }, set: { draft = $0 }),
                                     onCommit: commit, onCancel: { draft = nil })
                }
            } header: {
                HStack {
                    Text("Categories")
                    Spacer()
                    Button { startDraft() } label: { Icon(.add, size: 10) }
                        .buttonStyle(CircleButtonStyle(kind: .ghost, diameter: 22))
                        .help("New category")
                        .accessibilityLabel("New category")
                }
                .padding(.trailing, Theme.Space.xs)
            }
            Section("Types") {
                ForEach(ItemType.userTypes) { t in
                    let n = session.items.filter { $0.type == t }.count
                    Label {
                        HStack { Text(t.displayName); Spacer(); count(n) }
                    } icon: { IconTile(type: t, size: 18) }
                    .tag(SidebarSelection.type(t))
                }
            }
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.self) { tag in
                        Label { Text(tag) } icon: { Icon(.tag, size: 14).foregroundStyle(.secondary) }
                            .tag(SidebarSelection.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["SATCHEL_DEBUG_NEW_CATEGORY"] != nil { startDraft() } } // UI testing only
        #endif
        .onChange(of: session.newCategoryRequested) { _, requested in
            if requested { startDraft(); session.newCategoryRequested = false }
        }
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

    private func row(_ sel: SidebarSelection, _ title: String, _ icon: Codicon, _ tint: ItemType, _ n: Int?) -> some View {
        Label {
            HStack { Text(title); Spacer(); if let n { count(n) } }
        } icon: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.accent(tint))
                .frame(width: 18, height: 18)
                .overlay(Icon(icon, size: 11).foregroundStyle(.white))
        }
        .tag(sel)
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
    }
}

/// An existing category: edit its name and look in a card, choose whether this Mac syncs it, delete it.
private struct CategoryRow: View {
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    let category: CategoryInfo
    let count: Int
    let onDelete: () -> Void
    @State private var anchor = AnchorBox()

    var body: some View {
        let synced = sync.isSynced(category: category.id)
        Label {
            HStack(spacing: Theme.Space.xs + 2) {
                Text(category.name).lineLimit(1)
                if sync.isConfigured && !synced {
                    Icon(.lock, size: 10).foregroundStyle(.tertiary).help("Stays on this Mac")
                }
                Spacer()
                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: { CategoryTile(category: category) }
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
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.leading, Theme.Space.xs)
        .padding(.trailing, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }
}
