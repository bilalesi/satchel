import Foundation
import Security

/// Remembers when the trial started, in UserDefaults and in the login Keychain. Removing the app, its
/// preferences (`defaults delete`) or reinstalling clears the first copy, not the second, and the earliest copy
/// wins, so none of that restarts the trial. A start later than now (the clock was set back since) is pulled
/// back to now, so a clock set forward on the first launch cannot stretch the trial either.
///
/// The date is kept in the Keychain item's attributes, not its secret data: attributes are read without a
/// Keychain prompt, also after an update changes the app's code signature. The date is not a secret.
/// ponytail: the Keychain copy is only written when missing (changing an item can prompt for permission), and
/// deleting it by hand together with the preferences still restarts the trial; perfect DRM in a native binary
/// is not achievable (§6.3).
public struct TrialStore {
    public static let key = "trialStarted"
    let defaults: UserDefaults
    let service: String

    /// The service is per bundle id, so the demo copy (its own id) never touches the real app's trial.
    public init(defaults: UserDefaults = .standard, service: String = (Bundle.main.bundleIdentifier ?? AppIdentity.bundleID) + ".trial") {
        self.defaults = defaults
        self.service = service
    }

    /// The trial start; the first call on a Mac records `now`.
    public func start(now: Date = Date()) -> Date {
        let kept = keychainDate()
        let start = min([defaults.object(forKey: Self.key) as? Date, kept].compactMap { $0 }.min() ?? now, now)
        defaults.set(start, forKey: Self.key)
        if kept == nil { saveToKeychain(start) }
        return start
    }

    func keychainDate() -> Date? {
        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let text = (out as? [String: Any])?[kSecAttrComment as String] as? String,
              let seconds = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    @discardableResult
    func saveToKeychain(_ date: Date) -> Bool {
        var add = item
        add[kSecAttrLabel as String] = "\(AppIdentity.name) trial"
        add[kSecAttrComment as String] = String(date.timeIntervalSince1970)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func removeFromKeychain() { SecItemDelete(item as CFDictionary) }

    /// A generic password in the login keychain (not synced through iCloud: the trial is per Mac).
    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.key]
    }
}
