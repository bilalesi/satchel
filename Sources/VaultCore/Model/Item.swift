import Foundation

public enum ItemType: String, Codable, CaseIterable, Sendable {
    case login, apiKey, dbCredential, webhook, secureNote, sshKey

    public var displayName: String {
        switch self {
        case .login: return "Login"
        case .apiKey: return "API Key"
        case .dbCredential: return "Database"
        case .webhook: return "Webhook"
        case .secureNote: return "Secure Note"
        case .sshKey: return "SSH Key"
        }
    }

    /// The field Quick Access copies on Enter and that `history` tracks on change.
    public var primarySecretField: String {
        switch self {
        case .login, .dbCredential: return "password"
        case .apiKey: return "apiKey"
        case .webhook: return "url"
        case .secureNote: return "notes"
        case .sshKey: return "privateKey"
        }
    }

    /// Ordered field keys for the editor and detail view. `notes` is always last.
    public var fieldKeys: [String] {
        switch self {
        case .login: return ["password", "totpSeed", "notes"]
        case .apiKey: return ["apiKey", "secret", "endpoint", "notes"]
        case .dbCredential: return ["host", "port", "database", "password", "connectionString", "notes"]
        case .webhook: return ["url", "secret", "notes"]
        case .secureNote: return ["notes"]
        case .sshKey: return ["privateKey", "publicKey", "passphrase", "host", "notes"]
        }
    }

    /// Fields whose values are hidden until revealed and whose changes are kept in history.
    public static let secretFieldKeys: Set<String> = [
        "password", "totpSeed", "apiKey", "secret", "privateKey", "passphrase", "connectionString",
    ]
}

/// Searchable metadata. Encrypted with the overview key; decrypted for every item at unlock.
public struct ItemOverview: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var type: ItemType
    public var title: String
    public var username: String?
    public var urls: [String]
    public var bundleIDs: [String]
    public var tags: [String]
    public var favorite: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), type: ItemType, title: String, username: String? = nil,
                urls: [String] = [], bundleIDs: [String] = [], tags: [String] = [],
                favorite: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
        self.urls = urls
        self.bundleIDs = bundleIDs
        self.tags = tags
        self.favorite = favorite
        self.createdAt = createdAt.millisecondPrecision
        self.updatedAt = updatedAt.millisecondPrecision
    }

    /// Lower-cased hosts of `urls`, used for matching and display.
    public var hosts: [String] {
        urls.compactMap { raw in
            let s = raw.contains("://") ? raw : "https://" + raw
            return URL(string: s)?.host?.lowercased()
        }
    }
}

public struct SecretRevision: Codable, Equatable, Sendable {
    public var field: String
    public var value: String
    public var changedAt: Date

    public init(field: String, value: String, changedAt: Date = Date()) {
        self.field = field
        self.value = value
        self.changedAt = changedAt.millisecondPrecision
    }
}

/// The secret part. Encrypted with the item key; decrypted only on demand.
/// ponytail: field values are Swift Strings once decoded; they live only while a
/// detail view or copy action needs them. Upgrade path: per-field SecureBytes.
public struct ItemDetails: Codable, Equatable, Sendable {
    public static let historyCap = 10

    public var fields: [String: String]
    public var history: [SecretRevision]

    public init(fields: [String: String] = [:], history: [SecretRevision] = []) {
        self.fields = fields
        self.history = history
    }

    /// Returns a copy where every secret field that changed from `previous` has the old
    /// value prepended to `history`, capped at `historyCap`.
    public func recordingChanges(from previous: ItemDetails, at date: Date = Date()) -> ItemDetails {
        var next = self
        var added: [SecretRevision] = []
        for key in ItemType.secretFieldKeys {
            if let old = previous.fields[key], !old.isEmpty, old != (fields[key] ?? "") {
                added.append(SecretRevision(field: key, value: old, changedAt: date))
            }
        }
        if !added.isEmpty {
            next.history = Array((added + previous.history).prefix(Self.historyCap))
        } else {
            next.history = previous.history
        }
        return next
    }
}
