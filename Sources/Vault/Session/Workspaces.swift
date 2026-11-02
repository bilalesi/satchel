import Foundation
import VaultCore

/// A workspace is a separate vault with its own master password, Touch ID, categories and
/// sync target ("Work", "Personal"). Only the list and the active choice are stored here;
/// everything else lives inside each vault.
struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String
    /// Look of the workspace tile. Optional so lists saved before they existed still load.
    var iconName: String?
    var colorName: String?

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var look: (icon: String, color: String) { (iconName ?? "layers", colorName ?? "blue") }
}

enum WorkspaceStore {
    static let listKey = "workspaces"
    static let activeKey = "activeWorkspace"

    /// The registered workspaces; the first launch registers the existing vault as "Personal".
    static func load() -> (list: [Workspace], active: UUID) {
        let d = UserDefaults.standard
        var list = d.data(forKey: listKey).flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? []
        if list.isEmpty {
            list = [Workspace(id: UUID(), name: "Personal", path: AppSettings.vaultURL.path, iconName: "home", colorName: "blue")]
        }
        let active = d.string(forKey: activeKey).flatMap(UUID.init(uuidString:)).flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list[0].id
        save(list, active: active)
        return (list, active)
    }

    static func save(_ list: [Workspace], active: UUID) {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(list), forKey: listKey)
        d.set(active.uuidString, forKey: activeKey)
    }

    /// Location for a new workspace's vault.
    static func newPath() -> String {
        AppIdentity.workspacesURL.appendingPathComponent(UUID().uuidString.lowercased() + ".vault", isDirectory: true).path
    }
}
