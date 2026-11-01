import Foundation

/// Write-temp-then-rename so a crash leaves either the old file or the new one, never a
/// partial one. `rename(2)` is atomic on APFS within one volume; the temp file lives in
/// the target directory to guarantee that.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            let fh = try FileHandle(forWritingTo: tmp)
            try fh.synchronize() // fsync before rename so the rename never points at unflushed data
            try fh.close()
            guard rename(tmp.path, url.path) == 0 else {
                throw VaultError.io("rename failed: \(String(cString: strerror(errno)))")
            }
        } catch let e as VaultError {
            try? FileManager.default.removeItem(at: tmp)
            throw e
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw VaultError.io(error.localizedDescription)
        }
    }

    static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: [.uncached]) }
        catch { throw VaultError.io("read \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}
