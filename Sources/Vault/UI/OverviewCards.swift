import SwiftUI
import VaultCore

/// Home screen. Responsive: the column count is derived from the measured width so every
/// row is full (6 type cards → 6, 3 or 2 columns; 4 summary cards → 4, 2 or 1).
struct OverviewCards: View {
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    var onSelect: (SidebarSelection) -> Void = { _ in }
    @State private var width: CGFloat = 900

    private static let staleDays: Double = 180
    private static let maxContentWidth: CGFloat = 1180

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                grid(columns: summaryColumns) { summaryCards }
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionLabel(text: "By type")
                    grid(columns: typeColumns) {
                        ForEach(ItemType.userTypes) { typeCard($0) }
                    }
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        // Reason: one width read per layout pass; cheaper than a GeometryReader around the content.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    // MARK: Layout

    private var contentWidth: CGFloat { min(width, Self.maxContentWidth) - Theme.Space.xl * 2 }
    private var typeColumns: Int { contentWidth >= 1020 ? 6 : contentWidth >= 500 ? 3 : 2 }
    private var summaryColumns: Int { contentWidth >= 820 ? 4 : contentWidth >= 300 ? 2 : 1 }

    private func grid<C: View>(columns: Int, @ViewBuilder content: () -> C) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m, alignment: .top), count: columns),
                  alignment: .leading, spacing: Theme.Space.m, content: content)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Overview").font(Theme.title)
            Text(subtitle).font(Theme.body).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        let n = session.items.count
        let favs = session.items.filter(\.favorite).count
        return "\(n) \(n == 1 ? "item" : "items") · \(favs) \(favs == 1 ? "favorite" : "favorites")"
    }

    // MARK: Summary row

    @ViewBuilder
    private var summaryCards: some View {
        SummaryCard(title: "Items", icon: .inbox, color: Theme.accent(.login),
                    value: "\(session.items.count)", caption: "\(session.items.filter(\.favorite).count) favorites",
                    footer: nil, action: { onSelect(.all) })
        SummaryCard(title: "Rotate soon", icon: .history, color: Theme.accent(.apiKey),
                    value: "\(stale.count)", caption: "older than \(Int(Self.staleDays)) days",
                    footer: stale.isEmpty ? "Everything is fresh" : stale.prefix(2).map(\.title).joined(separator: ", "),
                    action: stale.isEmpty ? nil : { onSelect(.recent) })
        SummaryCard(title: "Sync", icon: .sync, color: syncColor,
                    value: syncValue, caption: syncCaption, footer: syncFooter, action: nil)
        SummaryCard(title: "Security", icon: .shield, color: Theme.accent(.sshKey),
                    value: session.touchIDEnabled ? "Touch ID" : "Password",
                    caption: "Locks after \(AppSettings.autoLockMinutes) min",
                    footer: session.corruptIDs.isEmpty ? "All items readable" : "\(session.corruptIDs.count) unreadable",
                    action: nil)
    }

    private var stale: [ItemOverview] {
        let cutoff = Date().addingTimeInterval(-Self.staleDays * 86400)
        return session.items.filter { $0.updatedAt < cutoff }.sorted { $0.updatedAt < $1.updatedAt }
    }

    private var syncColor: Color {
        switch sync.status {
        case .error: return .red
        case .off: return .secondary
        default: return Theme.accent(.webhook)
        }
    }

    private var syncValue: String {
        switch sync.status {
        case .off: return "Off"
        case .syncing: return "Syncing"
        case .error: return "Error"
        case .idle: return sync.lastSyncAt == nil ? "Ready" : "Synced"
        }
    }

    private var syncCaption: String {
        switch sync.status {
        case .error(let m): return m
        case .off: return "Settings → Sync"
        default:
            if let d = sync.lastSyncAt { return d.formatted(.relative(presentation: .named)) }
            return sync.config.displayName
        }
    }

    private var syncFooter: String? {
        guard sync.status != .off else { return nil }
        if let r = sync.lastReport { return "↓ \(r.pulled)   ↑ \(r.pushed)" + (r.conflicts > 0 ? "   merged \(r.conflicts)" : "") }
        return sync.config.displayName
    }

    // MARK: Type cards

    private func typeCard(_ t: ItemType) -> some View {
        let items = session.items.filter { $0.type == t }
        return Button { onSelect(.type(t)) } label: {
            Card(accent: Theme.accent(t), interactive: true) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.s) {
                        IconTile(type: t, size: 22)
                        Text(t.displayName).font(Theme.headline).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                        Text("\(items.count)").font(Theme.hero).contentTransition(.numericText())
                        Text(items.count == 1 ? "item" : "items").font(Theme.caption).foregroundStyle(.secondary)
                    }
                    DotMatrix(values: weekly(items), color: Theme.accent(t))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help("Show \(t.displayName) items")
    }

    /// Items updated per week over the last 16 weeks, oldest first.
    private func weekly(_ items: [ItemOverview]) -> [Int] {
        var buckets = [Int](repeating: 0, count: 16)
        for i in items {
            let w = Int(-i.updatedAt.timeIntervalSinceNow / (7 * 86400))
            if w >= 0 && w < buckets.count { buckets[buckets.count - 1 - w] += 1 }
        }
        return buckets
    }
}

/// One summary tile: label, light hero value, one caption, optional footer. Fixed min height
/// so a row of tiles lines up whatever the text length.
struct SummaryCard: View {
    let title: String
    let icon: Codicon
    let color: Color
    let value: String
    let caption: String
    let footer: String?
    let action: (() -> Void)?

    var body: some View {
        let card = Card(accent: color, interactive: action != nil) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s - 2) {
                    Icon(icon, size: 13)
                    Text(title)
                }
                .font(Theme.headline).foregroundStyle(color)
                Text(value).font(Theme.hero).lineLimit(1).minimumScaleFactor(0.8)
                Text(caption).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let footer {
                    Text(footer).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
        if let action {
            Button(action: action) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }
}
