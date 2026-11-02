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
    @AppStorage("listWidth") private var listWidth: Double = 330
    @AppStorage("didShowWelcome") private var didShowWelcome = false
    @State private var welcomeStart: Date?
    @State private var uiScale: CGFloat = 1
    @State private var windowWidth: CGFloat = 1040

    var body: some View {
        Group {
            if session.state == .unlocked {
                workspace
            } else {
                UnlockView()
            }
        }
        .scaleEffect(welcomeStart == nil ? 1 : uiScale)
        .overlay { if let start = welcomeStart { WelcomeSplash(start: start, onFinish: finishWelcome).ignoresSafeArea() } }
        .frame(minWidth: Responsive.minWindowWidth, minHeight: 480)
        .excludedFromCapture()
        .onChange(of: session.state) { _, s in if s != .unlocked { selectedItem = nil } }
        .onAppear { if shouldPlayWelcome { startWelcome() } }
        .onChange(of: session.welcomeRequested) { _, requested in
            if requested { session.welcomeRequested = false; startWelcome() }
        }
    }

    /// The welcome plays once, on the very first launch (no vault yet). Settings can replay it.
    private var shouldPlayWelcome: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SATCHEL_SPLASH"] != nil { return true } // UI testing only
        #endif
        return session.state == .noVault && !didShowWelcome
    }

    private func startWelcome() {
        guard welcomeStart == nil else { return }
        // Reduce Motion: no animation at all; the screen behind it is simply there.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { didShowWelcome = true; return }
        uiScale = 0.9
        welcomeStart = Date()
        Task {
            try? await Task.sleep(for: .seconds(SplashTiming.pushStart))
            withAnimation(.easeOut(duration: SplashTiming.pushEnd - SplashTiming.pushStart)) { uiScale = 1 }
        }
    }

    private func finishWelcome() {
        welcomeStart = nil
        uiScale = 1
        didShowWelcome = true
    }

    /// Title band on top, then workspaces, menu, list and detail side by side.
    private var workspace: some View {
        let layout = Responsive(width: windowWidth, menuExpanded: menuExpanded, preferredList: listWidth)
        return VStack(spacing: 0) {
            TitleBand(query: $query, menuExpanded: $menuExpanded, canExpand: layout.canExpandMenu) { creatingType = $0 }
            HStack(spacing: 0) {
                WorkspaceRail()
                // Menu, list and detail are separate rounded blocks with a gap between them.
                HStack(spacing: Theme.blockGap) {
                    MenuColumn(selection: $selection, expanded: layout.menuExpanded)
                    // The handle is the only space between list and detail: one gap, not three.
                    HStack(spacing: 0) {
                        ItemList(filter: selection ?? .home, query: $query, selectedItem: $selectedItem)
                            .frame(width: layout.listWidth)
                            .block()
                        SplitHandle(width: Binding(get: { layout.listWidth }, set: { listWidth = $0 }), range: layout.listRange)
                        detail.frame(minWidth: Responsive.detailMin, maxWidth: .infinity).block()
                    }
                }
                .padding(.trailing, Theme.blockGap)
                .padding(.bottom, Theme.blockGap)
            }
        }
        .background(Theme.stage)
        .ignoresSafeArea(.container, edges: .top)
        // Reason: one width read per layout pass; the columns below are derived from it, not measured again.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .animation(.snappy(duration: 0.25), value: layout.menuExpanded)
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
        }
    }
}

/// How the columns share the window's width. The full menu needs room: below `expandBreakpoint` it is
/// shown as its icon rail whatever was chosen, and the list gives up width before the detail does, so
/// nothing is ever clipped. At the smallest window the rail, the icon rail, a 240 pt list and the
/// 340 pt detail still fit.
@MainActor
struct Responsive {
    static let railWidth: CGFloat = 60
    static let detailMin: CGFloat = 340
    static let listMin: CGFloat = 240
    static let listMax: CGFloat = 480
    static let minWindowWidth: CGFloat = 720

    let width: CGFloat
    let menuPreference: Bool
    let preferredList: Double

    init(width: CGFloat, menuExpanded: Bool, preferredList: Double) {
        self.width = width
        self.menuPreference = menuExpanded
        self.preferredList = preferredList
    }

    /// The expanded menu (232) + a list at its minimum + the detail minimum + the rail and the gaps.
    static let expandBreakpoint: CGFloat = railWidth + MenuColumn.expandedWidth + listMin + detailMin + Theme.blockGap * 4
    var canExpandMenu: Bool { width >= Self.expandBreakpoint }
    var menuExpanded: Bool { menuPreference && canExpandMenu }

    private var menuWidth: CGFloat { menuExpanded ? MenuColumn.expandedWidth : MenuColumn.collapsedWidth }
    private var listCeiling: CGFloat {
        max(Self.listMin, min(Self.listMax, width - Self.railWidth - menuWidth - Self.detailMin - Theme.blockGap * 4))
    }
    var listRange: ClosedRange<Double> { Double(Self.listMin)...Double(listCeiling) }
    var listWidth: Double { min(max(preferredList, listRange.lowerBound), listRange.upperBound) }
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
        VStack(spacing: 0) {
            header(count: list.count)
            List(selection: $selectedItem) {
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
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if list.isEmpty {
                    EmptyState(icon: query.isEmpty ? .inbox : .search, title: query.isEmpty ? "No items yet" : "No matches")
                }
            }
        }
    }

    /// Title and count, with room to breathe: this is the heading of the whole column.
    private func header(count: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s + 2) {
                Text(query.isEmpty ? title : "Results")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(Theme.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: 20)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.l + 2)
            .frame(height: 56)
            Divider().padding(.horizontal, Theme.Space.m)
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


/// The gap between the list block and the detail block, which is also the handle that resizes the list.
struct SplitHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: Theme.blockGap)
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? width
                    startWidth = start
                    width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startWidth = nil })
            .accessibilityLabel("Resize the list")
    }
}
