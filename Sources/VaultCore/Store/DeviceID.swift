import Foundation

/// Stable per-installation id recorded in the manifest so sync can tell devices apart.
public enum DeviceID {
    static let key = AppIdentity.bundleID + ".deviceID"

    public static var current: UUID {
        if let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
