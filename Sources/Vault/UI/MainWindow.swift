import SwiftUI
import VaultCore

enum SidebarSelection: Hashable {
    case home, all, favorites, recent
    case type(ItemType)
    case tag(String)
}

struct MainWindow: View {
    @EnvironmentObject var session: VaultSession
    @State private var selection: SidebarSelection? = .home
    @State private var selectedItem: UUID?
    @State private var query = ""
    @State private var editing: ItemOverview?
    @State private var creatingType: ItemType?

    var body: some View {
        Group {
            if session.state == .unlocked {
                NavigationSplitView {
                    Sidebar(selection: $selection)
                } content: {
                    ItemList(filter: selection ?? .home, query: $query, selectedItem: $selectedItem)
                } detail: {
                    detail
                }
                .searchable(text: $query, placement: .sidebar, prompt: "Search")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(ItemType.allCases, id: \.self) { t in
                                Button { creatingType = t } label: { Label(t.displayName, systemImage: Theme.symbol(t)) }
                            }
                        } label: { Label("New", systemImage: "plus") }
                    }
                    ToolbarItem {
                        Button { session.lock() } label: { Label("Lock", systemImage: "lock") }
                            .keyboardShortcut("l", modifiers: [.command, .shift])
                    }
                }
                .sheet(item: $creatingType) { t in
                    ItemEditor(type: t, overview: nil, details: nil) { o, d in
                        session.save(o, d)
                        selectedItem = o.id
                    }
                }
                .sheet(item: $editing) { o in
                    ItemEditor(type: o.type, overview: o, details: try? session.details(o.id)) { o2, d2 in
                        session.save(o2, d2)
                    }
                }
            } else {
                UnlockView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .excludedFromCapture()
        .onChange(of: session.state) { _, s in if s != .unlocked { selectedItem = nil } }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedItem, let overview = session.items.first(where: { $0.id == id }) {
            ItemDetailView(overview: overview, onEdit: { editing = overview })
                .id(id)
        } else if selection == .home || selection == nil {
            OverviewCards()
        } else {
            ContentUnavailableView("Select an item", systemImage: "key.viewfinder")
                .background(Theme.canvas)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var session: VaultSession
    @Binding var selection: SidebarSelection?

    var tags: [String] {
        Array(Set(session.items.flatMap(\.tags))).sorted()
    }

    var body: some View {
        List(selection: $selection) {
            Section("Vault") {
                row(.home, "Overview", "square.grid.2x2", .secureNote, nil)
                row(.all, "All items", "tray.full", .login, session.items.count)
                row(.favorites, "Favorites", "star", .apiKey, session.items.filter(\.favorite).count)
                row(.recent, "Recent", "clock", .dbCredential, nil)
            }
            Section("Types") {
                ForEach(ItemType.allCases) { t in
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
                        Label(tag, systemImage: "tag").tag(SidebarSelection.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppIdentity.name).font(.system(size: 12, weight: .semibold))
                    Text(session.touchIDEnabled ? "Touch ID on" : "Password only")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    private func row(_ sel: SidebarSelection, _ title: String, _ symbol: String, _ tint: ItemType, _ n: Int?) -> some View {
        Label {
            HStack { Text(title); Spacer(); if let n { count(n) } }
        } icon: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.accent(tint))
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
        }
        .tag(sel)
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
    }
}

struct ItemList: View {
    @EnvironmentObject var session: VaultSession
    let filter: SidebarSelection
    @Binding var query: String
    @Binding var selectedItem: UUID?

    var items: [ItemOverview] {
        let base = query.isEmpty ? session.items : session.search(query, limit: 500)
        switch filter {
        case .home, .all: return base
        case .favorites: return base.filter(\.favorite)
        case .recent: return Array(base.sorted { $0.updatedAt > $1.updatedAt }.prefix(20))
        case .type(let t): return base.filter { $0.type == t }
        case .tag(let tag): return base.filter { $0.tags.contains(tag) }
        }
    }

    var body: some View {
        List(items, selection: $selectedItem) { item in
            HStack(spacing: 10) {
                IconTile(type: item.type, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if item.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                    }
                    Text(subtitle(item)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(item.updatedAt, format: .relative(presentation: .named))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .tag(item.id)
            .contextMenu {
                Button("Copy \(Theme.label(item.type.primarySecretField))") { session.copyField(item.type.primarySecretField, of: item.id) }
                if let u = item.username { Button("Copy username") { session.copy(u) } }
                Divider()
                Button(item.favorite ? "Remove from favorites" : "Add to favorites") { toggleFavorite(item) }
            }
        }
        .listStyle(.inset)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No items yet" : "No matches", systemImage: "magnifyingglass")
            }
        }
    }

    private func subtitle(_ item: ItemOverview) -> String {
        [item.username, item.hosts.first].compactMap { $0 }.joined(separator: " · ")
    }

    private func toggleFavorite(_ item: ItemOverview) {
        var o = item
        o.favorite.toggle()
        if let d = try? session.details(item.id) { session.save(o, d) }
    }
}
