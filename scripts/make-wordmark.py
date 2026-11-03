#!/usr/bin/env python3
"""The "satchel" wordmark, drawn once and written twice: SVG files for the website and emails
(Resources/Brand/satchel-wordmark-<weight>.svg) and a SwiftUI shape for the app
(Sources/Vault/UI/Wordmark.swift). Both come from the same cubic Bézier curves, so they match.

The style: monoline geometric, lowercase; even strokes, round bowls that fill the x-height, flat cut
ends, and a drop-shaped "a" whose bowl ends in a square corner. Drawn, not typed: no font licence.

Units: baseline y=600, x-height y=200, ascender y=40 (y grows downward). Strokes are centred on the
lines. Weights: 20 for large uses, 30 for small ones (thin lines vanish when small).

Usage: python3 scripts/make-wordmark.py
"""
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
R = 200            # bowl radius: a circle spanning the x-height exactly
GAP = 70           # space between letters
BASE, XH, ASC, MID = 600, 200, 40, 400


class Pen:
    """Collects subpaths of absolute moves, lines and cubic curves."""

    def __init__(self):
        self.ops = []          # ("M", x, y) | ("L", x, y) | ("C", x1, y1, x2, y2, x, y) | ("Z",)
        self.cur = (0.0, 0.0)

    def move(self, x, y):
        self.ops.append(("M", x, y)); self.cur = (x, y)

    def line(self, x, y):
        self.ops.append(("L", x, y)); self.cur = (x, y)

    def close(self):
        self.ops.append(("Z",))

    def arc(self, cx, cy, rx, ry, a0, a1):
        """Elliptical arc from angle a0 to a1 (degrees, maths convention: counter-clockwise, y up),
        as cubic Béziers of at most 90° each. Starts where the pen is."""
        steps = max(1, math.ceil(abs(a1 - a0) / 90))
        da = (a1 - a0) / steps
        for i in range(steps):
            t0 = math.radians(a0 + i * da); t1 = math.radians(a0 + (i + 1) * da)
            k = 4 / 3 * math.tan((t1 - t0) / 4)
            p = lambda u, v: (cx + rx * u, cy - ry * v)
            c1 = p(math.cos(t0) - k * math.sin(t0), math.sin(t0) + k * math.cos(t0))
            c2 = p(math.cos(t1) + k * math.sin(t1), math.sin(t1) - k * math.cos(t1))
            end = p(math.cos(t1), math.sin(t1))
            self.ops.append(("C", *c1, *c2, *end)); self.cur = end


def at(cx, cy, rx, ry, deg):
    t = math.radians(deg)
    return cx + rx * math.cos(t), cy - ry * math.sin(t)


# Each glyph draws at x and returns its advance width.
def g_s(p, x):
    rx, ry = 116, 100; c = x + rx
    p.move(*at(c, 300, rx, ry, 28)); p.arc(c, 300, rx, ry, 28, 270)     # over the top, down to the waist
    p.arc(c, 500, rx, ry, 90, -152)                                      # round the bottom
    return 2 * rx

def g_a(p, x):
    cx = x + R
    p.move(cx + R, MID); p.arc(cx, MID, R, R, 0, 270)                    # the bowl, anticlockwise to the bottom
    p.line(cx + R, BASE); p.close()                                     # the square corner
    return 2 * R

def g_t(p, x):
    sx = x + 60
    p.move(sx, 80); p.line(sx, BASE - 110); p.arc(sx + 110, BASE - 110, 110, 110, 180, 270)   # stem and foot
    p.move(x, XH); p.line(sx + 120, XH)                                 # crossbar
    return 180

def g_c(p, x):
    cx = x + R
    p.move(*at(cx, MID, R, R, 48)); p.arc(cx, MID, R, R, 48, 312)
    return R + R * math.cos(math.radians(48))

def g_h(p, x):
    w = 330; r = w / 2
    p.move(x, ASC); p.line(x, BASE)
    p.move(x, XH + r); p.arc(x + r, XH + r, r, r, 180, 0); p.line(x + w, BASE)
    return w

def g_e(p, x):
    cx = x + R
    p.move(cx - R, MID); p.line(cx + R, MID); p.arc(cx, MID, R, R, 0, 318)
    return 2 * R

def g_l(p, x):
    p.move(x, ASC); p.line(x, BASE)
    return 0


def draw():
    p, x = Pen(), 0.0
    for g in (g_s, g_a, g_t, g_c, g_h, g_e, g_l):
        x += g(p, x) + GAP
    return p, x - GAP


def svg(p, width, stroke):
    f = lambda v: f"{v:.2f}".rstrip("0").rstrip(".")
    d = []
    for op in p.ops:
        if op[0] == "Z": d.append("Z")
        else: d.append(op[0] + " ".join(f(v) for v in op[1:]))
    pad = stroke / 2 + 2
    vb = f"{f(-pad)} {f(ASC - pad)} {f(width + 2 * pad)} {f(BASE - ASC + 2 * pad)}"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" role="img" aria-label="satchel">'
            f'<path d="{"".join(d)}" fill="none" stroke="currentColor" stroke-width="{f(stroke)}"/></svg>\n')


def swift(p, width):
    f = lambda v: f"{v:.2f}"
    lines = []
    for op in p.ops:
        if op[0] == "M": lines.append(f"        p.move(to: CGPoint(x: {f(op[1])}, y: {f(op[2])}))")
        elif op[0] == "L": lines.append(f"        p.addLine(to: CGPoint(x: {f(op[1])}, y: {f(op[2])}))")
        elif op[0] == "C": lines.append(f"        p.addCurve(to: CGPoint(x: {f(op[5])}, y: {f(op[6])}), control1: CGPoint(x: {f(op[1])}, y: {f(op[2])}), control2: CGPoint(x: {f(op[3])}, y: {f(op[4])}))")
        else: lines.append("        p.closeSubpath()")
    body = "\n".join(lines)
    return (SWIFT_TEMPLATE.replace('@ASC@', str(ASC)).replace('@WIDTH@', f(width))
            .replace('@HEIGHT@', str(BASE - ASC)).replace('@BODY@', body))


SWIFT_TEMPLATE = r"""// Generated by scripts/make-wordmark.py: do not edit; change the script and run it again.
import SwiftUI

/// The "satchel" wordmark as a vector shape (the same curves as the website's logo). Stroke it:
/// `Wordmark().stroke(lineWidth: …)`; `Wordmark.lineWidth(forHeight:)` gives the weight for a size.
struct Wordmark: Shape {
    /// The drawing's box in its own units: baseline 600, ascender 40.
    static let bounds = CGRect(x: 0, y: @ASC@, width: @WIDTH@, height: @HEIGHT@)
    static var aspectRatio: CGFloat { bounds.width / bounds.height }

    /// Thin lines vanish when small: 20 units of 560 when large, up to 30 when the mark is short.
    static func lineWidth(forHeight h: CGFloat) -> CGFloat {
        let units: CGFloat = h >= 60 ? 20 : h <= 24 ? 30 : 30 - 10 * (h - 24) / 36
        return units * h / bounds.height
    }

    static let path: Path = {
        var p = Path()
@BODY@
        return p
    }()

    func path(in rect: CGRect) -> Path {
        // Fit the drawing into rect, keeping its proportions, with room for the stroke.
        let scale = min(rect.width / Self.bounds.width, rect.height / Self.bounds.height)
        let w = Self.bounds.width * scale, h = Self.bounds.height * scale
        let t = CGAffineTransform(translationX: rect.midX - w / 2, y: rect.midY - h / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -Self.bounds.minX, y: -Self.bounds.minY)
        return Self.path.applying(t)
    }
}

/// The wordmark at a given height, stroked at the right weight, in the current foreground style.
struct WordmarkView: View {
    var height: CGFloat
    var body: some View {
        Wordmark()
            .stroke(style: StrokeStyle(lineWidth: Wordmark.lineWidth(forHeight: height), lineJoin: .miter))
            .frame(width: height * Wordmark.aspectRatio, height: height)
            .padding(Wordmark.lineWidth(forHeight: height) / 2)
            .accessibilityLabel("Satchel")
    }
}
"""


if __name__ == "__main__":
    p, width = draw()
    brand = ROOT / "Resources/Brand"; brand.mkdir(parents=True, exist_ok=True)
    for name, stroke in (("light", 20), ("regular", 30)):
        (brand / f"satchel-wordmark-{name}.svg").write_text(svg(p, width, stroke))
    (ROOT / "Sources/Vault/UI/Wordmark.swift").write_text(swift(p, width))
    print(f"wrote Resources/Brand/satchel-wordmark-*.svg and Sources/Vault/UI/Wordmark.swift (width {width:.1f})")
