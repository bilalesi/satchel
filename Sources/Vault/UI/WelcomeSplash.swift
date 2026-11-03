import AppKit
import SwiftUI

/// The first-run welcome: the Satchel logo wakes up, its clasp clicks, and the camera pushes
/// through the keyhole into the app. The window underneath is revealed *through* the keyhole as it
/// grows, so the app is not shown after the logo, you arrive in it.
///
/// Everything is drawn as vectors in one Canvas from the same geometry as the app icon
/// (scripts/make-icon.swift), so it stays sharp at any zoom, and every value is a pure function of
/// time: the same code draws the live animation and the preview frames.
enum SplashTiming {
    static let duration: Double = 3.5
    static let pushStart = 1.7
    static let pushEnd = 3.3
}

struct WelcomeSplash: View {
    let start: Date
    let onFinish: () -> Void

    var body: some View {
        TimelineView(.animation) { context in
            SplashFrame(time: context.date.timeIntervalSince(start))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFinish) // any click skips
        .onExitCommand(perform: onFinish)
        .task {
            try? await Task.sleep(for: .seconds(1.12)) // the clasp click
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            try? await Task.sleep(for: .seconds(SplashTiming.duration - 1.12))
            onFinish()
        }
        .accessibilityLabel("Welcome to Satchel. Click to skip.")
    }
}

struct SplashFrame: View {
    let time: Double
    var body: some View {
        Canvas { context, size in SplashArt.draw(&context, size: size, t: time) }
            .allowsHitTesting(false)
    }
}

enum SplashArt {
    // MARK: Palette (same values as the icon)

    private static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, opacity: a)
    }

    private static let leatherTop = hex(0xF7C27A), leatherBottom = hex(0xD9822C)
    private static let flapTop = hex(0xE9993F), flapBottom = hex(0xB5601B)
    private static let handleColor = hex(0x8E4812), handleHighlight = hex(0xB8681F)
    private static let claspTop = hex(0xFFF6E6), claspBottom = hex(0xEBD3AC)
    private static let keyholeColor = hex(0x3A220F), stitchColor = hex(0xFFF1DA, 0.9)
    private static let ink = hex(0x140D07), inkGlow = hex(0x32231A), cream = hex(0xF6E7CF)

    // MARK: Geometry (1024 grid, y down, as in the icon)

    private static let handle: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 336, y: 430))
        p.addLine(to: CGPoint(x: 336, y: 330))
        p.addCurve(to: CGPoint(x: 688, y: 330), control1: CGPoint(x: 336, y: 150), control2: CGPoint(x: 688, y: 150))
        p.addLine(to: CGPoint(x: 688, y: 430))
        return p
    }()

    private static let flap: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -40, y: 430))
        p.addLine(to: CGPoint(x: 1064, y: 430))
        p.addLine(to: CGPoint(x: 1064, y: 640))
        p.addCurve(to: CGPoint(x: -40, y: 640), control1: CGPoint(x: 900, y: 860), control2: CGPoint(x: 124, y: 860))
        p.closeSubpath()
        return p
    }()

    private static let stitches: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 70, y: 470))
        p.addLine(to: CGPoint(x: 954, y: 470))
        p.addLine(to: CGPoint(x: 954, y: 630))
        p.addCurve(to: CGPoint(x: 70, y: 630), control1: CGPoint(x: 830, y: 800), control2: CGPoint(x: 194, y: 800))
        p.closeSubpath()
        return p
    }()

    private static let clasp = CGRect(x: 452, y: 690, width: 120, height: 140)
    private static let keyholeCenter = CGPoint(x: 512, y: 747)

    private static let keyhole: Path = {
        var p = Path()
        p.addEllipse(in: CGRect(x: 512 - 19, y: clasp.minY + 38, width: 38, height: 38))
        p.addRoundedRect(in: CGRect(x: 512 - 9, y: clasp.minY + 62, width: 18, height: 46), cornerSize: CGSize(width: 8, height: 8))
        return p
    }()

    /// The icon body (824 of 1024, rounded square) the artwork is clipped to.
    private static let bodyInset: CGFloat = 100
    private static let bodyScale: CGFloat = 824.0 / 1024.0
    private static let body = Path(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerRadius: 185, style: .continuous)

    // MARK: Easing

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func smooth(_ x: Double) -> Double { let c = clamp(x); return c * c * (3 - 2 * c) }
    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    private static func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    // MARK: Drawing

    static func draw(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        let W = size.width, H = size.height
        guard t < SplashTiming.duration else { return }

        // Timeline (seconds): 0–0.8 wake, 1.05–1.6 clasp click, 0.85–1.95 wordmark, 1.7–3.3 push through.
        let appear = easeOut(t / 0.8)
        let push = clamp((t - SplashTiming.pushStart) / (SplashTiming.pushEnd - SplashTiming.pushStart))
        let e = smooth(push)
        let cut = smooth(push / 0.10) // the keyhole turns into an opening
        let wordIn = easeOut((t - 0.85) / 0.6), wordOut = smooth((t - 1.6) / 0.35)

        let logoSize = min(W, H) * 0.36
        let b = logoSize / 1024
        let center = CGPoint(x: W / 2, y: H / 2 - logoSize * 0.07)
        let appearScale = 0.88 + 0.12 * appear

        // Keyhole position in the logo canvas, and where it sits on screen at rest.
        let kCanvas = CGPoint(x: bodyInset + keyholeCenter.x * bodyScale, y: bodyInset + keyholeCenter.y * bodyScale)
        let rest = CGPoint(x: center.x + (kCanvas.x - 512) * b * appearScale, y: center.y + (kCanvas.y - 512) * b * appearScale)
        let kPos = mix(rest, CGPoint(x: W / 2, y: H / 2), e)
        // At the end the keyhole's round part, 38 art units wide, is larger than the window diagonal.
        let zoomMax = hypot(W, H) * 1.25 / (38 * bodyScale * b * appearScale)
        let sx = b * appearScale * exp(log(zoomMax) * e)
        let artScale = sx * bodyScale // art unit → screen points

        // Soft shadows only matter while the logo is small; they fade out as the camera moves in.
        let shadow = 1 - smooth(e / 0.3)

        context.drawLayer { layer in
            // Stage
            layer.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ink))
            layer.fill(Path(CGRect(origin: .zero, size: size)),
                       with: .radialGradient(Gradient(colors: [inkGlow, ink]), center: center, startRadius: 0, endRadius: max(W, H) * 0.65))

            // Logo
            layer.drawLayer { logo in
                logo.opacity = appear
                logo.translateBy(x: kPos.x, y: kPos.y)
                logo.scaleBy(x: sx, y: sx)
                logo.translateBy(x: -kCanvas.x, y: -kCanvas.y)

                if shadow > 0.02 {
                    logo.drawLayer { s in
                        s.addFilter(.shadow(color: .black.opacity(0.55 * shadow), radius: 40 * b * appearScale * 1024 / 300, x: 0, y: 22 * b * appearScale * 1024 / 300))
                        s.fill(body, with: .color(leatherBottom))
                    }
                }

                logo.drawLayer { art in
                    art.clip(to: body)
                    art.translateBy(x: bodyInset, y: bodyInset)
                    art.scaleBy(x: bodyScale, y: bodyScale)

                    // Leather
                    let canvasRect = Path(CGRect(x: -40, y: -40, width: 1104, height: 1104))
                    art.fill(canvasRect, with: .linearGradient(Gradient(colors: [leatherTop, leatherBottom]),
                                                               startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 1024)))
                    art.fill(Path(CGRect(x: -40, y: 0, width: 1104, height: 420)),
                             with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0)]),
                                                   startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 420)))

                    // Handle: lifts once while the logo wakes, then settles.
                    let lift = 30 * sin(.pi * clamp((t - 0.25) / 0.75))
                    var h = art
                    h.translateBy(x: 0, y: -lift)
                    if shadow > 0.02 {
                        h.drawLayer { s in
                            s.addFilter(.shadow(color: hex(0x4A2308, 0.45 * shadow), radius: 14 * artScale, x: 0, y: 8 * artScale))
                            s.stroke(handle, with: .color(handleColor), style: StrokeStyle(lineWidth: 72, lineCap: .round, lineJoin: .round))
                        }
                    } else {
                        h.stroke(handle, with: .color(handleColor), style: StrokeStyle(lineWidth: 72, lineCap: .round, lineJoin: .round))
                    }
                    h.translateBy(x: 0, y: -14)
                    h.stroke(handle, with: .color(handleHighlight), style: StrokeStyle(lineWidth: 20, lineCap: .round))

                    // Flap
                    if shadow > 0.02 {
                        art.drawLayer { s in
                            s.addFilter(.shadow(color: hex(0x4A2308, 0.5 * shadow), radius: 26 * artScale, x: 0, y: 14 * artScale))
                            s.fill(flap, with: .color(flapBottom))
                        }
                    }
                    art.fill(flap, with: .linearGradient(Gradient(colors: [flapTop, flapBottom]),
                                                         startPoint: CGPoint(x: 0, y: 430), endPoint: CGPoint(x: 0, y: 800)))
                    art.stroke(stitches, with: .color(stitchColor), style: StrokeStyle(lineWidth: 9, lineCap: .round, dash: [20, 22]))

                    // Clasp: clicks shut with a small overshoot.
                    let click = clamp((t - 1.05) / 0.5)
                    let pulse = 1 - 0.08 * sin(.pi * min(1, click * 1.6)) * (1 - click) + 0.04 * sin(.pi * 2 * click) * (1 - click)
                    var c = art
                    c.translateBy(x: clasp.midX, y: clasp.midY)
                    c.scaleBy(x: pulse, y: pulse)
                    c.translateBy(x: -clasp.midX, y: -clasp.midY)
                    let claspPath = Path(roundedRect: clasp, cornerRadius: 28, style: .continuous)
                    if shadow > 0.02 {
                        c.drawLayer { s in
                            s.addFilter(.shadow(color: hex(0x3A1C05, 0.45 * shadow), radius: 14 * artScale, x: 0, y: 8 * artScale))
                            s.fill(claspPath, with: .color(claspBottom))
                        }
                    }
                    c.fill(claspPath, with: .linearGradient(Gradient(colors: [claspTop, claspBottom]),
                                                            startPoint: CGPoint(x: 0, y: clasp.minY), endPoint: CGPoint(x: 0, y: clasp.maxY)))
                    c.fill(keyhole, with: .color(keyholeColor.opacity(1 - cut)))
                }
            }

            // Punch the keyhole out of everything drawn so far: what shows through is the app.
            if cut > 0.01 {
                var punch = layer
                punch.blendMode = .destinationOut
                punch.translateBy(x: kPos.x, y: kPos.y)
                punch.scaleBy(x: sx, y: sx)
                punch.translateBy(x: -kCanvas.x, y: -kCanvas.y)
                punch.translateBy(x: bodyInset, y: bodyInset)
                punch.scaleBy(x: bodyScale, y: bodyScale)
                punch.fill(keyhole, with: .color(.black.opacity(cut)))
            }
        }

        // Light spilling out of the keyhole just before the camera goes in.
        let glow = 0.5 * smooth((t - 1.0) / 0.6) * (1 - smooth((e - 0.15) / 0.55))
        if glow > 0.01 {
            var g = context
            g.blendMode = .plusLighter
            let r = 90 * artScale
            g.fill(Path(ellipseIn: CGRect(x: kPos.x - r, y: kPos.y - r, width: 2 * r, height: 2 * r)),
                   with: .radialGradient(Gradient(colors: [hex(0xFFD49A, glow), hex(0xFFD49A, 0)]), center: kPos, startRadius: 0, endRadius: r))
        }

        // A ring runs out from the keyhole as the clasp clicks.
        let u = clamp((t - 1.08) / 0.8)
        if u > 0 && u < 1 {
            let r = (24 + 150 * easeOut(u)) * artScale
            context.stroke(Path(ellipseIn: CGRect(x: kPos.x - r, y: kPos.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(cream.opacity(0.7 * (1 - u))), lineWidth: 1.5)
        }

        // Wordmark
        let wordAlpha = wordIn * (1 - wordOut)
        if wordAlpha > 0.01 {
            var w = context
            w.opacity = wordAlpha
            // Measured from the icon's visible edge (the 1024 canvas has a 100-unit margin), so the name sits close.
            let iconBottom = center.y + (924 - 512) * b * appearScale
            let baseY = iconBottom + 30 - 8 * (1 - wordIn)
            // The logo's own letters (scripts/make-wordmark.py), not a system font.
            let h: CGFloat = 30, ww = h * Wordmark.aspectRatio
            w.stroke(Wordmark().path(in: CGRect(x: W / 2 - ww / 2, y: baseY - h / 2, width: ww, height: h)),
                     with: .color(cream), style: StrokeStyle(lineWidth: Wordmark.lineWidth(forHeight: h)))
            w.draw(w.resolve(Text("Your secrets, kept close.").font(.system(size: 13)).kerning(0.6).foregroundColor(cream.opacity(0.62))),
                   at: CGPoint(x: W / 2, y: baseY + 30), anchor: .center)
        }
    }
}

#if DEBUG
/// Review frames of the welcome (development only): `SATCHEL_SPLASH_DUMP=<folder>` renders the
/// animation to numbered PNGs over a stand-in for the create-vault screen, then quits.
struct SplashPreviewScene: View {
    let time: Double

    var body: some View {
        let push = min(1, max(0, (time - SplashTiming.pushStart) / (SplashTiming.pushEnd - SplashTiming.pushStart)))
        ZStack {
            Theme.stage
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Create the vault for “Personal”").font(Theme.title)
                Text("Pick a long passphrase. It cannot be recovered.").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Master password").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    Divider()
                    Text("Confirm password").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(width: 320)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
                Text("Create vault").font(Theme.body.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 30).background(Color.accentColor, in: Capsule())
            }
            .scaleEffect(0.9 + 0.1 * push * push)
            SplashFrame(time: time)
        }
        .frame(width: 1040, height: 640)
    }
}

@MainActor
enum SplashDump {
    static func run(to folder: String) {
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fps = 30.0
        let frames = Int(SplashTiming.duration * fps) + 12 // a short hold on the finished app
        for i in 0..<frames {
            let renderer = ImageRenderer(content: SplashPreviewScene(time: Double(i) / fps))
            renderer.scale = 1.5
            guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appendingPathComponent(String(format: "frame_%03d.png", i)))
        }
        NSApp.terminate(nil)
    }
}
#endif
