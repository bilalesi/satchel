import AppKit
import SwiftUI
import VaultCore

@main
struct VaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session: VaultSession
    @StateObject private var updates = UpdateManager()

    init() {
        AppSettings.registerDefaults()
        let s = VaultSession()
        _session = StateObject(wrappedValue: s)
        AppDelegate.session = s
    }

    var body: some Scene {
        Window(AppIdentity.name, id: "main") {
            MainWindow().environmentObject(session).environmentObject(session.sync).environmentObject(updates)
                .onAppear { updates.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Lock \(AppIdentity.name)") { session.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(session.state != .unlocked)
            }
        }

        Settings {
            SettingsView().environmentObject(session).environmentObject(session.sync).environmentObject(updates)
        }

        MenuBarExtra {
            Button("Quick Access  \(HotKey.shared.label)") { QuickAccessController.shared.toggle() }
            Button(session.state == .unlocked ? "Lock now" : "Locked") { session.lock() }
                .disabled(session.state != .unlocked)
            if case .available(let o) = updates.state {
                Button("Update to \(o.version.description)…") { Task { await updates.download() } }
            } else if case .ready(let o, _) = updates.state {
                Button("Restart to update to \(o.version.description)") { Task { await updates.installAndRelaunch() } }
            }
            Button("Sync now") { Task { await session.sync.syncNow(announce: true) } }
                .disabled(session.state != .unlocked || !session.sync.isConfigured)
            Divider()
            Button("Open \(AppIdentity.name)") { AppDelegate.openMainWindow() }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(nsImage: (session.state == .unlocked ? Codicon.unlock : Codicon.lock).image(size: 16))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var session: VaultSession?
    @MainActor static var bridge: BridgeServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSScrollView.installRoundedScrollers()
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["SATCHEL_SPLASH_DUMP"] { SplashDump.run(to: folder); return }
        #endif
        // One instance per user: a second copy would take over the browser bridge socket and
        // open the same vault. Hand over to the running one instead.
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? AppIdentity.bundleID).first(where: { $0.processIdentifier != me }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        guard let session = Self.session else { return }
        Self.warnIfNotInstalled()
        QuickAccessController.shared.install(session: session)
        let handler = BridgeHandler(session: session)
        Self.bridge = try? BridgeServer { req in await handler.handle(req) }
        NativeMessagingInstaller.refreshStalePaths()
        HotKey.shared.onPress = { QuickAccessController.shared.toggle() }
        HotKey.shared.setEnabled(UserDefaults.standard.bool(forKey: AppSettings.hotKeyEnabledKey))
        // Every window of this app stays out of screen capture, including ones created later.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            if let w = n.object as? NSWindow { MainActor.assumeIsolated { AppSettings.applyCapturePolicy(to: w) } }
        }
    }

    /// Running from the DMG (or from a quarantined download) means the app disappears on eject,
    /// cannot update itself, and browser integration points into a volume that goes away.
    @MainActor
    private static func warnIfNotInstalled() {
        let path = Bundle.main.bundlePath
        let fromDiskImage = path.hasPrefix("/Volumes/")
        let translocated = path.contains("/AppTranslocation/")
        guard fromDiskImage || translocated else { return }
        let alert = NSAlert()
        alert.messageText = "Move Satchel to Applications first"
        alert.informativeText = "Satchel is running from \(fromDiskImage ? "the disk image" : "a temporary location"). Drag it onto the Applications folder, eject the disk image, and open it from there. Your vault is not affected."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Continue Anyway")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.session?.lock() }
    }

    @MainActor
    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == AppIdentity.name }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
    }
}
