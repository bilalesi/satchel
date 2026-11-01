import Foundation

public struct RemoteObject: Sendable, Equatable {
    public let data: Data
    /// Opaque validator for compare-and-swap. Every backend uses the git blob id of the
    /// content so the engine can compare local bytes to the remote without downloading.
    public let etag: String

    public init(data: Data, etag: String) {
        self.data = data
        self.etag = etag
    }
}

/// The whole contract a sync backend must fulfil. Strategy pattern: GitHub, a folder,
/// later S3, all plug in here.
public protocol RemoteStore: Sendable {
    var displayName: String { get }
    /// `nil` when the object does not exist.
    func get(_ path: String) async throws -> RemoteObject?
    /// Compare-and-swap write. `ifMatch == nil` means create-only. Returns the new etag.
    /// Throws `SyncError.conflict` when the precondition fails.
    func put(_ path: String, data: Data, ifMatch: String?) async throws -> String
    /// Objects under `prefix` → etag. `prefix` ends with "/".
    func list(prefix: String) async throws -> [String: String]
}

public enum SyncError: Error, Equatable, LocalizedError {
    case conflict(String)
    case unauthorized
    case notFound(String)
    case network(String)
    case remote(status: Int, message: String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .conflict(let p): return "Another device changed \(p) at the same time; retrying."
        case .unauthorized: return "The remote rejected the credentials. Sign in again."
        case .notFound(let p): return "\(p) is missing on the remote."
        case .network(let m): return "Network error: \(m)"
        case .remote(let s, let m): return "Remote error \(s): \(m)"
        case .notConfigured: return "No remote configured."
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
