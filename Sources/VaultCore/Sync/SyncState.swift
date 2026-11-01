import Foundation

/// Local-only bookkeeping (`sync.json`): what this device last agreed with the remote.
/// `synced` is the per-item base version used to tell "changed here" from "changed there".
public struct SyncState: Codable, Equatable, Sendable {
    public static let fileName = "sync.json"

    public var lastGeneration: UInt64 = 0
    public var synced: [String: UInt64] = [:]
    public var lastSyncAt: Date?

    public init() {}

    public func baseVersion(of id: UUID) -> UInt64 {
        synced[id.uuidString] ?? 0
    }
}
