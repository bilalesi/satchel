import Foundation

/// Local-only bookkeeping (`sync.json`): what this device last agreed with the remote.
public struct SyncState: Codable, Equatable, Sendable {
    public static let fileName = "sync.json"

    /// What was last moved for one remote object: the server's etag and the git-blob sha of
    /// the bytes. Server etags are opaque (WebDAV and S3 etags are not content hashes), so
    /// "the remote still holds exactly what we last transferred" is `etag == known.etag`
    /// together with `localSha == known.sha`.
    public struct KnownObject: Codable, Equatable, Sendable {
        public var etag: String
        public var sha: String
        public init(etag: String, sha: String) {
            self.etag = etag
            self.sha = sha
        }
    }

    public var lastGeneration: UInt64 = 0
    /// Per-item base version: tells "changed here" from "changed there".
    public var synced: [String: UInt64] = [:]
    public var lastSyncAt: Date?
    public var objects: [String: KnownObject] = [:]
    /// Selective sync: remote versions that were looked at and deliberately not stored.
    public var skipped: [String: UInt64] = [:]
    /// Fingerprint of the selection `skipped` was computed under; a change clears it.
    public var filterFingerprint: String = ""

    public init() {}

    enum CodingKeys: String, CodingKey { case lastGeneration, synced, lastSyncAt, objects, skipped, filterFingerprint }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastGeneration = try c.decodeIfPresent(UInt64.self, forKey: .lastGeneration) ?? 0
        synced = try c.decodeIfPresent([String: UInt64].self, forKey: .synced) ?? [:]
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        // Older sync.json files do not have these.
        objects = try c.decodeIfPresent([String: KnownObject].self, forKey: .objects) ?? [:]
        skipped = try c.decodeIfPresent([String: UInt64].self, forKey: .skipped) ?? [:]
        filterFingerprint = try c.decodeIfPresent(String.self, forKey: .filterFingerprint) ?? ""
    }

    public func baseVersion(of id: UUID) -> UInt64 {
        synced[id.uuidString] ?? 0
    }

    /// True when the remote object is byte-identical to `localSha`. A git-style etag (the blob
    /// sha itself) answers directly; any other etag needs the pair recorded at the last transfer.
    public func isSame(path: String, remoteEtag: String?, localSha: String?) -> Bool {
        guard let remoteEtag, let localSha else { return false }
        if remoteEtag == localSha { return true }
        guard let known = objects[path] else { return false }
        return known.etag == remoteEtag && known.sha == localSha
    }

    public mutating func record(path: String, etag: String, data: Data) {
        objects[path] = KnownObject(etag: etag, sha: GitBlob.sha(data))
    }
}
