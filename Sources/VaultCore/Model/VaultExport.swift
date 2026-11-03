import Foundation

/// A plain JSON copy of one workspace's items, to move to another app or keep a readable backup.
/// It is NOT encrypted: the app warns before writing it. JSON keeps every field and type without a lossy
/// column mapping (CSV would flatten six item types into one table); field keys are those of `ItemType.fieldKeys`.
/// Secret history is left out: an export carries current values only.
public enum VaultExport {
    public struct Entry: Codable, Equatable, Sendable {
        public var type: ItemType
        public var title: String
        public var username: String?
        public var urls: [String]
        public var tags: [String]
        public var category: String?
        public var favorite: Bool
        public var createdAt: Date
        public var updatedAt: Date
        public var fields: [String: String]
    }

    public struct File: Codable, Equatable, Sendable {
        public var format = "satchel-export"
        public var version = 1
        public var workspace: String
        public var exportedAt: Date
        public var items: [Entry]
    }

    public static func json(workspace: String, items: [(ItemOverview, ItemDetails)], categories: [UUID: String],
                            now: Date = Date()) throws -> Data {
        let entries = items.map { o, d in
            Entry(type: o.type, title: o.title, username: o.username, urls: o.urls, tags: o.tags,
                  category: o.categoryID.flatMap { categories[$0] }, favorite: o.favorite,
                  createdAt: o.createdAt, updatedAt: o.updatedAt, fields: d.fields.filter { !$0.value.isEmpty })
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(File(workspace: workspace, exportedAt: now, items: entries))
    }
}
