import AppKit
import Foundation
import VaultCore

/// Trial and licence state of this Mac, kept outside the vault (UserDefaults, plus the Keychain for the trial
/// start). After the trial, without a licence, Satchel is blocked except for unlocking, entering a key and
/// exporting the items (`allowsUse`): nothing here can make an item unreadable.
@MainActor
final class Licensing: ObservableObject {
    static let shared = Licensing()
    static let licenseKeyKey = "licenseKey"

    @Published private(set) var license: License?
    let trial: Trial
    private var trialEndTimer: Timer?

    /// Public half of the licence signing key, set by `scripts/bundle.sh` from Resources/license-public-key.txt.
    var publicKey: String {
        #if DEBUG
        if let k = ProcessInfo.processInfo.environment["SATCHEL_LICENSE_PUBKEY"] { return k }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "SatchelLicensePublicKey") as? String ?? ""
    }

    /// Public half of the sandbox (test card) signing key, from Resources/license-test-public-key.txt. Only used to
    /// recognise a test key and explain why it does not activate.
    var testPublicKey: String { Bundle.main.object(forInfoDictionaryKey: "SatchelLicenseTestPublicKey") as? String ?? "" }

    /// A build without a licence key (built from source without one) has nothing to check against: everything is on.
    var isEnforced: Bool { !publicKey.isEmpty }

    /// False once the trial is over without a licence: the main window shows the trial-ended screen and
    /// Quick Access, browser fill and auto-type refuse.
    var allowsUse: Bool { License.allowsUse(enforced: isEnforced, license: license, trial: trial) }

    /// True while unlicensed and the trial is still running: the trial note shows then.
    var inTrial: Bool { isEnforced && license == nil }

    private init() {
        trial = Trial(started: TrialStore().start())
        license = nil
        license = UserDefaults.standard.string(forKey: Self.licenseKeyKey).flatMap { License.parse($0, publicKey: publicKey) }
        // The window switches to the trial-ended screen at the moment the trial ends, not at the next redraw.
        // A timer that is due while the Mac sleeps fires on wake.
        if isEnforced, license == nil, !trial.isOver() {
            trialEndTimer = Timer.scheduledTimer(withTimeInterval: trial.ends().timeIntervalSinceNow + 1, repeats: false) { _ in
                MainActor.assumeIsolated { Licensing.shared.objectWillChange.send() }
            }
        }
    }

    /// Whether the licence (or a running trial) includes a release; otherwise it is offered as a renewal.
    func covers(_ offer: UpdateOffer) -> Bool {
        guard isEnforced else { return true }
        if let license { return license.covers(release: offer.published) }
        return !trial.isOver()
    }

    /// Checks and keeps a pasted key. Returns nil when it activated, otherwise what to tell the person.
    func activate(_ text: String) -> String? {
        switch License.check(text, publicKey: publicKey, testPublicKey: testPublicKey) {
        case .valid(let l):
            UserDefaults.standard.set(text.filter { !$0.isWhitespace }, forKey: Self.licenseKeyKey)
            license = l
            return nil
        case .testKey:
            return "This is a test key, from a purchase with a test card. Only keys from real purchases activate \(AppIdentity.name)."
        case .invalid:
            return "This key is not valid. Paste it exactly as you received it."
        }
    }

    /// `satchel://activate?key=…`, from the thank-you page or the purchase email.
    func activate(link url: URL) {
        guard let key = License.key(fromActivationURL: url) else { return }
        AppDelegate.openMainWindow()
        if let problem = activate(key) {
            let alert = NSAlert()
            alert.messageText = "This licence link did not work"
            alert.informativeText = problem + " If a key from a real purchase is refused, reply to your purchase email."
            alert.runModal()
        } else {
            NotchHUD.shared.show(title: "Licence activated", detail: "Thank you for buying \(AppIdentity.name)")
        }
    }

    func remove() {
        UserDefaults.standard.removeObject(forKey: Self.licenseKeyKey)
        license = nil
    }

    static let endedMessage = "Your trial has ended. Enter a licence key in Satchel to keep using it, or export your items there."
}
