import SwiftUI
import VaultCore

/// Design tokens. One spacing scale, five type sizes, semantic colors, one accent per type.
enum Theme {
    // Spacing grid (4-pt base). Use only these.
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
        static let xl: CGFloat = 24, xxl: CGFloat = 32
    }

    // Type scale: hero (light) → title → body → caption → label.
    static let hero = Font.system(size: 28, weight: .light).monospacedDigit()
    static let title = Font.system(size: 20, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    /// Uppercase section labels; the only tracked text in the app.
    static let label = Font.system(size: 11, weight: .medium)
    static let labelTracking: CGFloat = 0.8

    // Kept for existing call sites.
    static let numeral = hero

    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// What the blocks sit on: the window colour, a touch deeper (lighter in dark mode), so the
    /// rounded blocks read as separate pieces.
    static var stage: some View { Color(nsColor: .windowBackgroundColor).overlay(Color.primary.opacity(0.045)) }
    static let blockRadius: CGFloat = 18
    static let blockGap: CGFloat = 8
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor).opacity(0.6)
    static let hover = Color.primary.opacity(0.05)
    static let radius: CGFloat = 12
    static let rowRadius: CGFloat = 8

    static func accent(_ type: ItemType) -> Color {
        switch type {
        case .login: return Color(red: 0.20, green: 0.47, blue: 0.96)
        case .apiKey: return Color(red: 0.96, green: 0.56, blue: 0.14)
        case .dbCredential: return Color(red: 0.20, green: 0.68, blue: 0.38)
        case .webhook: return Color(red: 0.58, green: 0.38, blue: 0.90)
        case .secureNote: return Color(red: 0.52, green: 0.54, blue: 0.60)
        case .sshKey: return Color(red: 0.12, green: 0.62, blue: 0.68)
        case .category: return Color(red: 0.52, green: 0.54, blue: 0.60)
        }
    }

    static func icon(_ type: ItemType) -> Codicon {
        switch type {
        case .login: return .account
        case .apiKey: return .key
        case .dbCredential: return .database
        case .webhook: return .link
        case .secureNote: return .note
        case .sshKey: return .terminal
        case .category: return .folder
        }
    }

    static func label(_ field: String) -> String {
        switch field {
        case "password": return "Password"
        case "apiKey": return "API key"
        case "totpSeed": return "Authenticator key"
        case "connectionString": return "Connection string"
        case "privateKey": return "Private key"
        case "publicKey": return "Public key"
        default: return field.prefix(1).uppercased() + field.dropFirst()
        }
    }
}

/// Uppercase section label ("BY TYPE").
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label).tracking(Theme.labelTracking)
            .foregroundStyle(.secondary)
    }
}

/// Card surface. Interactive cards lift on hover with an accent border.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    var accent: Color? = nil
    var interactive = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        let lifted = interactive && hovering
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(lifted ? (accent ?? .accentColor).opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(lifted ? 0.10 : 0.03), radius: lifted ? 12 : 2, y: lifted ? 4 : 1)
            .scaleEffect(lifted ? 1.01 : 1)
            .animation(.easeOut(duration: 0.15), value: lifted)
            .onHover { hovering = $0 }
            .pointerStyle(interactive ? .link : nil)
    }
}

/// Rounded hover highlight for rows that are not system list rows.
struct HoverHighlight: ViewModifier {
    var radius: CGFloat = Theme.rowRadius
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = Theme.rowRadius) -> some View { modifier(HoverHighlight(radius: radius)) }
}

/// Small rounded square with a white symbol, like Pulse's sidebar icons.
struct IconTile: View {
    let type: ItemType
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.accent(type).gradient)
            .frame(width: size, height: size)
            .overlay(Icon(Theme.icon(type), size: (size * 0.58).rounded()).foregroundStyle(.white))
    }
}

/// Pulse's LED sparkline: a grid of dots, columns lit from the bottom by value.
/// Drawn in one Canvas pass (cheap even with many columns).
struct DotMatrix: View {
    let values: [Int]
    let color: Color
    var rows = 4
    var dot: CGFloat = 4
    var gap: CGFloat = 3

    var body: some View {
        let maxV = max(values.max() ?? 1, 1)
        Canvas { ctx, size in
            let columns = values.count
            let step = columns > 1 ? (size.width - dot) / CGFloat(columns - 1) : 0
            for (c, v) in values.enumerated() {
                let lit = v == 0 ? 0 : max(1, Int((Double(v) / Double(maxV) * Double(rows)).rounded(.up)))
                for r in 0..<rows {
                    let on = r >= rows - lit
                    let rect = CGRect(x: CGFloat(c) * step, y: CGFloat(r) * (dot + gap), width: dot, height: dot)
                    ctx.fill(Circle().path(in: rect), with: .color(on ? color : color.opacity(0.15)))
                }
            }
        }
        .frame(height: CGFloat(rows) * (dot + gap) - gap)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// A solid rounded block on the stage: one piece of the window, separate from the others, like
    /// the menu column.
    func block() -> some View {
        self.background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.blockRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.blockRadius, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 1)
    }

    /// Applies the screen-capture policy (hidden from screenshots unless allowed in Settings).
    func excludedFromCapture() -> some View {
        background(WindowAccessor { window in
            AppSettings.applyCapturePolicy(to: window)
        })
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { configure(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let w = nsView.window { configure(w) }
    }
}
