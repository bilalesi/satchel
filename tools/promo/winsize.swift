import CoreGraphics
import Foundation
// winsize PID : prints "W H Y" of the app's biggest normal window (layer 0), or nothing.
let pid = Int32(CommandLine.arguments[1])!
var best: (Double, Double, Double)? = nil
for w in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]] {
    guard (w["kCGWindowOwnerPID"] as? Int32) == pid, (w["kCGWindowLayer"] as? Int) == 0,
          let b = w["kCGWindowBounds"] as? [String: Double], let width = b["Width"], let height = b["Height"], height > 100 else { continue }
    if best == nil || width * height > best!.0 * best!.1 { best = (width, height, b["Y"] ?? 0) }
}
if let b = best { print(Int(b.0), Int(b.1), Int(b.2)) }
