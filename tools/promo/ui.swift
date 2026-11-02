import AppKit
import CoreGraphics
import Foundation

// Smooth, human-looking pointer and keyboard driver for recording the demo.
//   ui move X Y [ms]   glide the pointer (points, top-left origin)
//   ui click | dclick | rclick
//   ui type "text"     typed with a natural rhythm
//   ui key CODE [cmd|ctrl|opt|shift ...]
//   ui scroll DY       pixels, negative = down
//   ui pos             print the pointer position
let a = CommandLine.arguments

// Safety: clicks, keys, typing and scrolling are only ever sent while the demo app is the front app.
// Anything else (another app came forward, the screen switched Space) aborts the run instead of
// clicking into someone's real work.
// The demo's process id comes from the caller (take.sh): the driver never guesses which app to click in.
let demoPID = Int32(ProcessInfo.processInfo.environment["DEMO_PID"] ?? "") ?? 0
func requireDemoInFront() {
    func front() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    guard demoPID > 0 else { FileHandle.standardError.write(Data("ABORT: DEMO_PID not set\n".utf8)); exit(3) }
    if front() != demoPID {
        // Something else came forward: bring the demo back and look again before acting.
        FileHandle.standardError.write(Data("note: front app was pid \(front() ?? 0); re-activating the demo\n".utf8))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(demoPID)) to true"]
        try? task.run(); task.waitUntilExit()
        usleep(1_200_000)
        // Kept for the take: a clean log means the whole recording shows only the demo.
        let line = "\(Date().timeIntervalSince1970) front-app-stolen\n"
        if let h = FileHandle(forWritingAtPath: "steal.log") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(toFile: "steal.log", atomically: true, encoding: .utf8) }
    }
    guard front() == demoPID else {
        FileHandle.standardError.write(Data("ABORT: front app is pid \(front() ?? 0), not the demo (\(demoPID))\n".utf8))
        exit(3)
    }
}

func pos() -> CGPoint { CGEvent(source: nil)!.location }
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func move(to p: CGPoint) { post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)) }

func glide(to end: CGPoint, ms: Double) {
    let start = pos()
    let steps = max(2, Int(ms / 8))
    let dx = end.x - start.x, dy = end.y - start.y
    let dist = hypot(dx, dy)
    // A gentle arc, as a hand makes, bigger for longer trips.
    let bend = min(40, dist * 0.08) * (dx >= 0 ? 1 : -1)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 // ease in-out
        let arc = sin(.pi * e) * bend
        move(to: CGPoint(x: start.x + dx * e - arc * dy / max(dist, 1), y: start.y + dy * e + arc * dx / max(dist, 1)))
        usleep(UInt32(ms / Double(steps) * 1000))
    }
    move(to: end)
}

func click(count: Int = 1, button: CGMouseButton = .left) {
    let p = pos()
    let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
    for n in 1...count {
        let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button)
        d?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        post(d); usleep(60000)
        let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button)
        u?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        post(u); usleep(90000)
    }
}

func flags(_ names: ArraySlice<String>) -> CGEventFlags {
    var f: CGEventFlags = []
    for n in names { switch n { case "cmd": f.insert(.maskCommand); case "ctrl": f.insert(.maskControl); case "opt": f.insert(.maskAlternate); case "shift": f.insert(.maskShift); default: break } }
    return f
}

switch a.count > 1 ? a[1] : "" {
case "move": glide(to: CGPoint(x: Double(a[2])!, y: Double(a[3])!), ms: a.count > 4 ? Double(a[4])! : 600)
case "click": requireDemoInFront(); click()
case "dclick": requireDemoInFront(); click(count: 2)
case "tclick": requireDemoInFront(); click(count: 3)
case "rclick": requireDemoInFront(); click(button: .right)
case "type":
    requireDemoInFront()
    for ch in a[2] {
        let s = String(ch).utf16.map { $0 }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: s.count, unicodeString: s)
            post(e)
        }
        usleep(UInt32.random(in: 55_000...115_000))
    }
case "key":
    requireDemoInFront()
    let code = CGKeyCode(a[2])!
    let f = flags(a[3...])
    for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); e?.flags = f; post(e); usleep(40000) }
case "scroll":
    requireDemoInFront()
    let steps = 12
    for _ in 0..<steps { post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(Double(a[2])! / Double(steps)), wheel2: 0, wheel3: 0)); usleep(16000) }
case "pos": let p = pos(); print(Int(p.x), Int(p.y))
default: print("usage: ui move|click|dclick|rclick|type|key|scroll|pos")
}
