import AppKit
import SwiftUI

/// A short announcement that hangs from the top edge of the screen with the app's logo, a title and
/// one line of description: a workspace switch, a manual sync that ended, a new or installed update.
/// On a Mac with a notch the black shape grows out of the notch and merges with it; on other Macs it
/// is the same card hanging under the top edge. It never takes focus and ignores the mouse.
@MainActor
final class NotchHUD {
    static let shared = NotchHUD()

    struct Message: Equatable {
        var title: String
        var detail: String
    }

    /// Where the card sits on one screen. `notchWidth`/`notchHeight` are the hardware cut-out (0 without one).
    struct Geometry: Equatable {
        static let width: CGFloat = 360
        static let body: CGFloat = 64
        var notchWidth: CGFloat
        var notchHeight: CGFloat
        var frame: CGRect
        var height: CGFloat { notchHeight + Self.body }

        init(screen: NSScreen) {
            let inset = screen.safeAreaInsets.top
            if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notchWidth = max(0, screen.frame.width - left.width - right.width)
                notchHeight = inset
            } else {
                notchWidth = 0
                notchHeight = 0
            }
            let h = notchHeight + Self.body
            // Without a notch the card hangs just under the menu bar, not from the physical edge.
            let top = notchHeight > 0 ? screen.frame.maxY : screen.visibleFrame.maxY - 6
            frame = CGRect(x: screen.frame.midX - Self.width / 2, y: top - h, width: Self.width, height: h)
        }
    }

    final class Model: ObservableObject {
        @Published var message = Message(title: "", detail: "")
        @Published var geometry = Geometry(screen: NSScreen.main ?? NSScreen.screens[0])
        @Published var expanded = false
    }

    private let model = Model()
    private var panel: NotchPanel?
    private var hideTask: Task<Void, Never>?

    func show(title: String, detail: String, seconds: TimeInterval = 3.2) {
        guard let screen = NSScreen.main else { return }
        #if DEBUG
        let seconds = ProcessInfo.processInfo.environment["SATCHEL_HUD_SECONDS"].flatMap(Double.init) ?? seconds // UI testing only
        #endif
        let geometry = Geometry(screen: screen)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.geometry = geometry
        model.message = Message(title: title, detail: detail)
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
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8), change)
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
    /// AppKit would push the window below the menu bar; the card belongs in that strip.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct NotchHUDView: View {
    @ObservedObject var model: NotchHUD.Model

    var body: some View {
        let g = model.geometry
        let hasNotch = g.notchHeight > 0
        // Closed, the shape is exactly the notch, so it disappears into it.
        let closedWidth = hasNotch ? g.notchWidth : 96
        let closedHeight = hasNotch ? g.notchHeight : 8
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: hasNotch ? 0 : 22, bottomLeadingRadius: 24,
                                   bottomTrailingRadius: 24, topTrailingRadius: hasNotch ? 0 : 22)
                .fill(Color.black)
                .frame(width: model.expanded ? NotchHUD.Geometry.width : closedWidth,
                       height: model.expanded ? g.height : closedHeight)
            HStack(spacing: Theme.Space.m) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.message.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(model.message.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.l + 4)
            .frame(width: NotchHUD.Geometry.width, height: NotchHUD.Geometry.body)
            .padding(.top, g.notchHeight)
            .opacity(model.expanded ? 1 : 0)
            .animation(.easeOut(duration: 0.2).delay(model.expanded ? 0.15 : 0), value: model.expanded)
        }
        .frame(width: NotchHUD.Geometry.width, height: g.height, alignment: .top)
    }
}
