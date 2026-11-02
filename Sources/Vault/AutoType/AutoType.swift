import AppKit
import ApplicationServices
import Carbon
import Foundation

enum AutoTypeError: LocalizedError {
    case notTrusted
    case noTargetApp
    case targetNotFrontmost(String)
    case noTextField(String)
    case secureInput(String?)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "Accessibility permission needed. Enable it in Settings → Security → Auto-type."
        case .noTargetApp: return "No app to type into. Open Quick Access while the target app is in front."
        case .targetNotFrontmost(let app): return "\(app) is no longer in front; nothing was typed."
        case .noTextField(let app): return "Click into a text field in \(app) first."
        case .secureInput(let app): return "Secure keyboard entry is on" + (app.map { " in \($0)" } ?? "") + "; keystrokes cannot be sent."
        case .failed(let why): return "Typing failed: \(why)"
        }
    }
}

/// Types text into the app in front. Accessibility first (sets the field's value and
/// verifies), synthesized Unicode keystrokes second (for Electron and other apps that
/// ignore AX writes). Refuses when the focused element is not a text field.
@MainActor
enum AutoType {
    enum Method: String { case accessibility, keystrokes }

    static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, "AXSecureTextField",
        kAXComboBoxRole as String, "AXSearchField",
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        // The constant is "AXTrustedCheckOptionPrompt"; spelled out to avoid the non-Sendable global.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns which method worked. The `text` string is not retained.
    static func type(_ text: String, into app: NSRunningApplication) async throws -> Method {
        guard isTrusted else { throw AutoTypeError.notTrusted }
        let name = app.localizedName ?? app.bundleIdentifier ?? "the app"
        app.activate()
        // Give the window server a moment to move focus back.
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw AutoTypeError.targetNotFrontmost(name)
        }

        let focused = focusedElement(of: app)
        guard let focused, isTextElement(focused) else { throw AutoTypeError.noTextField(name) }

        if setValueAndVerify(focused, text) { return .accessibility }

        if IsSecureEventInputEnabled() {
            throw AutoTypeError.secureInput(secureInputAppName())
        }
        // Keystrokes go to whatever is in front; the AX probing above may have taken a while.
        try postKeystrokes(text, onlyWhileFrontmost: app.processIdentifier, name: name)
        return .keystrokes
    }

    static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: Accessibility

    private static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func isTextElement(_ element: AXUIElement) -> Bool {
        if let role = attribute(element, kAXRoleAttribute as String) as? String, textRoles.contains(role) { return true }
        // Web content and custom controls: editable if the value is settable and it looks like text.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            if let role = attribute(element, kAXRoleAttribute as String) as? String,
               role == kAXStaticTextRole as String || role == "AXWebArea" || role == kAXGroupRole as String {
                return attribute(element, kAXSelectedTextRangeAttribute as String) != nil
            }
            return attribute(element, kAXValueAttribute as String) is String
        }
        return false
    }

    /// Sets AXValue and reads it back. Secure fields read back masked, so for those a
    /// successful set is accepted without comparison.
    private static func setValueAndVerify(_ element: AXUIElement, _ text: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success else { return false }
        let role = attribute(element, kAXRoleAttribute as String) as? String
        if role == "AXSecureTextField" { return true }
        guard let back = attribute(element, kAXValueAttribute as String) as? String else { return false }
        if back == text {
            // Nudge frameworks that watch for edits (React reads the DOM on input events).
            AXUIElementPerformAction(element, kAXConfirmAction as CFString)
            return true
        }
        // The write did not stick (Electron often echoes the old value): roll back if we changed it.
        return false
    }

    // MARK: Keystrokes

    /// Unicode keystrokes are layout-independent: every character arrives as typed.
    private static func postKeystrokes(_ text: String, onlyWhileFrontmost pid: pid_t, name: String) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw AutoTypeError.failed("no event source") }
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            // Re-checked before every chunk: if focus moved, stop instead of typing a secret elsewhere.
            guard isFrontmost(pid) else { throw AutoTypeError.targetNotFrontmost(name) }
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for keyDown in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                    throw AutoTypeError.failed("event creation")
                }
                ev.flags = []
                chunk.withUnsafeBufferPointer { ev.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                ev.post(tap: .cghidEventTap)
            }
            i += 16
            usleep(4000)
        }
    }

    /// Name of the process holding secure input, when the system exposes it.
    private static func secureInputAppName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let params = IORegistryEntryCreateCFProperty(entry, "HIDParameters" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let pid = params["kCGSSessionSecureInputPID"] as? pid_t else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
