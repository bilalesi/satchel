import Foundation

/// Reads files that another party controls (a cloned repository, a shared folder) without being
/// tricked by what is on disk: a symlink to a device or a large file, a FIFO that never ends.
enum SafeFile {
    /// Vault objects are kilobytes; this is far above any real one and far below memory trouble.
    static let maxBytes = 32 * 1024 * 1024

    /// `nil` when the file does not exist. Throws for anything that is not a plain file within the size limit.
    static func readRegular(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw SyncError.network("\(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxBytes else {
            throw SyncError.remote(status: 0, message: "\(url.lastPathComponent) is not a plain file of a sensible size; refusing to read it.")
        }
        do { return try Data(contentsOf: url, options: [.uncached]) }
        catch { throw SyncError.network(error.localizedDescription) }
    }

    /// For directory listings: entries that are not plain files are skipped, not read.
    static func isRegular(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}
