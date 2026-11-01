import Foundation

/// Plaintext header file `vault.vhdr`. Contains no secrets: KDF parameters and
/// wrapped keys only. Integrity is covered by the manifest MAC.
public struct VaultHeader: Codable, Equatable, Sendable {
    public static let fileName = "vault.vhdr"
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var vaultID: UUID
    public var createdAt: Date
    /// Bumped on password change; sync keeps the newer header when both devices changed it.
    public var updatedAt: Date
    /// Password slots only. The Touch ID slot is device-bound and lives in a local file.
    public var slots: [KeySlot]

    public init(vaultID: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date? = nil, slots: [KeySlot]) {
        self.formatVersion = Self.currentFormatVersion
        self.vaultID = vaultID
        self.createdAt = createdAt.millisecondPrecision
        self.updatedAt = (updatedAt ?? createdAt).millisecondPrecision
        self.slots = slots
    }

    enum CodingKeys: String, CodingKey { case formatVersion, vaultID, createdAt, updatedAt, slots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        vaultID = try c.decode(UUID.self, forKey: .vaultID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        // Phase 1 headers had no updatedAt.
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        slots = try c.decode([KeySlot].self, forKey: .slots)
    }

    public func encoded() throws -> Data {
        try JSONCoding.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> VaultHeader {
        guard let header = try? JSONCoding.decoder.decode(VaultHeader.self, from: data),
              header.formatVersion == currentFormatVersion else {
            throw VaultError.corruptHeader
        }
        return header
    }
}

/// One encoder/decoder configuration for every JSON file in the vault, so bytes are
/// deterministic (sorted keys) and dates round-trip exactly (ISO 8601 with millis).
enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        e.dataEncodingStrategy = .base64
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let ms = try dec.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        d.dataDecodingStrategy = .base64
        return d
    }()
}
