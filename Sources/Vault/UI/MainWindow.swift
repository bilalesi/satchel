import SwiftUI
import VaultCore

enum SidebarSelection: Hashable {
    case home, all, favorites, recent
    case type(ItemType)
    case tag(String)
    case category(UUID)
}

struct MainWindow: View {
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    @State private var selection: SidebarSelection? = .home
    @State private var selectedItem: UUID?
    @State private var query = ""
    @State private var editing: ItemOverview?
    @State private var creatingType: ItemType?
    @AppStorage("menuExpanded") private var menuExpanded = true

    var body: some View {
        Group {
            if session.state == .unlocked {
                workspace
            } else {
                UnlockView()
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .excludedFromCapture()
        .onChange(of: session.state) { _, s in if s != .unlocked { selectedItem = nil } }
    }

    /// Title band on top, then workspaces, menu, list and detail side by side.
    private var workspace: some View {
        VStack(spacing: 0) {
            TitleBand(query: $query, menuExpanded: $menuExpanded) { creatingType = $0 }
            HStack(spacing: 0) {
                WorkspaceRail()
                MenuColumn(selection: $selection, expanded: menuExpanded)
                HSplitView {
                    ItemList(filter: selection ?? .home, query: $query, selectedItem: $selectedItem)
                        .frame(minWidth: 280, idealWidth: 330, maxWidth: 480)
                    detail.frame(minWidth: 380, maxWidth: .infinity)
                }
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy(duration: 0.25), value: menuExpanded)
        .sheet(item: $creatingType) { t in
            ItemEditor(type: t, overview: nil, details: nil, defaultCategory: currentCategory) { o, d in
                session.save(o, d)
                selectedItem = o.id
            }
        }
        .sheet(item: $editing) { o in
            ItemEditor(type: o.type, overview: o, details: try? session.details(o.id), syncChoice: sync.choice(for: o.id)) { o2, d2 in
                session.save(o2, d2)
            }
        }
    }

    private var currentCategory: UUID? {
        if case .category(let id)? = selection { return id }
        return nil
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedItem, let overview = session.items.first(where: { $0.id == id }) {
            ItemDetailView(overview: overview, onEdit: { editing = overview })
                .id(id)
        } else if selection == .home || selection == nil {
            OverviewCards(onSelect: { selection = $0 })
        } else {
            EmptyState(icon: .key, title: "Select an item")
                .background(Theme.canvas)
        }
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
        case .category(let id): return base.filter { $0.categoryID == id }
        }
    }

    private var title: String {
        switch filter {
        case .home, .all: return "All items"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .type(let t): return t.displayName
        case .tag(let tag): return "#" + tag
        case .category(let id): return session.categories.first { $0.id == id }?.name ?? "Category"
        }
    }

    var body: some View {
        let list = items
        List(selection: $selectedItem) {
            Section {
                ForEach(list) { item in
                    ItemRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Copy \(Theme.label(item.type.primarySecretField))") { session.copyField(item.type.primarySecretField, of: item.id) }
                            if let u = item.username { Button("Copy username") { session.copy(u) } }
                            if item.type == .login { Button("Copy one-time code") { session.copyField("totp", of: item.id) } }
                            Divider()
                            Button(item.favorite ? "Remove from favorites" : "Add to favorites") { toggleFavorite(item) }
                        }
                }
            } header: {
                HStack {
                    Text(query.isEmpty ? title : "Results")
                    Spacer()
                    Text("\(list.count)").monospacedDigit()
                }
                .font(Theme.label).tracking(Theme.labelTracking).textCase(.uppercase)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .overlay {
            if list.isEmpty {
                EmptyState(icon: query.isEmpty ? .inbox : .search, title: query.isEmpty ? "No items yet" : "No matches")
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

/// One list row. The title gets layout priority; the date uses the narrow style ("2d ago").
struct ItemRow: View {
    let item: ItemOverview

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(type: item.type, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.xs) {
                    Text(item.title).font(Theme.body.weight(.medium)).lineLimit(1)
                    if item.favorite {
                        Icon(.starFull, size: 10).foregroundStyle(.yellow)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            Text(item.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(Theme.caption).foregroundStyle(.tertiary).monospacedDigit()
                .lineLimit(1).fixedSize()
        }
        .padding(.vertical, Theme.Space.xs)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        [item.username, item.hosts.first].compactMap { $0 }.joined(separator: " · ")
    }
}
