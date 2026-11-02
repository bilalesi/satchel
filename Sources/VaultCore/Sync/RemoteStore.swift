import Foundation

public struct RemoteObject: Sendable, Equatable {
    public let data: Data
    /// Opaque validator for compare-and-swap. Backends return whatever the server uses (a git
    /// blob id, an S3 ETag, a WebDAV ETag); the engine only ever echoes it back and records
    /// it in `SyncState.objects`.
    public let etag: String

    public init(data: Data, etag: String) {
        self.data = data
        self.etag = etag
    }
}

/// The whole contract a sync backend must fulfil. Strategy pattern: GitHub, a folder, Git over
/// SSH, WebDAV and S3-compatible storage all plug in here.
public protocol RemoteStore: Sendable {
    var displayName: String { get }
    /// `nil` when the object does not exist.
    func get(_ path: String) async throws -> RemoteObject?
    /// Compare-and-swap write. `ifMatch == nil` means create-only. Returns the new etag.
    /// Throws `SyncError.conflict` when the precondition fails.
    func put(_ path: String, data: Data, ifMatch: String?) async throws -> String
    /// Objects under `prefix` → etag. `prefix` ends with "/".
    func list(prefix: String) async throws -> [String: String]
    /// Removes an object. A missing object is not an error. `ifMatch == nil` deletes whatever is there.
    func delete(_ path: String, ifMatch: String?) async throws
}

/// A backend that can stage several writes and publish them together (Git: one commit and one
/// push per sync round instead of one per file). Reads inside `withBatch` see staged writes.
/// If publishing fails because the remote moved, `withBatch` throws `SyncError.conflict` and
/// nothing is published.
public protocol BatchingRemoteStore: RemoteStore {
    func withBatch<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T
}

public enum ProbeResult: Equatable, Sendable {
    case enforced
    /// The server accepted a write that should have been refused (named for the message).
    case notEnforced(String)
}

public extension RemoteStore {
    /// Proves the server really enforces conditional writes, which the sync engine relies on to
    /// avoid lost updates. Writes, overwrites and removes one scratch object under `items/`
    /// (a name that is not an item id, so it is ignored by sync).
    func probeConditionalWrites() async throws -> ProbeResult {
        let path = RemotePaths.itemsPrefix + ".probe-" + UUID().uuidString.lowercased()
        do {
            let first = try await put(path, data: Data("a".utf8), ifMatch: nil)

            func refused(_ body: () async throws -> String) async throws -> Bool {
                do { _ = try await body(); return false } catch SyncError.conflict { return true }
            }
            if !(try await refused({ try await put(path, data: Data("b".utf8), ifMatch: nil) })) {
                try? await delete(path, ifMatch: nil)
                return .notEnforced("create-only overwrote an existing object")
            }
            if !(try await refused({ try await put(path, data: Data("c".utf8), ifMatch: "satchel-wrong-etag") })) {
                try? await delete(path, ifMatch: nil)
                return .notEnforced("a write with a wrong ETag was accepted")
            }
            // A correct etag must still be accepted (otherwise every real write would fail).
            _ = try await put(path, data: Data("d".utf8), ifMatch: first)
            try? await delete(path, ifMatch: nil)
            return .enforced
        } catch {
            try? await delete(path, ifMatch: nil)
            throw error
        }
    }
}

public enum SyncError: Error, Equatable, LocalizedError {
    case conflict(String)
    case unauthorized
    case notFound(String)
    case network(String)
    case remote(status: Int, message: String)
    case notConfigured
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .conflict(let p): return "Another device changed \(p) at the same time; retrying."
        case .unauthorized: return "The remote rejected the credentials. Sign in again."
        case .notFound(let p): return "\(p) is missing on the remote."
        case .network(let m): return "Network error: \(m)"
        case .remote(let s, let m): return "Remote error \(s): \(m)"
        case .notConfigured: return "No remote configured."
        case .missingToken: return "No GitHub token is saved on this Mac. Paste it in Settings → Sync."
        }
    }
}

/// Remote layout, identical to the local vault directory.
public enum RemotePaths {
    public static let header = VaultHeader.fileName
    public static let manifest = Manifest.fileName
    public static let itemsPrefix = "items/"

    public static func item(_ id: UUID) -> String {
        itemsPrefix + id.uuidString + "." + ItemFile.fileExtension
    }

    public static func itemID(fromPath path: String) -> UUID? {
        guard path.hasPrefix(itemsPrefix), path.hasSuffix("." + ItemFile.fileExtension) else { return nil }
        return UUID(uuidString: String(path.dropFirst(itemsPrefix.count).dropLast(ItemFile.fileExtension.count + 1)))
    }
}
