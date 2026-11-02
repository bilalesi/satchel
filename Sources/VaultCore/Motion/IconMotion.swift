import Foundation

/// How an icon is drawn at one moment of its motion: scale, turn (degrees), shift (in a 18-pt tile) and opacity.
public struct IconPose: Equatable, Sendable {
    public var sx = 1.0, sy = 1.0, rotation = 0.0, dx = 0.0, dy = 0.0, opacity = 1.0
    public static let rest = IconPose()
    public init(sx: Double = 1, sy: Double = 1, rotation: Double = 0, dx: Double = 0, dy: Double = 0, opacity: Double = 1) {
        self.sx = sx; self.sy = sy; self.rotation = rotation; self.dx = dx; self.dy = dy; self.opacity = opacity
    }
}

/// One short motion per kind of icon: a star pops and spins, a key turns, the history clock winds back,
/// a link stretches. Each is a pure function of progress `p` in 0...1 that starts and ends at rest, so the
/// view only needs the clock: no keyframe state, nothing to drift, and the shape of every motion is testable.
public enum IconMotion: CaseIterable, Sendable {
    case pop, spinStar, heartbeat, rewind, sweep, drop, turnKey, stack, stretch, fold, blink, openLid
    case hop, launch, flicker, flash, float, spinGlobe, tilt, nod

    /// Seconds one motion takes.
    public static let duration = 0.7

    /// The motion that suits an icon (by its Codicon case name); anything unlisted pops.
    public static func forIcon(_ name: String) -> IconMotion {
        switch name {
        case "dashboard": return .sweep
        case "inbox", "bookmark": return .drop
        case "starFull", "star": return .spinStar
        case "history": return .rewind
        case "account": return .nod
        case "key": return .turnKey
        case "database", "server", "layers": return .stack
        case "link": return .stretch
        case "note": return .fold
        case "terminal": return .blink
        case "folder": return .openLid
        case "heart": return .heartbeat
        case "rocket": return .launch
        case "flame": return .flicker
        case "lightbulb": return .flash
        case "cloud": return .float
        case "globe": return .spinGlobe
        case "coffee", "mail": return .tilt
        case "home", "briefcase", "gift": return .hop
        default: return .pop
        }
    }

    public func pose(at progress: Double) -> IconPose {
        let p = min(max(progress, 0), 1)
        let bump = sin(.pi * p)                       // 0 → 1 → 0
        let ease = p * p * (3 - 2 * p)                // 0 → 1, slow at both ends
        func wobble(_ cycles: Double) -> Double { sin(2 * .pi * cycles * p) * (1 - p) } // decaying swing, 0 at both ends
        switch self {
        case .pop: return IconPose(sx: 1 + 0.3 * bump, sy: 1 + 0.3 * bump)
        case .spinStar: return IconPose(sx: 1 + 0.3 * bump, sy: 1 + 0.3 * bump, rotation: 360 * ease)
        case .heartbeat:
            let beat = 1 + 0.25 * abs(sin(2 * .pi * p)) * (1 - p)
            return IconPose(sx: beat, sy: beat)
        case .rewind: return IconPose(rotation: -360 * ease)
        case .sweep: return IconPose(rotation: 40 * wobble(1.5))
        case .drop: return IconPose(sy: 1 - 0.12 * bump, dy: 3 * bump)
        case .turnKey: return IconPose(rotation: 55 * bump)
        case .stack: return IconPose(sx: 1 - 0.1 * wobble(1.5), sy: 1 + 0.18 * wobble(1.5))
        case .stretch: return IconPose(sx: 1 + 0.3 * wobble(1), sy: 1 - 0.12 * wobble(1))
        case .fold: return IconPose(rotation: -10 * wobble(1.25), dy: -1.5 * bump)
        case .blink: return IconPose(dx: 1.5 * bump, opacity: 0.25 + 0.75 * abs(cos(2 * .pi * 1.5 * p)))
        case .openLid: return IconPose(sy: 1 + 0.15 * bump, rotation: -6 * bump)
        case .hop: return IconPose(dy: -5 * bump)
        case .launch: return IconPose(dx: 3 * bump, dy: -4 * bump)
        case .flicker: return IconPose(sx: 1 - 0.08 * wobble(3), sy: 1 + 0.15 * wobble(3), rotation: 4 * wobble(4))
        case .flash: return IconPose(opacity: 0.35 + 0.65 * abs(cos(2 * .pi * 1.5 * p)))
        case .float: return IconPose(dy: -3 * sin(2 * .pi * p))
        case .spinGlobe: return IconPose(rotation: 360 * ease)
        case .tilt: return IconPose(rotation: 14 * bump)
        case .nod: return IconPose(rotation: 10 * wobble(1), dy: 1.5 * bump)
        }
    }
}
