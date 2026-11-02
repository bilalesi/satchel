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

/// How much of a tile its glyph fills: the drawn glyphs use nearly all of it, stock glyphs need air around them.
func glyphSize(inTile size: CGFloat, iconName: String) -> CGFloat {
    SatchelGlyph(name: iconName) != nil ? (size * 0.74).rounded() : (size * 0.54).rounded()
}

/// An icon that plays its motion whenever `iconPulse` changes: a drawn glyph its own (parts moving on their
/// own), a stock glyph the one `IconMotion` picks for it. The clock only runs while a motion plays: at rest
/// the view is static and costs nothing. With Reduce Motion it never moves.
struct MotionGlyph: View {
    let iconName: String
    var size: CGFloat = 14
    @Environment(\.iconPulse) private var pulse
    @State private var start: Date?

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            let elapsed = start.map { context.date.timeIntervalSince($0) }
            if let glyph = SatchelGlyph(name: iconName) {
                SatchelGlyphView(glyph: glyph, size: size, progress: min(1, (elapsed ?? 0) / SatchelGlyph.duration))
            } else {
                stock(elapsed: elapsed)
            }
        }
        .onChange(of: pulse) { _, _ in play() }
    }

    private func stock(elapsed: Double?) -> some View {
        let motion = IconMotion.forIcon(iconName)
        let reach = size / 9 * 0.5 // shifts are authored for a 9-pt glyph; this keeps them inside a tile of any size
        let pose = elapsed.map { motion.pose(at: $0 / IconMotion.duration) } ?? .rest
        return Icon(CategoryStyle.icon(named: iconName), size: size)
            .scaleEffect(x: pose.sx, y: pose.sy)
            .rotationEffect(.degrees(pose.rotation))
            .offset(x: pose.dx * reach, y: pose.dy * reach)
            .opacity(pose.opacity)
    }

    private func play() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let started = Date()
        let seconds = SatchelGlyph(name: iconName) != nil ? SatchelGlyph.duration : IconMotion.duration
        start = started
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if start == started { start = nil }
        }
    }
}

/// A rounded colour tile with a white glyph that plays the glyph's motion.
struct MotionTile: View {
    let iconName: String
    let colorName: String
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(CategoryStyle.color(named: colorName).gradient)
            .frame(width: size, height: size)
            .overlay(MotionGlyph(iconName: iconName, size: glyphSize(inTile: size, iconName: iconName)).foregroundStyle(.white))
    }
}
