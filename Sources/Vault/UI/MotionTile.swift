import SwiftUI
import VaultCore

private struct IconPulseKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    /// A counter a row bumps when its icon should play its motion (the pointer arrives, the row is selected).
    var iconPulse: Int {
        get { self[IconPulseKey.self] }
        set { self[IconPulseKey.self] = newValue }
    }
}

/// An icon that plays its motion (`IconMotion`) whenever `iconPulse` changes. The clock only runs while a
/// motion plays: at rest the view is static and costs nothing. With Reduce Motion it never moves.
struct MotionGlyph: View {
    let iconName: String
    var size: CGFloat = 14
    @Environment(\.iconPulse) private var pulse
    @State private var start: Date?

    var body: some View {
        let motion = IconMotion.forIcon(iconName)
        let reach = size / 9 * 0.5 // shifts are authored for an 18-pt tile (9-pt glyph); this keeps them inside a tile of any size
        TimelineView(.animation(paused: start == nil)) { context in
            let pose = start.map { motion.pose(at: context.date.timeIntervalSince($0) / IconMotion.duration) } ?? .rest
            Icon(CategoryStyle.icon(named: iconName), size: size)
                .scaleEffect(x: pose.sx, y: pose.sy)
                .rotationEffect(.degrees(pose.rotation))
                .offset(x: pose.dx * reach, y: pose.dy * reach)
                .opacity(pose.opacity)
        }
        .onChange(of: pulse) { _, _ in play() }
    }

    private func play() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let started = Date()
        start = started
        Task {
            try? await Task.sleep(for: .seconds(IconMotion.duration))
            if start == started { start = nil }
        }
    }
}

/// A rounded colour tile with a white glyph that plays the glyph's motion.
struct MotionTile: View {
    let iconName: String
    let colorName: String
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(CategoryStyle.color(named: colorName).gradient)
            .frame(width: size, height: size)
            .overlay(MotionGlyph(iconName: iconName, size: (size * 0.52).rounded()).foregroundStyle(.white))
    }
}
