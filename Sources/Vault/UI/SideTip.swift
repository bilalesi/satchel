import SwiftUI

/// A tooltip for icon-only controls in a narrow rail: a small dark label beside the icon, centred on it, that
/// appears quickly (almost at once when the pointer moves from one icon to the next) and goes away when the
/// pointer leaves, a button is pressed, the list scrolls or a key is typed. It lives in its own window so it
/// can sit over the neighbouring pane, never takes focus and ignores the mouse.
@MainActor
final class SideTipController {
    static let shared = SideTipController()

    private var panel: NSPanel?
    private let label = SideTipLabel()
    private var pending: Task<Void, Never>?
    private var lastHidden = Date.distantPast
    private var monitor: Any?

    /// Wait before the first label of a hover; none while the pointer is moving between icons.
    private static let firstDelay: Duration = .milliseconds(250)
    private static let quickWindow: TimeInterval = 0.5

    func hover(_ text: String, anchor: NSView?) {
        pending?.cancel()
        let quick = panel?.isVisible == true || Date().timeIntervalSince(lastHidden) < Self.quickWindow
        pending = Task { [weak self] in
            if !quick { try? await Task.sleep(for: Self.firstDelay) }
            guard !Task.isCancelled, let self, let anchor else { return }
            self.show(text, anchor: anchor)
        }
    }

    func leave() {
        pending?.cancel()
        hide()
    }

    private func show(_ text: String, anchor: NSView) {
        guard let window = anchor.window, window.isVisible else { return }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = label.set(text)
        // 8 pt right of the icon, centred on it, and kept on the screen.
        var origin = NSPoint(x: rect.maxX + 8, y: rect.midY - size.height / 2)
        if let screen = window.screen ?? NSScreen.main {
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width)
            origin.y = min(max(origin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
        panel.invalidateShadow()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.leave() }
                return event
            }
        }
    }

    private func hide() {
        guard panel?.isVisible == true else { return }
        lastHidden = Date()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true // follows the label's rounded shape
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        AppSettings.applyCapturePolicy(to: p)
        p.contentView = label
        return p
    }
}

/// The label itself: white text on a dark rounded rectangle. Plain AppKit: as a SwiftUI view in a pop-up
/// window it was pinned to the size of its first, empty text.
private final class SideTipLabel: NSView {
    private static let padX: CGFloat = 10, padY: CGFloat = 5
    private let text = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = .white
        text.lineBreakMode = .byClipping
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sets the text and returns the size the label needs.
    func set(_ string: String) -> NSSize {
        text.stringValue = string
        text.sizeToFit()
        let size = NSSize(width: ceil(text.frame.width) + 2 * Self.padX, height: ceil(text.frame.height) + 2 * Self.padY)
        text.frame.origin = NSPoint(x: Self.padX, y: Self.padY)
        setFrameSize(size)
        return size
    }
}

private struct SideTipModifier: ViewModifier {
    let text: String
    @State private var anchor = AnchorBox()

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(box: anchor))
            .onHover { inside in
                if inside { SideTipController.shared.hover(text, anchor: anchor.view) } else { SideTipController.shared.leave() }
            }
            .onDisappear { SideTipController.shared.leave() }
        #if DEBUG
            .onAppear { // UI testing only: show this label at launch, without a pointer
                guard ProcessInfo.processInfo.environment["SATCHEL_DEBUG_SIDETIP"] == text else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SideTipController.shared.hover(text, anchor: anchor.view) }
            }
        #endif
    }
}

private struct SideTipsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside a narrow icon rail: `railHint` then uses the side label instead of the system tooltip.
    var sideTips: Bool {
        get { self[SideTipsKey.self] }
        set { self[SideTipsKey.self] = newValue }
    }
}

private struct HintModifier: ViewModifier {
    let text: String
    @Environment(\.sideTips) private var side

    @ViewBuilder
    func body(content: Content) -> some View {
        if side { content.sideTip(text) } else { content.tooltip(text) }
    }
}

extension View {
    /// The dark label beside an icon of a rail.
    func sideTip(_ text: String) -> some View { modifier(SideTipModifier(text: text)) }
    /// The side label inside a rail (`sideTips`), the system tooltip anywhere else.
    func railHint(_ text: String) -> some View { modifier(HintModifier(text: text)) }
}
