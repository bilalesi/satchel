import Foundation

/// Decides which items this device syncs. Device-local: it is stored encrypted next to the
/// vault and never uploaded, like Dropbox's "selective sync". Items it excludes are neither
/// uploaded nor stored when found on the remote.
public protocol SyncFilter: Sendable {
    func includes(_ overview: ItemOverview) -> Bool
    /// Changes whenever the answers can change, so cached "skipped" decisions are dropped.
    var fingerprint: String { get }
}

public struct SyncEverything: SyncFilter {
    public init() {}
    public func includes(_ overview: ItemOverview) -> Bool { true }
    public var fingerprint: String { "all" }
}

public struct SyncSelection: SyncFilter, Codable, Equatable, Sendable {
    public static let secretName = "sync-selection"

    /// Categories whose items (and the category itself) this device does not sync.
    public var excludedCategories: Set<UUID> = []
    public var syncUncategorized = true
    /// Per-item decision that wins over the category rule: true = always, false = never.
    public var itemOverrides: [UUID: Bool] = [:]

    public init() {}

    public func includes(_ overview: ItemOverview) -> Bool {
        if let forced = itemOverrides[overview.id] { return forced }
        if overview.type == .category { return !excludedCategories.contains(overview.id) }
        if let category = overview.categoryID { return !excludedCategories.contains(category) }
        return syncUncategorized
    }

    public var isDefault: Bool { self == SyncSelection() }

    public var fingerprint: String {
        let parts = excludedCategories.map(\.uuidString).sorted()
            + [syncUncategorized ? "u1" : "u0"]
            + itemOverrides.map { "\($0.key.uuidString)=\($0.value ? 1 : 0)" }.sorted()
        return GitBlob.sha(Data(parts.joined(separator: "|").utf8))
    }

    // Codable with stable JSON (sets and dictionaries keyed by UUID encode as arrays/strings).
    enum CodingKeys: String, CodingKey { case excludedCategories, syncUncategorized, itemOverrides }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excludedCategories = Set(try c.decodeIfPresent([UUID].self, forKey: .excludedCategories) ?? [])
        syncUncategorized = try c.decodeIfPresent(Bool.self, forKey: .syncUncategorized) ?? true
        let raw = try c.decodeIfPresent([String: Bool].self, forKey: .itemOverrides) ?? [:]
        itemOverrides = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(excludedCategories.map(\.uuidString).sorted(), forKey: .excludedCategories)
        try c.encode(syncUncategorized, forKey: .syncUncategorized)
        try c.encode(Dictionary(uniqueKeysWithValues: itemOverrides.map { ($0.key.uuidString, $0.value) }), forKey: .itemOverrides)
    }
}
