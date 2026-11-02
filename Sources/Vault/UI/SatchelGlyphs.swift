import SwiftUI

/// Satchel's own icons, drawn for what each menu entry is, not picked from a stock set: a dashboard of
/// tiles, a fan of cards, a key, a stack of database slabs, a hook of three nodes, a note with a padlock.
/// Each is one pure function of its motion progress `p` in 0...1 (0 and 1 are the same resting picture), so a
/// part can move on its own: tiles pop in turn, the key flips, the slabs hop, the lines rewrite themselves.
/// Drawn in the foreground colour of the view, on a unit square.
enum SatchelGlyph: String, CaseIterable {
    case overview, allItems, favorites, recent, login, apiKey, database, webhook, note, sshKey, lock, shield, server

    static let prefix = "satchel."
    var name: String { Self.prefix + rawValue }

    init?(name: String) {
        guard name.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: String(name.dropFirst(Self.prefix.count)))
    }

    /// Seconds one motion takes.
    static let duration = 0.9
}

// MARK: - Drawing helpers

private func bump(_ t: Double) -> Double { sin(.pi * min(max(t, 0), 1)) }                  // 0 → 1 → 0
private func ease(_ t: Double) -> Double { let x = min(max(t, 0), 1); return x * x * (3 - 2 * x) } // 0 → 1
private func seg(_ p: Double, _ a: Double, _ b: Double) -> Double { min(max((p - a) / (b - a), 0), 1) } // p's slice a…b as 0…1
private func blink(_ p: Double) -> Double { 0.25 + 0.75 * abs(cos(2 * .pi * 1.5 * p)) }    // 1 at both ends

private struct Pen {
    let ctx: GraphicsContext
    let s: CGFloat
    var lw: CGFloat { s * 0.1 }

    func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, r: Double) -> Path {
        Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: r * s, style: .continuous)
    }
    func dot(_ x: Double, _ y: Double, r: Double) -> Path {
        Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s))
    }
    func line(_ points: [(Double, Double)]) -> Path {
        var path = Path()
        for (i, q) in points.enumerated() { i == 0 ? path.move(to: pt(q.0, q.1)) : path.addLine(to: pt(q.0, q.1)) }
        return path
    }
    func stroke(_ path: Path, alpha: Double = 1, width: CGFloat? = nil) {
        var c = ctx
        c.opacity = alpha
        c.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: width ?? lw, lineCap: .round, lineJoin: .round))
    }
    func fill(_ path: Path, alpha: Double = 1) {
        var c = ctx
        c.opacity = alpha
        c.fill(path, with: .foreground)
    }
    /// Draws `body` moved, turned (degrees) and scaled about `pivot`.
    func moved(about pivot: (Double, Double), dx: Double = 0, dy: Double = 0, rotate: Double = 0, sx: Double = 1, sy: Double = 1,
               _ body: (Pen) -> Void) {
        var c = ctx
        c.translateBy(x: (pivot.0 + dx) * s, y: (pivot.1 + dy) * s)
        c.rotate(by: .degrees(rotate))
        c.scaleBy(x: sx, y: sy)
        c.translateBy(x: -pivot.0 * s, y: -pivot.1 * s)
        body(Pen(ctx: c, s: s))
    }
}

extension SatchelGlyph {
    /// Draws the glyph in a square of side `side` at progress `p`.
    func draw(_ ctx: GraphicsContext, side: CGFloat, p: Double) {
        let g = Pen(ctx: ctx, s: side)
        switch self {
        case .overview:
            // A dashboard of four tiles; each pops in turn.
            let cells: [(Double, Double, Double, Double, Double)] = [
                (0.04, 0.04, 0.42, 0.54, 1), (0.54, 0.04, 0.42, 0.30, 0.7), (0.04, 0.66, 0.42, 0.30, 0.7), (0.54, 0.42, 0.42, 0.54, 1),
            ]
            for (i, c) in cells.enumerated() {
                let t = bump(seg(p, Double(i) * 0.14, Double(i) * 0.14 + 0.5))
                g.moved(about: (c.0 + c.2 / 2, c.1 + c.3 / 2), sx: 1 + 0.2 * t, sy: 1 + 0.2 * t) {
                    $0.fill($0.rect(c.0, c.1, c.2, c.3, r: 0.1), alpha: c.4)
                }
            }
        case .allItems:
            // Three cards, each narrower than the one in front like a stack seen from above; the front ones
            // fan out and settle back.
            let cards: [(y: Double, x: Double, alpha: Double, turn: Double)] = [(0.52, 0.24, 0.45, 0), (0.36, 0.15, 0.72, 5), (0.16, 0.06, 1, -9)]
            for (i, c) in cards.enumerated() {
                let t = bump(seg(p, Double(2 - i) * 0.1, Double(2 - i) * 0.1 + 0.6))
                g.moved(about: (0.1, 0.92), dy: -0.05 * t * Double(i), rotate: c.turn * t) {
                    $0.fill($0.rect(c.x, c.y, 1 - 2 * c.x, 0.34, r: 0.09), alpha: c.alpha)
                }
            }
        case .favorites:
            // A star that pops and turns one fifth of a turn (it looks the same), with sparkles.
            let t = bump(p)
            g.moved(about: (0.5, 0.54), rotate: 72 * ease(p), sx: 1 + 0.22 * t, sy: 1 + 0.22 * t) { $0.fill(star($0)) }
            let sp = bump(seg(p, 0.15, 0.85))
            sparkle(g, x: 0.88, y: 0.14, r: 0.1 + 0.07 * sp, alpha: 0.5 + 0.5 * sp)
            sparkle(g, x: 0.1, y: 0.2, r: 0.07 + 0.06 * sp, alpha: 0.5 + 0.5 * sp)
        case .recent:
            // A clock whose minute hand winds back once around.
            g.stroke(g.dot(0.5, 0.5, r: 0.42))
            g.stroke(g.line([(0.5, 0.5), (0.5, 0.26)]))
            g.moved(about: (0.5, 0.5), rotate: -360 * ease(p)) { $0.stroke($0.line([(0.5, 0.5), (0.76, 0.5)])) }
            g.fill(g.dot(0.5, 0.5, r: 0.06))
        case .login:
            // An arrow goes through the door frame.
            g.stroke(g.line([(0.6, 0.12), (0.88, 0.12), (0.88, 0.88), (0.6, 0.88)]))
            g.moved(about: (0.4, 0.5), dx: 0.14 * bump(p)) {
                $0.stroke($0.line([(0.08, 0.5), (0.62, 0.5)]))
                $0.stroke($0.line([(0.44, 0.28), (0.66, 0.5), (0.44, 0.72)]))
            }
        case .apiKey:
            // A key that flips about its own shaft, like turning in a lock.
            g.moved(about: (0.5, 0.5), sy: cos(2 * .pi * ease(p))) {
                $0.stroke($0.dot(0.27, 0.5, r: 0.2))
                $0.fill($0.dot(0.27, 0.5, r: 0.06))
                $0.stroke($0.line([(0.47, 0.5), (0.92, 0.5)]))
                $0.stroke($0.line([(0.72, 0.5), (0.72, 0.7)]))
                $0.stroke($0.line([(0.86, 0.5), (0.86, 0.65)]))
            }
        case .database:
            // Three slabs with a status light each; they hop one after the other, bottom to top.
            for (k, y) in [0.68, 0.41, 0.14].enumerated() {
                let t = bump(seg(p, Double(k) * 0.16, Double(k) * 0.16 + 0.55))
                g.moved(about: (0.5, y), dy: -0.09 * t) {
                    $0.stroke($0.rect(0.08, y, 0.84, 0.2, r: 0.1), width: $0.lw * 0.9)
                    $0.fill($0.dot(0.24, y + 0.1, r: 0.045))
                    $0.stroke($0.line([(0.42, y + 0.1), (0.74, y + 0.1)]), alpha: 0.7, width: $0.lw * 0.7)
                }
            }
        case .webhook:
            // Three nodes joined by a hook; a pulse runs through them.
            let nodes: [(Double, Double)] = [(0.5, 0.2), (0.17, 0.76), (0.83, 0.76)]
            g.stroke(g.line([nodes[0], nodes[1], nodes[2], nodes[0]]), alpha: 0.85, width: g.lw * 0.8)
            for (i, n) in nodes.enumerated() {
                let t = bump(seg(p, Double(i) * 0.2, Double(i) * 0.2 + 0.45))
                g.moved(about: n, sx: 1 + 0.4 * t, sy: 1 + 0.4 * t) { $0.fill($0.dot(n.0, n.1, r: 0.13)) }
            }
        case .note:
            // A note whose lines rewrite themselves, and a padlock whose shackle lifts.
            g.stroke(Path { path in
                path.move(to: g.pt(0.12, 0.06)); path.addLine(to: g.pt(0.54, 0.06)); path.addLine(to: g.pt(0.74, 0.26))
                path.addLine(to: g.pt(0.74, 0.94)); path.addLine(to: g.pt(0.12, 0.94)); path.closeSubpath()
            })
            g.stroke(g.line([(0.54, 0.06), (0.54, 0.26), (0.74, 0.26)]), alpha: 0.8, width: g.lw * 0.8)
            for (i, y) in [0.44, 0.62, 0.8].enumerated() {
                let trim = 1 - 0.85 * bump(seg(p, Double(i) * 0.18, Double(i) * 0.18 + 0.6))
                g.stroke(g.line([(0.24, y), (i == 0 ? 0.6 : 0.46, y)]).trimmedPath(from: 0, to: trim), alpha: 0.9, width: g.lw * 0.8)
            }
            g.moved(about: (0.72, 0.66), dy: -0.07 * bump(seg(p, 0.3, 0.9))) { $0.stroke(shackle($0, x0: 0.6, x1: 0.84, top: 0.46, base: 0.66), width: $0.lw * 0.9) }
            g.fill(g.rect(0.5, 0.64, 0.44, 0.32, r: 0.08))
        case .sshKey:
            // A terminal: the prompt nudges forward, the cursor blinks.
            g.stroke(g.rect(0.05, 0.14, 0.9, 0.72, r: 0.14))
            g.moved(about: (0.3, 0.5), dx: 0.05 * bump(p)) { $0.stroke($0.line([(0.24, 0.35), (0.4, 0.5), (0.24, 0.65)])) }
            g.stroke(g.line([(0.5, 0.67), (0.74, 0.67)]), alpha: blink(p))
        case .lock:
            // A padlock that opens and closes.
            let t = bump(p)
            g.moved(about: (0.7, 0.46), dy: -0.12 * t, rotate: 18 * t) { $0.stroke(shackle($0, x0: 0.3, x1: 0.7, top: 0.1, base: 0.46)) }
            g.fill(g.rect(0.16, 0.44, 0.68, 0.5, r: 0.12))
        case .shield:
            // A shield that pops while its check mark draws itself again.
            let t = bump(p)
            g.moved(about: (0.5, 0.5), sx: 1 + 0.12 * t, sy: 1 + 0.12 * t) { pen in
                pen.stroke(Path { path in
                    path.move(to: pen.pt(0.5, 0.06)); path.addLine(to: pen.pt(0.86, 0.2)); path.addLine(to: pen.pt(0.86, 0.5))
                    path.addQuadCurve(to: pen.pt(0.5, 0.94), control: pen.pt(0.86, 0.8))
                    path.addQuadCurve(to: pen.pt(0.14, 0.5), control: pen.pt(0.14, 0.8))
                    path.addLine(to: pen.pt(0.14, 0.2)); path.closeSubpath()
                })
            }
            g.stroke(g.line([(0.32, 0.5), (0.45, 0.64), (0.69, 0.36)]).trimmedPath(from: 0, to: 1 - 0.9 * bump(seg(p, 0.1, 0.9))))
        case .server:
            // Two racks whose lights blink.
            for y in [0.1, 0.58] {
                g.stroke(g.rect(0.08, y, 0.84, 0.32, r: 0.1))
                g.fill(g.dot(0.25, y + 0.16, r: 0.05), alpha: blink(p + y))
                g.stroke(g.line([(0.45, y + 0.16), (0.75, y + 0.16)]), alpha: 0.7, width: g.lw * 0.7)
            }
        }
    }

    private func star(_ g: Pen) -> Path {
        var path = Path()
        for i in 0..<10 {
            let angle = -Double.pi / 2 + Double(i) * .pi / 5
            let r = i % 2 == 0 ? 0.48 : 0.21
            let q = g.pt(0.5 + r * cos(angle), 0.54 + r * sin(angle))
            i == 0 ? path.move(to: q) : path.addLine(to: q)
        }
        path.closeSubpath()
        return path
    }

    private func sparkle(_ g: Pen, x: Double, y: Double, r: Double, alpha: Double) {
        var path = Path()
        let k = r * 0.3
        path.move(to: g.pt(x, y - r)); path.addQuadCurve(to: g.pt(x + r, y), control: g.pt(x + k, y - k))
        path.addQuadCurve(to: g.pt(x, y + r), control: g.pt(x + k, y + k)); path.addQuadCurve(to: g.pt(x - r, y), control: g.pt(x - k, y + k))
        path.addQuadCurve(to: g.pt(x, y - r), control: g.pt(x - k, y - k))
        g.fill(path, alpha: alpha)
    }

    private func shackle(_ g: Pen, x0: Double, x1: Double, top: Double, base: Double) -> Path {
        Path { path in
            path.move(to: g.pt(x0, base)); path.addLine(to: g.pt(x0, (top + base) / 2))
            path.addCurve(to: g.pt(x1, (top + base) / 2), control1: g.pt(x0, top - 0.12), control2: g.pt(x1, top - 0.12))
            path.addLine(to: g.pt(x1, base))
        }
    }
}

/// A glyph at rest, or at a given point of its motion.
struct SatchelGlyphView: View {
    let glyph: SatchelGlyph
    var size: CGFloat
    var progress = 0.0

    var body: some View {
        Canvas { context, canvas in glyph.draw(context, side: min(canvas.width, canvas.height), p: progress) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
