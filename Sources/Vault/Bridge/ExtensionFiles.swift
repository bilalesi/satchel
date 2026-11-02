import Foundation
import VaultCore

/// A browser keeps loading an unpacked extension from the folder it was added from. Inside the app bundle that
/// folder moves whenever the app is renamed, moved or reinstalled (Dia still pointed at `build/Vault.app` after
/// the rename, and the extension died without a word). So a copy lives in Satchel's own data folder, which
/// never moves, is refreshed at every launch, and is the path Settings offers.
enum ExtensionFiles {
    static var stableURL: URL { AppIdentity.supportDirectory.appendingPathComponent("extension", isDirectory: true) }

    private static var bundledURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("extension", isDirectory: true)
    }

    /// Copies the bundled extension over the stable copy when they differ. Nothing is touched when they match,
    /// so a browser that has the extension loaded is not disturbed on every launch.
    static func refresh() {
        let fm = FileManager.default
        guard let src = bundledURL, fm.fileExists(atPath: src.path), files(in: src) != files(in: stableURL) else { return }
        let staging = stableURL.deletingLastPathComponent().appendingPathComponent("extension.new", isDirectory: true)
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: staging)
            try? fm.removeItem(at: stableURL)
            try fm.moveItem(at: staging, to: stableURL)
        } catch {
            try? fm.removeItem(at: staging) // the old copy, if any, stays in place
        }
    }

    /// Relative path → bytes, for every file under `root` (empty when it does not exist).
    private static func files(in root: URL) -> [String: Data] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result[String(url.path.dropFirst(root.path.count))] = try? Data(contentsOf: url)
        }
        return result
    }
}
