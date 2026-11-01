import AppKit
import SwiftUI
import VaultCore

@main
struct VaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session: VaultSession

    init() {
        AppSettings.registerDefaults()
        let s = VaultSession()
        _session = StateObject(wrappedValue: s)
        AppDelegate.session = s
    }

    var body: some Scene {
        Window(AppIdentity.name, id: "main") {
            MainWindow().environmentObject(session).environmentObject(session.sync)
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
            SettingsView().environmentObject(session).environmentObject(session.sync)
        }

        MenuBarExtra {
            Button("Quick Access  ⌥ Space") { QuickAccessController.shared.toggle() }
            Button(session.state == .unlocked ? "Lock now" : "Locked") { session.lock() }
                .disabled(session.state != .unlocked)
            Button("Sync now") { Task { await session.sync.syncNow() } }
                .disabled(session.state != .unlocked || !session.sync.isConfigured)
            Divider()
            Button("Open \(AppIdentity.name)") { AppDelegate.openMainWindow() }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: session.state == .unlocked ? "lock.open.fill" : "lock.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var session: VaultSession?
    @MainActor static var bridge: BridgeServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let session = Self.session else { return }
        QuickAccessController.shared.install(session: session)
        let handler = BridgeHandler(session: session)
        Self.bridge = try? BridgeServer { req in await handler.handle(req) }
        NativeMessagingInstaller.refreshStalePaths()
        HotKey.shared.onPress = { QuickAccessController.shared.toggle() }
        HotKey.shared.setEnabled(UserDefaults.standard.bool(forKey: AppSettings.hotKeyEnabledKey))
        // Every window of this app stays out of screen capture, including ones created later.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            (n.object as? NSWindow)?.sharingType = .none
        }
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
