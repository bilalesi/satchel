#!/usr/bin/env swift
// Draws Satchel's app icon with Core Graphics and writes:
//   Resources/AppIcon.iconset/*.png  → iconutil → Resources/AppIcon.icns   (classic, macOS <= 15)
//   Resources/AppIcon.icon/           → actool  → Assets.car               (macOS 26 layered icon)
//
// Design: the satchel IS the icon. The leather is the background (no separate plate); the
// handle, flap, stitching and clasp are drawn large on it. macOS 26 masks every icon to its
// rounded square, so full-bleed leather is the only way to have no plate behind the artwork.
// Small sizes use heavier strokes and drop the stitching instead of downscaling detail.
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

let leatherTop = rgb(0xF7C27A), leatherBottom = rgb(0xD9822C)
let flapTop = rgb(0xE9993F), flapBottom = rgb(0xB5601B)
let handleColor = rgb(0x8E4812), handleHighlight = rgb(0xB8681F)
let claspTop = rgb(0xFFF6E6), claspBottom = rgb(0xEBD3AC)
let keyhole = rgb(0x3A220F)
let stitch = rgb(0xFFF1DA, 0.9)

// MARK: Geometry (1024 grid, y grows downward)

enum Detail { case full, medium, minimal }

func detail(for pixels: Int) -> Detail {
    switch pixels {
    case ...32: return .minimal
    case ...128: return .medium
    default: return .full
    }
}

func handleWidth(_ d: Detail) -> CGFloat {
    switch d { case .full: return 72; case .medium: return 84; case .minimal: return 104 }
}

func linear(_ ctx: CGContext, _ path: CGPath, _ top: CGColor, _ bottom: CGColor, from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func handlePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 336, y: 430))
    p.addLine(to: CGPoint(x: 336, y: 330))
    p.addCurve(to: CGPoint(x: 688, y: 330), control1: CGPoint(x: 336, y: 150), control2: CGPoint(x: 688, y: 150))
    p.addLine(to: CGPoint(x: 688, y: 430))
    return p
}

/// Flap: wider than the canvas so the rounded-square mask trims its sides.
func flapPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: -40, y: 430))
    p.addLine(to: CGPoint(x: 1064, y: 430))
    p.addLine(to: CGPoint(x: 1064, y: 640))
    p.addCurve(to: CGPoint(x: -40, y: 640), control1: CGPoint(x: 900, y: 860), control2: CGPoint(x: 124, y: 860))
    p.closeSubpath()
    return p
}

let clasp = CGRect(x: 452, y: 690, width: 120, height: 140)

func keyholePath(_ d: Detail) -> CGPath {
    let p = CGMutablePath()
    let cx = clasp.midX
    p.addEllipse(in: CGRect(x: cx - 19, y: clasp.minY + 38, width: 38, height: 38))
    if d != .minimal {
        p.addPath(roundedRect(CGRect(x: cx - 9, y: clasp.minY + 62, width: 18, height: 46), 8))
    }
    return p
}

// MARK: Layers

struct Parts: OptionSet { let rawValue: Int
    static let background = Parts(rawValue: 1), handle = Parts(rawValue: 2), flap = Parts(rawValue: 4)
    static let all: Parts = [.background, .handle, .flap]
}

/// `squircle`: draw inside the macOS icon grid (824 pt body + shadow) for the classic .icns.
/// Otherwise the artwork fills the whole 1024 canvas (Icon Composer layers).
func draw(_ ctx: CGContext, pixels: Int, parts: Parts, squircle: Bool) {
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let d = detail(for: pixels)

    ctx.saveGState()
    if squircle {
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = roundedRect(rect, 185)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
        ctx.addPath(shape); ctx.setFillColor(leatherBottom); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.clip()
        // Artwork was drawn for the full canvas; fit it to the 824 body.
        ctx.translateBy(x: 100, y: 100)
        ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
    }

    if parts.contains(.background) {
        linear(ctx, CGPath(rect: CGRect(x: -40, y: -40, width: 1104, height: 1104), transform: nil),
               leatherTop, leatherBottom, from: 0, to: 1024)
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 420), options: [])
    }

    if parts.contains(.handle) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 14, color: rgb(0x4A2308, 0.45))
        ctx.addPath(handlePath())
        ctx.setLineWidth(handleWidth(d)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(handleColor); ctx.strokePath()
        ctx.restoreGState()
        if d == .full {
            ctx.saveGState()
            ctx.addPath(handlePath())
            ctx.setLineWidth(handleWidth(d) * 0.28); ctx.setLineCap(.round)
            ctx.setStrokeColor(handleHighlight)
            ctx.translateBy(x: 0, y: -handleWidth(d) * 0.2)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    if parts.contains(.flap) {
        let flap = flapPath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: rgb(0x4A2308, 0.5))
        ctx.addPath(flap); ctx.setFillColor(flapBottom); ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, flap, flapTop, flapBottom, from: 430, to: 800)

        if d == .full {
            ctx.saveGState()
            let inner = CGMutablePath()
            inner.move(to: CGPoint(x: 70, y: 470))
            inner.addLine(to: CGPoint(x: 954, y: 470))
            inner.addLine(to: CGPoint(x: 954, y: 630))
            inner.addCurve(to: CGPoint(x: 70, y: 630), control1: CGPoint(x: 830, y: 800), control2: CGPoint(x: 194, y: 800))
            inner.closeSubpath()
            ctx.addPath(inner)
            ctx.setLineWidth(9); ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [20, 22])
            ctx.setStrokeColor(stitch); ctx.strokePath()
            ctx.restoreGState()
        }

        let claspPath = roundedRect(clasp, d == .minimal ? 22 : 28)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 14, color: rgb(0x3A1C05, 0.45))
        ctx.addPath(claspPath); ctx.setFillColor(claspBottom); ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, claspPath, claspTop, claspBottom, from: clasp.minY, to: clasp.maxY)
        ctx.addPath(keyholePath(d)); ctx.setFillColor(keyhole); ctx.fillPath()
    }
    ctx.restoreGState()
}

func render(pixels: Int, parts: Parts, squircle: Bool) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, pixels: pixels, parts: parts, squircle: squircle)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

// MARK: Classic iconset (each size drawn at its own detail level)

let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(render(pixels: px, parts: .all, squircle: true), iconset.appendingPathComponent(name))
    }
}

// MARK: Icon Composer bundle (macOS 26). The system draws the rounded square and its glass;
// the leather is the bundle's fill, the handle and flap are layers on top.

let iconBundle = outDir.appendingPathComponent("AppIcon.icon", isDirectory: true)
try? FileManager.default.removeItem(at: iconBundle)
let assets = iconBundle.appendingPathComponent("Assets", isDirectory: true)
write(render(pixels: 1024, parts: [.handle], squircle: false), assets.appendingPathComponent("handle.png"))
write(render(pixels: 1024, parts: [.flap], squircle: false), assets.appendingPathComponent("flap.png"))
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.96863,0.76078,0.47843,1.00000",
      "srgb:0.85098,0.50980,0.17255,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [ { "image-name" : "flap.png", "name" : "flap" } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0 }
    },
    {
      "layers" : [ { "image-name" : "handle.png", "name" : "handle" } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.4 },
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
"""
write(Data(iconJSON.utf8), iconBundle.appendingPathComponent("icon.json"))
print("wrote \(iconset.path) and \(iconBundle.path)")
