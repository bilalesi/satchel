import SwiftUI
import VaultCore

/// Pulse-inspired tokens: grey canvas, white cards with a hairline, one accent per type.
enum Theme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
    static let radius: CGFloat = 14
    static let numeral = Font.system(size: 34, weight: .semibold, design: .rounded)

    static func accent(_ type: ItemType) -> Color {
        switch type {
        case .login: return Color(red: 0.20, green: 0.47, blue: 0.96)
        case .apiKey: return Color(red: 0.98, green: 0.58, blue: 0.16)
        case .dbCredential: return Color(red: 0.22, green: 0.72, blue: 0.40)
        case .webhook: return Color(red: 0.60, green: 0.40, blue: 0.92)
        case .secureNote: return Color(red: 0.55, green: 0.57, blue: 0.62)
        case .sshKey: return Color(red: 0.16, green: 0.66, blue: 0.70)
        }
    }

    static func symbol(_ type: ItemType) -> String {
        switch type {
        case .login: return "person.crop.circle"
        case .apiKey: return "key"
        case .dbCredential: return "cylinder.split.1x2"
        case .webhook: return "link"
        case .secureNote: return "note.text"
        case .sshKey: return "terminal"
        }
    }

    static func label(_ field: String) -> String {
        switch field {
        case "password": return "Password"
        case "apiKey": return "API key"
        case "totpSeed": return "One-time code seed"
        case "connectionString": return "Connection string"
        case "privateKey": return "Private key"
        case "publicKey": return "Public key"
        default: return field.prefix(1).uppercased() + field.dropFirst()
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Small rounded square with a white symbol, like Pulse's sidebar icons.
struct IconTile: View {
    let type: ItemType
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.accent(type))
            .frame(width: size, height: size)
            .overlay(Image(systemName: Theme.symbol(type))
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white))
    }
}

/// Pulse's LED sparkline: a grid of dots, columns lit from the bottom by value.
struct DotMatrix: View {
    let values: [Int]
    let color: Color
    var rows = 5
    var dot: CGFloat = 5
    var gap: CGFloat = 3

    var body: some View {
        let maxV = max(values.max() ?? 1, 1)
        Canvas { ctx, _ in
            for (c, v) in values.enumerated() {
                let lit = v == 0 ? 0 : max(1, Int((Double(v) / Double(maxV) * Double(rows)).rounded(.up)))
                for r in 0..<rows {
                    let on = r >= rows - lit
                    let rect = CGRect(x: CGFloat(c) * (dot + gap), y: CGFloat(r) * (dot + gap), width: dot, height: dot)
                    ctx.fill(Circle().path(in: rect), with: .color(on ? color : color.opacity(0.14)))
                }
            }
        }
        .frame(width: CGFloat(values.count) * (dot + gap) - gap, height: CGFloat(rows) * (dot + gap) - gap)
    }
}

extension View {
    /// Keeps a window out of screenshots and screen sharing.
    func excludedFromCapture() -> some View {
        background(WindowAccessor { window in
            window.sharingType = .none
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
