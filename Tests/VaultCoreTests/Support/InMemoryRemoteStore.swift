import Foundation
@testable import VaultCore

/// Test double with compare-and-swap semantics, call counters and fault injection.
final class InMemoryRemoteStore: RemoteStore, @unchecked Sendable {
    let displayName = "memory"
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private(set) var gets: [String] = []
    private(set) var puts: [String] = []
    private(set) var lists = 0
    private(set) var deletes: [String] = []
    /// Paths whose next put fails with `.conflict` once, without applying.
    var conflictOnce: Set<String> = []
    /// After this many successful puts, every put throws `.network`.
    var failPutsAfter: Int?

    func get(_ path: String) async throws -> RemoteObject? { syncGet(path) }
    func put(_ path: String, data: Data, ifMatch: String?) async throws -> String { try syncPut(path, data: data, ifMatch: ifMatch) }
    func list(prefix: String) async throws -> [String: String] { syncList(prefix) }
    func delete(_ path: String, ifMatch: String?) async throws { try syncDelete(path, ifMatch: ifMatch) }

    private func syncDelete(_ path: String, ifMatch: String?) throws {
        try lock.withLock {
            guard let data = objects[path] else { return }
            if let ifMatch, GitBlob.sha(data) != ifMatch { throw SyncError.conflict(path) }
            objects[path] = nil
            deletes.append(path)
        }
    }

    private func syncGet(_ path: String) -> RemoteObject? {
        lock.withLock {
            gets.append(path)
            return objects[path].map { RemoteObject(data: $0, etag: GitBlob.sha($0)) }
        }
    }

    private func syncPut(_ path: String, data: Data, ifMatch: String?) throws -> String {
        try lock.withLock {
            if conflictOnce.remove(path) != nil { throw SyncError.conflict(path) }
            if let limit = failPutsAfter, puts.count >= limit { throw SyncError.network("injected") }
            let current = objects[path].map(GitBlob.sha)
            guard current == ifMatch else { throw SyncError.conflict(path) }
            objects[path] = data
            puts.append(path)
            return GitBlob.sha(data)
        }
    }

    private func syncList(_ prefix: String) -> [String: String] {
        lock.withLock {
            lists += 1
            return objects.filter { $0.key.hasPrefix(prefix) }.mapValues(GitBlob.sha)
        }
    }

    // Test helpers
    subscript(path: String) -> Data? {
        get { lock.lock(); defer { lock.unlock() }; return objects[path] }
        set { lock.lock(); defer { lock.unlock() }; objects[path] = newValue }
    }

    var paths: [String] { lock.lock(); defer { lock.unlock() }; return objects.keys.sorted() }

    func resetCounters() {
        lock.lock(); defer { lock.unlock() }
        gets = []; puts = []; lists = 0; deletes = []
    }
}
