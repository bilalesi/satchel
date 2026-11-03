import Foundation

/// A directory as a remote: iCloud Drive, Dropbox, a network share, a USB stick.
///
/// The folder itself must exist: a share that is not mounted or a drive that is not plugged in leaves an empty
/// mount point (or none) behind, and reading that as "an empty remote" would make a new Mac upload its vault onto the
/// boot disk, or an old one report a wiped remote. So every operation first checks the folder is there.
/// ponytail: compare-then-write without a lock; one user with two devices, and the
/// cloud client serialises uploads anyway. Upgrade path: O_EXLOCK on a `.lock` file.
public final class FolderStore: RemoteStore {
    public let root: URL
    public var displayName: String { "Folder " + root.lastPathComponent }

    public init(root: URL) {
        self.root = root
    }

    private func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// Throws `unavailable` unless the folder exists and is a directory. Subfolders (`items/`) are created as needed.
    public func verify() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncError.unavailable("The folder \(root.path)")
        }
    }

    public func get(_ path: String) async throws -> RemoteObject? {
        try verify()
        guard let data = try SafeFile.readRegular(url(path)) else { return nil }
        return RemoteObject(data: data, etag: GitBlob.sha(data))
    }

    public func put(_ path: String, data: Data, ifMatch: String?) async throws -> String {
        try verify()
        let current = try await get(path)?.etag
        guard current == ifMatch else { throw SyncError.conflict(path) }
        let target = url(path)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try AtomicFile.write(data, to: target)
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
        return GitBlob.sha(data)
    }

    public func delete(_ path: String, ifMatch: String?) async throws {
        try verify()
        let current = try await get(path)
        guard let current else { return }
        if let ifMatch, current.etag != ifMatch { throw SyncError.conflict(path) }
        do { try FileManager.default.removeItem(at: url(path)) }
        catch { throw SyncError.network(error.localizedDescription) }
    }

    public func list(prefix: String) async throws -> [String: String] {
        try verify()
        let dir = url(prefix)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: String] = [:]
        for name in names where !name.hasPrefix(".") {
            let file = dir.appendingPathComponent(name)
            if SafeFile.isRegular(file), let data = try? SafeFile.readRegular(file) {
                out[prefix + name] = GitBlob.sha(data)
            }
        }
        return out
    }
}
