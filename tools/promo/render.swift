import AVFoundation
import AppKit
import CoreImage
import CoreVideo
import Foundation

// render TIMELINE.json : draws the promo frame by frame on the GPU (Core Image) and writes an H.264 file.
// Camera moves are sub-pixel (no whole-pixel jitter), speed-ups blend neighbouring source frames, and every
// motion (camera, captions, call-outs, transitions) is a function of time with an easing curve.

struct Cam: Codable { var t: Double; var zoom: Double; var u: Double; var v: Double; var ease: String? }
struct Overlay: Codable {
    var kind: String                 // "image" | "lens"
    var png: String?
    var rect: [Double]?              // output rect, top-left [x, y, w, h]
    var t0: Double; var t1: Double
    var anim: String?                // "slideUp" | "pop" | "fade" | "slideLeft"
    var lensSrc: [Double]?           // lens: region of the (cropped) source frame, px [x, y, w, h]
    var mask: String?; var frame: String?; var ring: String?
}
struct Layer: Codable { var png: String; var x: Double; var y: Double; var t0: Double; var anim: String; var dur: Double? }
struct Transition: Codable { var kind: String; var dur: Double }
struct Shot: Codable {
    var kind: String                 // "clip" | "card"
    var src: String?; var ss: Double?; var speed: Double?; var cropTop: Double?
    var dur: Double
    var cam: [Cam]?
    var overlays: [Overlay]?
    var bg: String?; var layers: [Layer]?
    var transition: Transition?      // into this shot, overlapping the previous one
}
struct Timeline: Codable { var out: String; var fps: Int; var shots: [Shot] }

let W = 1920.0, H = 1080.0
let SRC_W = 3024.0, SRC_H = 1701.0   // a 16:9 window of the recording
let metal = MTLCreateSystemDefaultDevice()
let ci = CIContext(mtlDevice: metal!, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))

// MARK: easing
func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(max(x, a), b) }
func easeInOut(_ x: Double) -> Double { let t = clamp(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
func easeOutExpo(_ x: Double) -> Double { let t = clamp(x); return t >= 1 ? 1 : 1 - pow(2, -10 * t) }
func easeOutBack(_ x: Double) -> Double { let t = clamp(x), c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) }
func ease(_ name: String?, _ x: Double) -> Double {
    switch name { case "expo": return easeOutExpo(x); case "out": return easeOut(x); case "linear": return clamp(x); default: return easeInOut(x) }
}

// MARK: source frames
final class Feeder {
    let reader: AVAssetReader
    let out: AVAssetReaderTrackOutput
    var prev: (CIImage, Double)?
    var cur: (CIImage, Double)?
    init(path: String, start: Double) throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = asset.tracks(withMediaType: .video)[0]
        reader = try AVAssetReader(asset: asset)
        out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start - 0.1), preferredTimescale: 600), duration: .positiveInfinity)
        reader.add(out)
        reader.startReading()
        cur = pull()
    }
    func pull() -> (CIImage, Double)? {
        guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        return (CIImage(cvPixelBuffer: pb), CMSampleBufferGetPresentationTimeStamp(sb).seconds)
    }
    /// The picture at source time `ts`; with `blend`, the two neighbouring frames mixed by position (smooth fast-forward).
    func frame(at ts: Double, blend: Bool) -> CIImage {
        while let c = cur, c.1 < ts, let n = pull() { prev = c; cur = n }
        guard let c = cur else { return prev?.0 ?? black }
        guard blend, let p = prev, c.1 > p.1 else { return c.0 }
        let a = clamp((ts - p.1) / (c.1 - p.1))
        return p.0.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: c.0, kCIInputTimeKey: a])
    }
    func close() { reader.cancelReading() }
}

// MARK: images
var pngCache: [String: CIImage] = [:]
func png(_ path: String) -> CIImage {
    if let c = pngCache[path] { return c }
    guard let img = CIImage(contentsOf: URL(fileURLWithPath: path)) else { fatalError("missing \(path)") }
    pngCache[path] = img; return img
}
func withAlpha(_ img: CIImage, _ a: Double) -> CIImage {
    a >= 0.999 ? img : img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a))])
}
/// Places `img` (its own pixel size) with its top-left at (x, y) in the output, moved by (dx, dy) and scaled about its centre.
func place(_ img: CIImage, x: Double, y: Double, dx: Double = 0, dy: Double = 0, scale: Double = 1) -> CIImage {
    let w = img.extent.width, h = img.extent.height
    // scale about the image's centre, then put its top-left corner at (x + dx, y + dy) of the output
    let t = CGAffineTransform(translationX: CGFloat(-w / 2), y: CGFloat(-h / 2))
        .concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        .concatenating(CGAffineTransform(translationX: CGFloat(w / 2 + x + dx), y: CGFloat(H - y - h / 2 - dy)))
    return img.transformed(by: t)
}

// MARK: shot rendering
func cameraFrame(_ src: CIImage, cropTop: Double, cam: [Cam], t: Double) -> (CIImage, Double, Double, Double) {
    var zoom = 1.0, u = 0.5, v = 0.5
    if let first = cam.first {
        zoom = first.zoom; u = first.u; v = first.v
        for i in 0..<cam.count - 1 where t >= cam[i].t {
            let a = cam[i], b = cam[i + 1]
            let e = ease(b.ease, (t - a.t) / max(b.t - a.t, 1e-6))
            zoom = a.zoom + (b.zoom - a.zoom) * e; u = a.u + (b.u - a.u) * e; v = a.v + (b.v - a.v) * e
        }
        if let last = cam.last, t >= last.t { zoom = last.zoom; u = last.u; v = last.v }
    }
    let vw = SRC_W / zoom, vh = SRC_H / zoom
    let cx = clamp(u * SRC_W - vw / 2, 0, SRC_W - vw), cy = clamp(v * SRC_H - vh / 2, 0, SRC_H - vh)
    let s = W / vw
    let srcH = src.extent.height
    let yCI = srcH - (cropTop + cy + vh)
    let scaled = src.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
    let moved = scaled.transformed(by: CGAffineTransform(translationX: CGFloat(-cx * s), y: CGFloat(-yCI * s)))
    return (moved.cropped(to: CGRect(x: 0, y: 0, width: W, height: H)), zoom, cx, cy)
}

func overlayFrame(_ o: Overlay, t: Double, src: CIImage?, cropTop: Double) -> CIImage? {
    guard t >= o.t0, t <= o.t1 else { return nil }
    let pin = clamp((t - o.t0) / 0.42), pout = clamp((o.t1 - t) / 0.22)
    var alpha = easeOut(pin) * pout
    var dx = 0.0, dy = 0.0, scale = 1.0
    switch o.anim ?? "slideUp" {
    case "slideUp": dy = (1 - easeOutBack(pin)) * 56
    case "slideLeft": dx = (1 - easeOutBack(pin)) * 120
    case "pop": scale = 0.86 + 0.14 * easeOutBack(pin)
    default: break
    }
    if pout < 1 { dy += (1 - pout) * 14 }
    alpha = clamp(alpha)
    let r = o.rect ?? [0, 0, 0, 0]
    if o.kind == "image", let p = o.png {
        let img = png(p)
        let x = r.count > 2 && r[2] > 0 ? r[0] : (W - img.extent.width) / 2
        let y = r.count > 2 && r[2] > 0 ? r[1] : r[1]
        return place(withAlpha(img, alpha), x: x, y: y, dx: dx, dy: dy, scale: scale)
    }
    if o.kind == "lens", let s = o.lensSrc, let src, let m = o.mask, let f = o.frame, let rg = o.ring {
        // a magnified piece of the live picture, in a rounded frame
        let srcH = src.extent.height
        let region = CGRect(x: s[0], y: srcH - (cropTop + s[1] + s[3]), width: s[2], height: s[3])
        let k = r[2] / s[2]
        let zoomed = src.cropped(to: region).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
            .transformed(by: CGAffineTransform(translationX: -region.minX * k, y: -region.minY * k))
        let mask = png(m)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: mask.extent)
        let masked = zoomed.cropped(to: mask.extent).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        // shadow underneath, the magnified picture, then the border on top
        let framed = png(rg).composited(over: masked.composited(over: png(f)))
        return place(withAlpha(framed, alpha), x: r[0], y: r[1], dx: dx, dy: dy, scale: scale)
    }
    return nil
}

func shotFrame(_ shot: Shot, t: Double, feeder: Feeder?) -> CIImage {
    var img = black
    var srcFrame: CIImage? = nil
    if shot.kind == "clip", let feeder {
        let speed = shot.speed ?? 1
        srcFrame = feeder.frame(at: (shot.ss ?? 0) + t * speed, blend: speed > 1.2)
        let (cam, _, _, _) = cameraFrame(srcFrame!, cropTop: shot.cropTop ?? 66, cam: shot.cam ?? [], t: t)
        img = cam
    } else if shot.kind == "card" {
        if let bg = shot.bg { img = png(bg) }
        for l in shot.layers ?? [] {
            let lt = t - l.t0
            if lt < 0 { continue }
            let p = clamp(lt / (l.dur ?? 0.7)), pOut = clamp((shot.dur - t) / 0.35)
            let a = easeOut(p) * pOut
            var dy = 0.0, scale = 1.0
            switch l.anim { case "slideUp": dy = (1 - easeOutExpo(p)) * 70; case "spring": scale = 0.55 + 0.45 * easeOutBack(p); dy = (1 - easeOutExpo(p)) * -30; default: break }
            img = place(withAlpha(png(l.png), a), x: l.x, y: l.y, dy: dy, scale: scale).composited(over: img)
        }
    }
    for o in shot.overlays ?? [] {
        if let f = overlayFrame(o, t: t, src: srcFrame, cropTop: shot.cropTop ?? 66) { img = f.composited(over: img) }
    }
    return img.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
}

func blurred(_ img: CIImage, radius: Double, angle: Double) -> CIImage {
    radius < 1 ? img : img.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: angle])
        .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
}

func transitionFrame(_ kind: String, a: CIImage, b: CIImage, p: Double) -> CIImage {
    let e = easeInOut(p), v = 4 * p * (1 - p)    // v: how fast things move right now (0 at both ends)
    func shift(_ img: CIImage, _ dx: Double, _ dy: Double) -> CIImage { img.transformed(by: CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))) }
    switch kind {
    case "slideLeft", "whipLeft":
        let r = kind == "whipLeft" ? 70 * v : 0
        return blurred(shift(b, W * (1 - e), 0), radius: r, angle: 0).composited(over: blurred(shift(a, -W * e * 0.55, 0), radius: r, angle: 0)).cropped(to: black.extent)
    case "slideRight", "whipRight":
        let r = kind == "whipRight" ? 70 * v : 0
        return blurred(shift(b, -W * (1 - e), 0), radius: r, angle: 0).composited(over: blurred(shift(a, W * e * 0.55, 0), radius: r, angle: 0)).cropped(to: black.extent)
    case "slideUp":
        return shift(b, 0, -H * (1 - e)).composited(over: shift(a, 0, H * e * 0.55)).cropped(to: black.extent)
    case "zoom":
        let s = 1 + 0.35 * e
        let aa = withAlpha(a.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2).scaledBy(x: CGFloat(s), y: CGFloat(s)).translatedBy(x: W / 2 / s, y: H / 2 / s)), 1 - e)
        let sb = 0.82 + 0.18 * easeOut(p)
        let bb = withAlpha(b.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2).scaledBy(x: CGFloat(sb), y: CGFloat(sb)).translatedBy(x: W / 2 / sb, y: H / 2 / sb)), easeOut(p))
        return bb.composited(over: aa.composited(over: black)).cropped(to: black.extent)
    default: // dissolve
        return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: e])
    }
}

// MARK: main
guard CommandLine.arguments.count > 1 else { print("usage: render timeline.json [start end]"); exit(1) }
let tl = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var starts: [Double] = []
var cursor = 0.0
for (i, s) in tl.shots.enumerated() {
    let overlap = i > 0 ? (s.transition?.dur ?? 0) : 0
    let start = cursor - overlap
    starts.append(start); cursor = start + s.dur
}
let total = cursor
let from = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[2])! : 0
let to = CommandLine.arguments.count > 3 ? min(Double(CommandLine.arguments[3])!, total) : total
print("shots: \(tl.shots.count), total \(String(format: "%.2f", total)) s, rendering \(from)–\(to)")

let outURL = URL(fileURLWithPath: tl.out)
try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoExpectedSourceFrameRateKey: tl.fps, AVVideoMaxKeyFrameIntervalKey: tl.fps]])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H)])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var feeders: [Int: Feeder] = [:]
func feeder(for i: Int) -> Feeder? {
    guard tl.shots[i].kind == "clip", let path = tl.shots[i].src else { return nil }
    if let f = feeders[i] { return f }
    let f = try? Feeder(path: path, start: tl.shots[i].ss ?? 0)
    feeders[i] = f; return f
}

let frames = Int((to - from) * Double(tl.fps))
let startFrame = Int(from * Double(tl.fps))
// Feeders are sequential: a shot that starts after `from` begins at its own start, so a partial render only
// supports `from` at a shot boundary. Full renders (the default) are exact.
for n in 0..<frames {
    let T = Double(startFrame + n) / Double(tl.fps)
    var active: [Int] = []
    for i in 0..<tl.shots.count where T >= starts[i] - 1e-9 && T < starts[i] + tl.shots[i].dur - 1e-9 { active.append(i) }
    if active.isEmpty { active = [tl.shots.count - 1] }
    var image: CIImage
    if active.count == 2, let tr = tl.shots[active[1]].transition {
        let a = shotFrame(tl.shots[active[0]], t: T - starts[active[0]], feeder: feeder(for: active[0]))
        let b = shotFrame(tl.shots[active[1]], t: T - starts[active[1]], feeder: feeder(for: active[1]))
        image = transitionFrame(tr.kind, a: a, b: b, p: (T - starts[active[1]]) / tr.dur)
    } else {
        let i = active.last!
        image = shotFrame(tl.shots[i], t: T - starts[i], feeder: feeder(for: i))
    }
    // free readers of shots that are over
    for (i, f) in feeders where starts[i] + tl.shots[i].dur < T - 0.5 { f.close(); feeders[i] = nil }

    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    ci.render(image.composited(over: black), to: pb!, bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(tl.fps)))
    if n % 120 == 0 { print(String(format: "  %.1f s", T)) }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print("wrote \(tl.out)", writer.status == .completed ? "ok" : "FAILED \(String(describing: writer.error))")
