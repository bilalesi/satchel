import AppKit
import Carbon
import Foundation
import SwiftUI

/// A global shortcut: Carbon key code and modifier mask, plus the text shown to the user
/// (recorded from the key that was pressed, so it is right on any keyboard layout).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let standard = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥ Space")

    /// Builds a shortcut from a key-down event. Needs ⌘, ⌥ or ⌃: Shift alone would swallow capital letters.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var mask: UInt32 = 0
        var text = ""
        if flags.contains(.control) { mask |= UInt32(controlKey); text += "⌃" }
        if flags.contains(.option) { mask |= UInt32(optionKey); text += "⌥" }
        if flags.contains(.shift) { mask |= UInt32(shiftKey); text += "⇧" }
        if flags.contains(.command) { mask |= UInt32(cmdKey); text += "⌘" }
        keyCode = UInt32(event.keyCode)
        modifiers = mask
        label = text + " " + Self.keyName(event)
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"; case kVK_F4: return "F4"
        case kVK_F5: return "F5"; case kVK_F6: return "F6"; case kVK_F7: return "F7"; case kVK_F8: return "F8"
        case kVK_F9: return "F9"; case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// Global hotkey via Carbon `RegisterEventHotKey`. Needs no Accessibility permission.
/// The shortcut is whatever the user recorded; ⌥ Space is only the starting point, because other
/// launchers use it too. A refused registration (another app owns the shortcut) is reported.
@MainActor
final class HotKey: ObservableObject {
    static let shared = HotKey()
    static let shortcutKey = "hotKeyShortcut"

    var onPress: (() -> Void)?
    @Published private(set) var shortcut: Shortcut
    /// True when the system refused the current shortcut, most likely because another app owns it.
    @Published private(set) var conflict = false
    @Published private(set) var enabled = false
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var label: String { shortcut.label }

    private init() {
        shortcut = UserDefaults.standard.data(forKey: Self.shortcutKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        unregister()
        if on { conflict = !register(shortcut) } else { conflict = false }
    }

    /// Tries `new`; on refusal the previous shortcut stays active. Returns whether it was accepted.
    @discardableResult
    func set(_ new: Shortcut) -> Bool {
        unregister()
        if register(new) {
            shortcut = new
            conflict = false
            UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: Self.shortcutKey)
            return true
        }
        if enabled { conflict = !register(shortcut) }
        return false
    }

    func reset() { set(.standard) }

    /// While the user records a new combination the current one must not fire.
    func suspend() { unregister() }
    func resume() { if enabled { conflict = !register(shortcut) } }

    private func register(_ s: Shortcut) -> Bool {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // The callback is a C function pointer; it cannot capture, so it reaches the
            // singleton. Carbon delivers it on the main thread.
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { HotKey.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x564C5431) /* "VLT1" */, id: 1)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return false }
        ref = newRef
        return true
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// Click, then press the combination you want. Esc cancels, ⌫ goes back to ⌥ Space.
struct ShortcutRecorder: View {
    @ObservedObject var hotKey: HotKey
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                if hotKey.shortcut != .standard && !recording {
                    IconButton(.debugRestart, help: "Back to \(Shortcut.standard.label)", diameter: 24) { hotKey.reset(); message = nil }
                }
                Button(action: toggle) {
                    Text(recording ? "Press the shortcut…" : hotKey.shortcut.label)
                        .font(Theme.body.weight(.medium).monospaced())
                        .foregroundStyle(recording ? Color.accentColor : Color.primary)
                        .frame(minWidth: 130)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 28)
                        .background(Color.primary.opacity(recording ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                            .strokeBorder(recording ? Color.accentColor : Theme.hairline, lineWidth: recording ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel("Shortcut \(hotKey.shortcut.label). Click to record a new one.")
            }
            // One reserved line: the hint and any problem appear here without moving the rows below.
            Group {
                if let message { Text(message).foregroundStyle(.orange) }
                else if recording { Text("Esc to cancel · ⌫ for the default").foregroundStyle(.secondary) }
                else { Text(" ") }
            }
            .font(Theme.caption)
            .frame(height: 14)
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        message = nil
        recording = true
        hotKey.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // swallowed: nothing types into the window while recording
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { hotKey.resume() }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: stop()
        case kVK_Delete: stop(); hotKey.reset()
        default:
            guard let candidate = Shortcut(event: event) else {
                message = "Include ⌘, ⌥ or ⌃ so normal typing is not affected."
                return
            }
            stop()
            message = hotKey.set(candidate) ? nil : "\(candidate.label) is taken by another app or macOS. Pick another."
        }
    }
}
