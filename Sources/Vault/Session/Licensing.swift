import Foundation
import VaultCore

/// Trial and licence state of this Mac. Stored in UserDefaults, outside the vault: nothing here can lock
/// anyone out of their items. After the trial, without a licence, only browser fill and auto-type pause;
/// unlocking, reading, copying, editing and sync keep working (see `conveniencesOn`).
@MainActor
final class Licensing: ObservableObject {
    static let shared = Licensing()
    static let licenseKeyKey = "licenseKey"
    static let trialStartedKey = "trialStarted"

    @Published private(set) var license: License?
    let trial: Trial

    /// Public half of the licence signing key, set by `scripts/bundle.sh` from Resources/license-public-key.txt.
    var publicKey: String {
        #if DEBUG
        if let k = ProcessInfo.processInfo.environment["SATCHEL_LICENSE_PUBKEY"] { return k }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "SatchelLicensePublicKey") as? String ?? ""
    }

    /// A build without a licence key (built from source without one) has nothing to check against: everything is on.
    var isEnforced: Bool { !publicKey.isEmpty }

    /// Browser fill and auto-type: the conveniences a licence keeps on after the trial.
    var conveniencesOn: Bool { !isEnforced || license != nil || !trial.isOver() }

    /// True while unlicensed and the trial is still running: the trial note shows then.
    var inTrial: Bool { isEnforced && license == nil }

    private init() {
        let d = UserDefaults.standard
        if !(d.object(forKey: Self.trialStartedKey) is Date) { d.set(Date(), forKey: Self.trialStartedKey) }
        trial = Trial(started: d.object(forKey: Self.trialStartedKey) as? Date ?? Date())
        license = nil
        license = d.string(forKey: Self.licenseKeyKey).flatMap { License.parse($0, publicKey: publicKey) }
    }

    /// Whether the licence (or a running trial) includes a release; otherwise it is offered as a renewal.
    func covers(_ offer: UpdateOffer) -> Bool {
        guard isEnforced else { return true }
        if let license { return license.covers(release: offer.published) }
        return !trial.isOver()
    }

    /// Checks and keeps a pasted key. Returns false for a key that does not verify.
    func activate(_ text: String) -> Bool {
        guard let l = License.parse(text, publicKey: publicKey) else { return false }
        UserDefaults.standard.set(text.filter { !$0.isWhitespace }, forKey: Self.licenseKeyKey)
        license = l
        return true
    }

    func remove() {
        UserDefaults.standard.removeObject(forKey: Self.licenseKeyKey)
        license = nil
    }

    static let endedMessage = "Your trial has ended. Browser fill and auto-type come back with a licence (Settings → Licence). Your items stay open in Satchel."
}
