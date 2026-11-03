import AppKit
import Combine
import CryptoKit
import Foundation
import os
import VaultCore

/// Checks satchel.echospace.dev for a newer signed build, downloads it, verifies its size, SHA-256 and
/// Ed25519 signature against the public key baked into this app, and swaps the app bundle.
///
/// Network use is limited to satchel.echospace.dev (the feed and the DMG). Nothing about the vault or the
/// user is sent. Turn it off in Settings → General.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case available(UpdateOffer)
        /// Newer than the licence's year of updates: offered as a renewal, never downloaded.
        case renew(UpdateOffer)
        case downloading(UpdateOffer, Double)
        case ready(UpdateOffer, URL)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    /// Result of the last manual check ("You're up to date"), shown in Settings.
    @Published private(set) var message: String?

    static let enabledKey = "autoUpdateCheck"
    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "update")
    private var timer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession!
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var downloadingOffer: UpdateOffer?
    /// SHA-256 of the DMG at the moment its signature was verified; checked again right before install.
    private var verifiedDigest: String?
    private var licenseWatch: AnyCancellable?

    // MARK: Configuration

    private var publicKey: String {
        #if DEBUG
        if let k = ProcessInfo.processInfo.environment["SATCHEL_UPDATE_PUBKEY"] { return k }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "SatchelUpdatePublicKey") as? String ?? ""
    }

    private var feedURL: URL? {
        #if DEBUG
        if let f = ProcessInfo.processInfo.environment["SATCHEL_UPDATE_FEED"] { return URL(string: f) }
        #endif
        return UpdateFeed.url
    }

    private var allowLocal: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SATCHEL_UPDATE_FEED"] != nil
        #else
        return false
        #endif
    }

    /// Updates need the public key; a build without it (a development build) never contacts the network for updates.
    var isAvailable: Bool { !publicKey.isEmpty }

    var isEnabled: Bool { isAvailable && UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") ?? AppVersion("0")!
    }

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        // Observer: a key entered in Settings or through a satchel://activate link may change what an offer is.
        licenseWatch = Licensing.shared.$license.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.licenseChanged() }
    }

    /// Checks shortly after launch and then every six hours, if the user allows it.
    func start() {
        guard timer == nil else { return }
        announceInstalledUpdate()
        Task { try? await Task.sleep(for: .seconds(8)); await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
    }

    /// The version that ran last time is remembered; when it is older than this one, an update was installed.
    private func announceInstalledUpdate() {
        let key = "lastRunVersion", defaults = UserDefaults.standard
        let now = currentVersion
        defer { defaults.set(now.description, forKey: key) }
        guard let old = defaults.string(forKey: key).flatMap(AppVersion.init), old < now else { return }
        NotchHUD.shared.show(title: "Satchel updated", detail: "Now on version \(now)")
    }

    // MARK: Check

    func check(manual: Bool) async {
        guard isAvailable else { if manual { message = "Updates are not set up in this build." }; return }
        guard manual || isEnabled else { return }
        switch state { case .downloading, .installing, .ready, .checking: return; default: break }
        if manual { message = nil }
        let previous = state
        state = .checking
        defer { lastChecked = Date() }
        do {
            guard let url = feedURL else { throw URLError(.badURL) }
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("\(AppIdentity.name)/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let sent = Date()
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            // The same answer says what time it is: one-time codes correct for a drifting clock with it.
            if let skew = ClockSkew.record(dateHeader: http?.value(forHTTPHeaderField: "Date"), age: http?.value(forHTTPHeaderField: "Age"),
                                           sent: sent, received: Date()), skew != 0 {
                Self.log.notice("clock is off by \(skew, format: .fixed(precision: 1), privacy: .public) s; one-time codes corrected")
            }
            let status = http?.statusCode ?? 0
            if status == 404 { state = previousOrIdle(previous); if manual { message = "You're up to date." }; return }
            guard status == 200 else { throw URLError(.badServerResponse) }
            if let offer = UpdateFeed.parse(data, current: currentVersion, allowLocal: allowLocal) {
                let covered = Licensing.shared.covers(offer)
                if case .available(let known) = previous, known.version == offer.version {} else if case .renew(let known) = previous, known.version == offer.version {} else {
                    NotchHUD.shared.show(title: covered ? "Update available" : "Satchel \(offer.version) is out",
                                         detail: covered ? "Satchel \(offer.version) is ready to download" : "Renew your licence for another year of updates")
                }
                state = covered ? .available(offer) : .renew(offer)
                Self.log.notice("update available: \(offer.version.description, privacy: .public)")
            } else {
                state = .idle
                if manual { message = "You're up to date (\(currentVersion))." }
            }
        } catch {
            state = previousOrIdle(previous)
            Self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if manual { message = "Could not check for updates: \(error.localizedDescription)" }
        }
    }

    private func previousOrIdle(_ s: State) -> State {
        switch s { case .available, .renew: return s; default: return .idle }
    }

    /// After a licence is entered or removed, an offer may move between "download" and "renew".
    private func licenseChanged() {
        if case .renew(let o) = state, Licensing.shared.covers(o) { state = .available(o) }
        else if case .available(let o) = state, !Licensing.shared.covers(o) { state = .renew(o) }
    }

    // MARK: Download

    func download() async {
        let offer: UpdateOffer
        switch state {
        case .available(let o): offer = o
        case .failed: await check(manual: true); guard case .available(let o) = state else { return }; offer = o
        default: return
        }
        state = .downloading(offer, 0)
        do {
            let file = try await fetch(offer.dmgURL)
            let key = publicKey
            let digest = try await Task.detached(priority: .userInitiated) { () -> String? in
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let digest = Self.sha256(data)
                guard data.count == offer.size, digest == offer.sha256,
                      UpdateSignature.verify(data, signature: offer.signature, publicKey: key) else { return nil }
                return digest
            }.value
            guard let digest else {
                try? FileManager.default.removeItem(at: file)
                throw UpdateError.badSignature
            }
            let kept = try Self.keep(file, as: "Satchel-\(offer.version).dmg")
            verifiedDigest = digest
            state = .ready(offer, kept)
        } catch {
            Self.log.error("update download failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func fetch(_ url: URL) async throws -> URL {
        guard allowLocal || UpdateFeed.isAllowedDownloadURL(url) else { throw UpdateError.untrustedURL }
        return try await withCheckedThrowingContinuation { cont in
            let task = session.downloadTask(with: url)
            downloadContinuation = cont
            downloadTask = task
            if case .downloading(let o, _) = state { downloadingOffer = o }
            task.resume()
        }
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func keep(_ temp: URL, as name: String) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.bundleID, isDirectory: true).appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    // MARK: Install

    /// Replaces this app with the verified one and relaunches. If the app's folder is not
    /// writable (not an admin user), the DMG is opened for a manual drag instead.
    func installAndRelaunch() async {
        guard case .ready(let offer, let dmg) = state else { return }
        state = .installing
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app", FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(dmg)
            state = .ready(offer, dmg)
            message = "Drag Satchel onto Applications to finish updating."
            return
        }
        do {
            let pid = ProcessInfo.processInfo.processIdentifier
            guard let expected = verifiedDigest else { throw UpdateError.badSignature }
            let staged = try await Task.detached(priority: .userInitiated) { () -> URL in
                // The file sat in a user-writable cache between verification and now: check it is
                // still exactly what was verified before mounting it.
                let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
                guard Self.sha256(data) == expected else { throw UpdateError.badSignature }
                return try Installer.stage(dmg: dmg, nextTo: appURL, expectedVersion: offer.version.description)
            }.value
            try Installer.launchSwap(pid: pid, old: appURL, new: staged)
            NSApp.terminate(nil)
        } catch {
            Self.log.error("update install failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }
}

enum UpdateError: LocalizedError {
    case badSignature, untrustedURL, installFailed(String)
    var errorDescription: String? {
        switch self {
        case .badSignature: return "The download failed its signature check and was discarded."
        case .untrustedURL: return "The update is not hosted where Satchel expects it."
        case .installFailed(let m): return m
        }
    }
}

// MARK: Download delegate

extension UpdateManager: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(UpdateFeed.maxDownloadBytes)
        let fraction = min(1, Double(totalBytesWritten) / Double(total))
        Task { @MainActor in
            if case .downloading(let o, _) = self.state { self.state = .downloading(o, fraction) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns: move it somewhere we own first.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("satchel-update-\(UUID().uuidString).dmg")
        let result: Result<URL, Error>
        do { try FileManager.default.moveItem(at: location, to: owned); result = .success(owned) } catch { result = .failure(error) }
        Task { @MainActor in
            self.downloadContinuation?.resume(with: result)
            self.downloadContinuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.downloadContinuation?.resume(throwing: error)
            self.downloadContinuation = nil
        }
    }

    /// A redirect may only lead to satchel.echospace.dev, over https.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url else { return completionHandler(nil) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SATCHEL_UPDATE_FEED"] != nil { return completionHandler(request) }
        #endif
        completionHandler(UpdateFeed.isAllowedDownloadURL(url) ? request : nil)
    }
}

// MARK: Installer

/// Disk work for an update. Everything here runs off the main thread.
enum Installer {
    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.installFailed(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Mounts the verified DMG, copies the app next to the installed one and checks it.
    static func stage(dmg: URL, nextTo installed: URL, expectedVersion: String) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("satchel-mnt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        let source = mount.appendingPathComponent("Satchel.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.installFailed("The update does not contain Satchel.app.") }
        let staged = installed.deletingLastPathComponent().appendingPathComponent(".Satchel-update-\(UUID().uuidString).app")
        do {
            try run("/usr/bin/ditto", [source.path, staged.path])
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            let plist = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
            guard plist?["CFBundleIdentifier"] as? String == AppIdentity.bundleID,
                  plist?["CFBundleShortVersionString"] as? String == expectedVersion else {
                throw UpdateError.installFailed("The update is not the expected version of Satchel.")
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// Starts a detached script that waits for this process to exit, swaps the bundles
    /// (restoring the old one if anything fails) and opens the new app.
    static func launchSwap(pid: Int32, old: URL, new: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; OLD="$2"; NEW="$3"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2; i=$((i+1))
          # The old app did not quit: leave everything as it was.
          if [ $i -gt 150 ]; then rm -rf "$NEW"; rm -f "$0"; exit 1; fi
        done
        BACKUP="$OLD.previous-$$"
        if mv "$OLD" "$BACKUP"; then
          if mv "$NEW" "$OLD"; then
            xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
            rm -rf "$BACKUP"
          else
            mv "$BACKUP" "$OLD"
          fi
        fi
        rm -rf "$NEW" 2>/dev/null
        open "$OLD"
        rm -f "$0"
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("satchel-swap-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [file.path, String(pid), old.path, new.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
