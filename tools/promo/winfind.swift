import CoreGraphics
import Foundation
// winfind PID : prints "X Y W H" of the app's small window (Settings, a card), the front-most one.
let pid = Int32(CommandLine.arguments[1])!
// winfind PID any : also windows above the normal layer (floating cards, menus).
let anyLayer = CommandLine.arguments.count > 2
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] {
    guard (w["kCGWindowOwnerPID"] as? Int32) == pid, anyLayer || (w["kCGWindowLayer"] as? Int) == 0,
          let b = w["kCGWindowBounds"] as? [String: Double], let width = b["Width"], width < 900, (b["Height"] ?? 0) > 150 else { continue }
    print(Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(width), Int(b["Height"] ?? 0)); break
}
