import AppKit
import SwiftUI

/// Floating, non-activating panel so the app in front keeps focus and its bundle id is
/// known before the panel appears. Created once at launch; `toggle()` only orders it
/// front, so it shows in well under a frame.
@MainActor
final class QuickAccessController {
    static let shared = QuickAccessController()

    private var panel: QuickAccessPanel?
    private(set) var frontmostBundleID: String?
    /// The application to type into; captured before the panel takes key status.
    private(set) var frontmostApp: NSRunningApplication?
    private var session: VaultSession?

    private init() {}

    func install(session: VaultSession) {
        self.session = session
        let panel = QuickAccessPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                                     styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                     backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        AppSettings.applyCapturePolicy(to: panel)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: QuickAccessView().environmentObject(session))
        panel.onResignKey = { [weak self] in self?.hide() }
        self.panel = panel
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard let panel else { return }
        // Capture before we take key status; the frontmost app is the fill target.
        let front = NSWorkspace.shared.frontmostApplication
        frontmostApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        frontmostBundleID = frontmostApp?.bundleIdentifier
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.62 - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickAccessDidShow, object: nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

final class QuickAccessPanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

extension Notification.Name {
    static let quickAccessDidShow = Notification.Name("quickAccessDidShow")
}
