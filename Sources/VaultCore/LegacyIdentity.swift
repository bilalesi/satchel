import Foundation

/// Satchel was `com.bilalesi.satchel` until it moved to the ekhodev organization. macOS keeps preferences per
/// bundle id, so the renamed app would start with none: no licence key, no workspaces, no settings, a new device id.
/// `migrateDefaults` copies them over once, at launch, before anything reads them.
///
/// The vault itself is unaffected (its folder is named after the app, not the bundle id). The trial's Keychain copy
/// is not moved: the trial start comes across in the preferences, and the earliest copy wins (`TrialStore`).
public enum LegacyIdentity {
    public static let bundleID = "com.bilalesi.satchel"

    /// Copies the old preferences when the new domain is still empty. Returns whether it did.
    @discardableResult
    public static func migrateDefaults(from old: String = bundleID, to new: String = AppIdentity.bundleID,
                                       defaults: UserDefaults = .standard) -> Bool {
        guard (defaults.persistentDomain(forName: new) ?? [:]).isEmpty,
              var values = defaults.persistentDomain(forName: old), !values.isEmpty else { return false }
        // Keys that carry the bundle id in their name (the device id) follow it.
        for (key, value) in values where key.hasPrefix(old + ".") {
            values.removeValue(forKey: key)
            values[new + key.dropFirst(old.count)] = value
        }
        defaults.setPersistentDomain(values, forName: new)
        return true
    }
}
