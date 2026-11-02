import AppKit
import SwiftUI

/// A short confirmation at the top of the screen, for things that happen where you cannot see
/// Satchel's window: a secret copied from Quick Access, the vault locking itself. On a Mac with a
/// notch it grows out of the notch (the black shape merges with it); on other Macs it is a small
/// black pill under the menu bar. It never takes focus and ignores the mouse.
@MainActor
final class NotchHUD {
    static let shared = NotchHUD()
    nonisolated static let enabledKey = "notchHUD"

    enum Tint { case success, neutral, warning }

    struct Message: Equatable {
        var icon: Codicon
        var title: String
        var detail: String?
        var tint: Tint
    }

    /// Where the HUD sits on one screen. `notchWidth` is the hardware cut-out, 0 without a notch.
    struct Geometry: Equatable {
        var hasNotch: Bool
        var notchWidth: CGFloat
        var height: CGFloat
        var width: CGFloat
        var frame: CGRect

        static let wing: CGFloat = 138

        init(screen: NSScreen) {
            let inset = screen.safeAreaInsets.top
            if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                hasNotch = true
                notchWidth = max(0, screen.frame.width - left.width - right.width)
                height = inset
                width = notchWidth + 2 * Self.wing
                frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
            } else {
                hasNotch = false
                notchWidth = 0
                height = 34
                width = 300
                frame = CGRect(x: screen.frame.midX - width / 2, y: screen.visibleFrame.maxY - height - 8, width: width, height: height)
            }
        }
    }

    final class Model: ObservableObject {
        @Published var message = Message(icon: .check, title: "", detail: nil, tint: .success)
        @Published var geometry = Geometry(screen: NSScreen.main ?? NSScreen.screens[0])
        @Published var expanded = false
    }

    private let model = Model()
    private var panel: NotchPanel?
    private var hideTask: Task<Void, Never>?

    func show(icon: Codicon, title: String, detail: String? = nil, tint: Tint = .success, seconds: TimeInterval = 2.4) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), let screen = NSScreen.main else { return }
        #if DEBUG
        let seconds = ProcessInfo.processInfo.environment["SATCHEL_HUD_SECONDS"].flatMap(Double.init) ?? seconds // UI testing only
        #endif
        let geometry = Geometry(screen: screen)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.geometry = geometry
        model.message = Message(icon: icon, title: title, detail: detail, tint: tint)
        panel.setFrame(geometry.frame, display: false)
        panel.orderFrontRegardless()
        animate { self.model.expanded = true }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.animate { self.model.expanded = false }
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { self.panel?.orderOut(nil) }
        }
    }

    private func animate(_ change: @escaping () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.easeInOut(duration: 0.12), change)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78), change)
        }
    }

    private func makePanel() -> NotchPanel {
        let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        AppSettings.applyCapturePolicy(to: p)
        let host = NSHostingView(rootView: NotchHUDView(model: model))
        host.layer?.backgroundColor = .clear
        p.contentView = host
        return p
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// AppKit would push the window below the menu bar; the HUD belongs in that strip.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct NotchHUDView: View {
    @ObservedObject var model: NotchHUD.Model

    var body: some View {
        let g = model.geometry
        let m = model.message
        ZStack(alignment: .top) {
            if g.hasNotch { notchBody(g, m) } else { pillBody(g, m) }
        }
        .frame(width: g.width, height: g.height, alignment: .top)
    }

    private func tint(_ t: NotchHUD.Tint) -> Color {
        switch t {
        case .success: return Color(red: 0.30, green: 0.85, blue: 0.45)
        case .neutral: return .white
        case .warning: return .orange
        }
    }

    /// Black wings left and right of the physical notch. Closed, the shape is exactly as wide as the
    /// notch, so it disappears into it.
    private func notchBody(_ g: NotchHUD.Geometry, _ m: NotchHUD.Message) -> some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16)
                .fill(Color.black)
                .frame(width: model.expanded ? g.width : g.notchWidth, height: g.height)
            HStack(spacing: 0) {
                Icon(m.icon, size: 14).foregroundStyle(tint(m.tint))
                    .frame(width: NotchHUD.Geometry.wing, alignment: .center)
                Color.clear.frame(width: g.notchWidth)
                HStack(spacing: 5) {
                    Text(m.title).font(.system(size: 12, weight: .semibold))
                    if let d = m.detail { Text(d).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: NotchHUD.Geometry.wing, alignment: .center)
            }
            .frame(height: g.height)
            .opacity(model.expanded ? 1 : 0)
            .animation(.easeOut(duration: 0.18).delay(model.expanded ? 0.12 : 0), value: model.expanded)
        }
    }

    private func pillBody(_ g: NotchHUD.Geometry, _ m: NotchHUD.Message) -> some View {
        HStack(spacing: Theme.Space.s) {
            Icon(m.icon, size: 13).foregroundStyle(tint(m.tint))
            Text(m.title).font(.system(size: 12, weight: .semibold))
            if let d = m.detail { Text(d).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, Theme.Space.l)
        .frame(height: g.height)
        .background(Color.black, in: Capsule())
        .scaleEffect(model.expanded ? 1 : 0.6, anchor: .top)
        .opacity(model.expanded ? 1 : 0)
        .frame(maxWidth: .infinity)
    }
}
