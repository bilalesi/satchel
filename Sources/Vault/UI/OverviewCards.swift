import SwiftUI
import VaultCore

/// Home screen: Pulse-style cards with one big number each.
struct OverviewCards: View {
    @EnvironmentObject var session: VaultSession

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Overview").font(.system(size: 20, weight: .semibold)).padding(.bottom, 2)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ItemType.allCases) { t in
                        let items = session.items.filter { $0.type == t }
                        StatCard(title: t.displayName, symbol: Theme.symbol(t), color: Theme.accent(t),
                                 value: "\(items.count)", unit: items.count == 1 ? "item" : "items",
                                 facts: [("Favorites", "\(items.filter(\.favorite).count)"),
                                         ("Updated 30d", "\(items.filter { $0.updatedAt > .now.addingTimeInterval(-30 * 86400) }.count)")],
                                 series: weekly(items))
                    }
                    StatCard(title: "Secret age", symbol: "hourglass", color: .orange,
                             value: "\(stale.count)", unit: "older than 180 days",
                             facts: [("Oldest", oldestLabel), ("Rotate soon", "\(stale.prefix(3).map(\.title).joined(separator: ", "))")],
                             series: ageBuckets)
                    StatCard(title: "Security", symbol: "lock.shield", color: Theme.accent(.login),
                             value: session.touchIDEnabled ? "On" : "Off", unit: "Touch ID",
                             facts: [("Auto-lock", "\(AppSettings.autoLockMinutes) min"),
                                     ("Clipboard", "\(AppSettings.clipboardSeconds) s"),
                                     ("Unreadable", "\(session.corruptIDs.count)")],
                             series: [])
                }
                Card(padding: 14) {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(session.vaultURL.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.vaultURL]) }
                            .buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.canvas)
    }

    private var stale: [ItemOverview] {
        session.items.filter { $0.updatedAt < .now.addingTimeInterval(-180 * 86400) }.sorted { $0.updatedAt < $1.updatedAt }
    }

    private var oldestLabel: String {
        guard let o = session.items.min(by: { $0.updatedAt < $1.updatedAt }) else { return "–" }
        return "\(Int(-o.updatedAt.timeIntervalSinceNow / 86400)) d"
    }

    /// Items updated per week, last 26 weeks, oldest first.
    private func weekly(_ items: [ItemOverview]) -> [Int] {
        var buckets = [Int](repeating: 0, count: 26)
        for i in items {
            let w = Int(-i.updatedAt.timeIntervalSinceNow / (7 * 86400))
            if w >= 0 && w < 26 { buckets[25 - w] += 1 }
        }
        return buckets
    }

    /// Items by age in 30-day buckets up to a year.
    private var ageBuckets: [Int] {
        var b = [Int](repeating: 0, count: 12)
        for i in session.items {
            let m = min(11, max(0, Int(-i.updatedAt.timeIntervalSinceNow / (30 * 86400))))
            b[m] += 1
        }
        return b
    }
}

struct StatCard: View {
    let title: String
    let symbol: String
    let color: Color
    let value: String
    let unit: String
    let facts: [(String, String)]
    let series: [Int]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(Theme.numeral).tracking(-1)
                    Text(unit).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(facts, id: \.0) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.0).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(f.1).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }
                    }
                }
                if !series.isEmpty {
                    DotMatrix(values: series, color: color).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
