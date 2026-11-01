import Foundation

/// In-memory ranking over item overviews.
/// Reason: a linear scan over at most a few thousand ~200-byte entries is well under
/// a millisecond; an inverted index would add code for no felt difference.
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let item: ItemOverview
        let title: String
        let titleWords: [String]
        let hosts: [String]
        let username: String
        let tags: [String]
    }

    private let entries: [Entry]

    public init(_ items: [ItemOverview]) {
        entries = items.map { item in
            let title = item.title.lowercased()
            return Entry(item: item,
                         title: title,
                         titleWords: title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init),
                         hosts: item.hosts,
                         username: (item.username ?? "").lowercased(),
                         tags: item.tags.map { $0.lowercased() })
        }
    }

    public var count: Int { entries.count }

    /// Ranked results. Every query token must match (AND). With an empty query, returns
    /// items linked to `frontmostBundleID` first, then favorites, then most recent.
    public func query(_ text: String, frontmostBundleID: String? = nil, limit: Int = 50) -> [ItemOverview] {
        let tokens = text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var scored: [(score: Int, item: ItemOverview)] = []
        scored.reserveCapacity(entries.count)

        for e in entries {
            var score = 0
            if let app = frontmostBundleID, e.item.bundleIDs.contains(app) { score += 100 }
            if e.item.favorite { score += 5 }
            var allMatched = true
            for t in tokens {
                let s = Self.tokenScore(t, e)
                if s == 0 { allMatched = false; break }
                score += s
            }
            guard allMatched else { continue }
            scored.append((score, e.item))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.updatedAt != $1.item.updatedAt { return $0.item.updatedAt > $1.item.updatedAt }
            return $0.item.title < $1.item.title // deterministic order on exact ties
        }
        return scored.prefix(limit).map(\.item)
    }

    private static func tokenScore(_ t: String, _ e: Entry) -> Int {
        if e.title.hasPrefix(t) { return 50 }
        if e.titleWords.contains(where: { $0.hasPrefix(t) }) { return 45 }
        if e.hosts.contains(where: { $0.hasPrefix(t) || $0.contains("." + t) }) { return 40 }
        if e.username.hasPrefix(t) { return 30 }
        if e.tags.contains(where: { $0.hasPrefix(t) }) { return 20 }
        if e.title.contains(t) || e.username.contains(t) || e.hosts.contains(where: { $0.contains(t) }) { return 15 }
        if isSubsequence(t, of: e.title) { return 10 }
        return 0
    }

    /// "gml" ⊂ "gmail".
    static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        outer: for c in needle {
            while let h = it.next() { if h == c { continue outer } }
            return false
        }
        return true
    }
}
