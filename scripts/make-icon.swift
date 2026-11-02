#!/usr/bin/env swift
// Draws Satchel's app icon with Core Graphics and writes:
//   Resources/AppIcon.iconset/*.png  → iconutil → Resources/AppIcon.icns   (classic, all sizes)
//   Resources/AppIcon.icon/           → actool  → Assets.car               (macOS 26 layered icon)
// Small sizes are drawn with less detail and heavier strokes (optical sizing), not downscaled.
// Usage: swift scripts/make-icon.swift [output-dir]   (default: Resources)

import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)

// MARK: Palette

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let inkTop = rgb(0x2C3140), inkBottom = rgb(0x12141B)
let leatherLight = rgb(0xF4B866), leatherDark = rgb(0xD47F2A)
let flapLight = rgb(0xE79A3F), flapDark = rgb(0xB9631C)
let handleColor = rgb(0xE5A04C)
let claspLight = rgb(0xFFF6E6), claspDark = rgb(0xF0DDBF)
let keyhole = rgb(0x3A220F)
let stitch = rgb(0xFFF1DA, 0.85)

// MARK: Geometry (1024 design grid, y grows downward like the Icon Composer canvas)

enum Detail { case full, medium, minimal }

struct Glyph {
    /// Scale of the glyph around the canvas centre; small sizes enlarge it to read better.
    var scale: CGFloat
    var handleWidth: CGFloat
    var detail: Detail
}

func glyph(for pixels: Int) -> Glyph {
    switch pixels {
    case ...16: return Glyph(scale: 1.16, handleWidth: 70, detail: .minimal)
    case ...32: return Glyph(scale: 1.10, handleWidth: 60, detail: .minimal)
    case ...64: return Glyph(scale: 1.04, handleWidth: 52, detail: .medium)
    case ...128: return Glyph(scale: 1.0, handleWidth: 46, detail: .medium) // stitching would be < 1px
    default: return Glyph(scale: 1.0, handleWidth: 44, detail: .full)
    }
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linear(_ ctx: CGContext, _ path: CGPath, _ top: CGColor, _ bottom: CGColor, from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Bag parts, in the 1024 grid before the glyph scale is applied.
let body = CGRect(x: 254, y: 404, width: 516, height: 404)
let bodyRadius: CGFloat = 76

func handlePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 398, y: 410))
    p.addLine(to: CGPoint(x: 398, y: 336))
    p.addCurve(to: CGPoint(x: 626, y: 336), control1: CGPoint(x: 398, y: 248), control2: CGPoint(x: 626, y: 248))
    p.addLine(to: CGPoint(x: 626, y: 410))
    return p
}

func flapPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 254, y: 404 + bodyRadius))
    p.addArc(tangent1End: CGPoint(x: 254, y: 404), tangent2End: CGPoint(x: 254 + bodyRadius, y: 404), radius: bodyRadius)
    p.addLine(to: CGPoint(x: 770 - bodyRadius, y: 404))
    p.addArc(tangent1End: CGPoint(x: 770, y: 404), tangent2End: CGPoint(x: 770, y: 404 + bodyRadius), radius: bodyRadius)
    p.addLine(to: CGPoint(x: 770, y: 560))
    p.addCurve(to: CGPoint(x: 254, y: 560), control1: CGPoint(x: 640, y: 676), control2: CGPoint(x: 384, y: 676))
    p.closeSubpath()
    return p
}

let clasp = CGRect(x: 466, y: 566, width: 92, height: 106)

func keyholePath(_ detail: Detail) -> CGPath {
    let p = CGMutablePath()
    let cx = clasp.midX
    p.addEllipse(in: CGRect(x: cx - 15, y: clasp.minY + 28, width: 30, height: 30))
    if detail != .minimal {
        p.addPath(roundedRect(CGRect(x: cx - 7, y: clasp.minY + 46, width: 14, height: 36), 6))
    }
    return p
}

// MARK: Layers

/// Draws into a 1024 canvas. `background` adds the ink squircle; `parts` picks layers.
struct Parts: OptionSet { let rawValue: Int
    static let handle = Parts(rawValue: 1), body = Parts(rawValue: 2), flap = Parts(rawValue: 4)
    static let all: Parts = [.handle, .body, .flap]
}

func draw(_ ctx: CGContext, pixels: Int, background: Bool, parts: Parts, squircle: Bool) {
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    // Flip to a top-left origin so the geometry reads like the design grid.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    if background {
        // macOS icon grid: 824pt body inside 1024 with a soft drop shadow (legacy .icns only).
        let rect = squircle ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let shape = roundedRect(rect, squircle ? 185 : 0)
        if squircle {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
            ctx.addPath(shape); ctx.setFillColor(inkBottom); ctx.fillPath()
            ctx.restoreGState()
        }
        linear(ctx, shape, inkTop, inkBottom, from: rect.minY, to: rect.maxY)
        // Faint top sheen.
        ctx.saveGState(); ctx.addPath(shape); ctx.clip()
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.minY + rect.height * 0.45), options: [])
        ctx.restoreGState()
        if squircle {
            ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(2); ctx.strokePath()
        }
    }

    let g = glyph(for: pixels)
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 540)
    ctx.scaleBy(x: g.scale, y: g.scale)
    ctx.translateBy(x: -512, y: -540)

    if parts.contains(.handle) {
        ctx.saveGState()
        ctx.addPath(handlePath())
        ctx.setLineWidth(g.handleWidth); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(handleColor); ctx.strokePath()
        ctx.restoreGState()
    }
    if parts.contains(.body) {
        let bodyPath = roundedRect(body, bodyRadius)
        if background {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(0x000000, 0.45))
            ctx.addPath(bodyPath); ctx.setFillColor(leatherDark); ctx.fillPath()
            ctx.restoreGState()
        }
        linear(ctx, bodyPath, leatherLight, leatherDark, from: body.minY, to: body.maxY)
    }
    if parts.contains(.flap) {
        let flap = flapPath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: rgb(0x5A2E0A, 0.45))
        ctx.addPath(flap); ctx.setFillColor(flapDark); ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, flap, flapLight, flapDark, from: 404, to: 660)
        if g.detail == .full {
            // Stitching just inside the flap edge.
            ctx.saveGState()
            let t = CGAffineTransform(translationX: 512, y: 520).scaledBy(x: 0.9, y: 0.88).translatedBy(x: -512, y: -520)
            ctx.addPath(flapPath().copy(using: [t])!)
            ctx.setLineWidth(7); ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [16, 18])
            ctx.setStrokeColor(stitch); ctx.strokePath()
            ctx.restoreGState()
        }
        // Clasp with keyhole.
        let claspPath = roundedRect(clasp, g.detail == .minimal ? 18 : 22)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 10, color: rgb(0x3A1C05, 0.4))
        ctx.addPath(claspPath); ctx.setFillColor(claspDark); ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, claspPath, claspLight, claspDark, from: clasp.minY, to: clasp.maxY)
        ctx.addPath(keyholePath(g.detail)); ctx.setFillColor(keyhole); ctx.fillPath()
    }
    ctx.restoreGState()
}

func render(pixels: Int, background: Bool, parts: Parts, squircle: Bool) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, pixels: pixels, background: background, parts: parts, squircle: squircle)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

// MARK: Classic iconset (every size macOS asks for, each drawn at its own detail level)

let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(render(pixels: px, background: true, parts: .all, squircle: true), iconset.appendingPathComponent(name))
    }
}

// MARK: Icon Composer bundle (macOS 26): background is the bundle's fill; glyph parts are layers.

let iconBundle = outDir.appendingPathComponent("AppIcon.icon", isDirectory: true)
try? FileManager.default.removeItem(at: iconBundle)
let assets = iconBundle.appendingPathComponent("Assets", isDirectory: true)
write(render(pixels: 1024, background: false, parts: [.handle, .body], squircle: false), assets.appendingPathComponent("bag.png"))
write(render(pixels: 1024, background: false, parts: [.flap], squircle: false), assets.appendingPathComponent("flap.png"))
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.17255,0.19216,0.25098,1.00000",
      "srgb:0.07059,0.07843,0.10588,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [ { "image-name" : "flap.png", "name" : "flap", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.3 }
    },
    {
      "layers" : [ { "image-name" : "bag.png", "name" : "bag", "glass" : true } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.2 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
"""
write(Data(iconJSON.utf8), iconBundle.appendingPathComponent("icon.json"))
print("wrote \(iconset.path) and \(iconBundle.path)")
