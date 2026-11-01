import Foundation

/// Fixed 41-byte plaintext header of an item file. It is the AAD of both encrypted
/// boxes, so a box cannot be moved to another id or replayed under another version.
public struct ItemFileHeader: Equatable, Sendable {
    public static let magic: [UInt8] = Array("VIT1".utf8)
    public static let size = 41

    public let id: UUID
    public let version: UInt64
    public let updatedAt: Date
    public let deleted: Bool

    public init(id: UUID, version: UInt64, updatedAt: Date, deleted: Bool) {
        self.id = id
        self.version = version
        self.updatedAt = updatedAt.millisecondPrecision
        self.deleted = deleted
    }

    func encoded() -> Data {
        var d = Data(capacity: Self.size)
        d.append(contentsOf: Self.magic)
        withUnsafeBytes(of: id.uuid) { d.append(contentsOf: $0) }
        d.append(contentsOf: version.bigEndianBytes)
        d.append(contentsOf: Int64((updatedAt.timeIntervalSince1970 * 1000).rounded()).bigEndianBytes)
        d.append(deleted ? 1 : 0)
        d.append(contentsOf: [0, 0, 0, 0])
        return d
    }

    static func decode(_ data: Data) throws -> ItemFileHeader {
        guard data.count >= size else { throw VaultError.corruptItemData }
        let b = [UInt8](data.prefix(size))
        guard Array(b[0..<4]) == magic else { throw VaultError.corruptItemData }
        let uuid = uuid_t(b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11],
                          b[12], b[13], b[14], b[15], b[16], b[17], b[18], b[19])
        let version = UInt64(bigEndianBytes: b[20..<28])
        let ms = Int64(bitPattern: UInt64(bigEndianBytes: b[28..<36]))
        return ItemFileHeader(id: UUID(uuid: uuid), version: version,
                              updatedAt: Date(timeIntervalSince1970: Double(ms) / 1000),
                              deleted: b[36] == 1)
    }
}

/// `items/<uuid>.vitem` layout:
/// `header(41) ‖ u32 overviewLen ‖ overviewBox ‖ u32 detailsLen ‖ detailsBox`
/// Reading the overview never touches the details bytes, so unlock reads are small.
public enum ItemFile {
    public static let fileExtension = "vitem"

    public static func encode(overview: ItemOverview, details: ItemDetails?, version: UInt64,
                              deleted: Bool, keys: VaultKeys) throws -> Data {
        let header = ItemFileHeader(id: overview.id, version: version, updatedAt: overview.updatedAt, deleted: deleted)
        let aad = header.encoded()
        var out = aad
        let overviewBox = try AEAD.seal(SecureBytes(data: try JSONCoding.encoder.encode(overview)),
                                        key: keys.overview, aad: aad)
        out.append(contentsOf: UInt32(overviewBox.count).bigEndianBytes)
        out.append(overviewBox)
        if let details {
            let detailsBox = try AEAD.seal(SecureBytes(data: try JSONCoding.encoder.encode(details)),
                                           key: keys.item, aad: aad)
            out.append(contentsOf: UInt32(detailsBox.count).bigEndianBytes)
            out.append(detailsBox)
        } else {
            out.append(contentsOf: UInt32(0).bigEndianBytes)
        }
        return out
    }

    public static func decodeHeader(_ data: Data) throws -> ItemFileHeader {
        try ItemFileHeader.decode(data)
    }

    public static func decodeOverview(_ data: Data, keys: VaultKeys) throws -> (header: ItemFileHeader, overview: ItemOverview) {
        let header = try ItemFileHeader.decode(data)
        let (box, _) = try box(in: data, at: ItemFileHeader.size)
        let plain = try AEAD.open(box, key: keys.overview, aad: data.prefix(ItemFileHeader.size))
        guard let overview = try? JSONCoding.decoder.decode(ItemOverview.self, from: plain.toData()),
              overview.id == header.id else {
            throw VaultError.corruptItemData
        }
        return (header, overview)
    }

    public static func decodeDetails(_ data: Data, keys: VaultKeys) throws -> ItemDetails {
        _ = try ItemFileHeader.decode(data)
        let (_, afterOverview) = try box(in: data, at: ItemFileHeader.size)
        let (box, _) = try box(in: data, at: afterOverview)
        guard !box.isEmpty else { throw VaultError.corruptItemData }
        let plain = try AEAD.open(box, key: keys.item, aad: data.prefix(ItemFileHeader.size))
        guard let details = try? JSONCoding.decoder.decode(ItemDetails.self, from: plain.toData()) else {
            throw VaultError.corruptItemData
        }
        return details
    }

    /// Reads `u32 len ‖ bytes` at `offset`. Returns the bytes and the offset after them.
    private static func box(in data: Data, at offset: Int) throws -> (Data, Int) {
        guard data.count >= offset + 4 else { throw VaultError.corruptItemData }
        let start = data.startIndex + offset
        let len = Int(UInt32(bigEndianBytes: data[start..<start + 4]))
        guard data.count >= offset + 4 + len else { throw VaultError.corruptItemData }
        return (data[start + 4..<start + 4 + len], offset + 4 + len)
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }

    init(bigEndianBytes bytes: some Collection<UInt8>) {
        precondition(bytes.count == MemoryLayout<Self>.size)
        var v: Self = 0
        for b in bytes { v = (v << 8) | Self(b) }
        self = v
    }
}
