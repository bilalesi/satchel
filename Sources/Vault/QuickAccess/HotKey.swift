import Carbon
import Foundation

/// Global hotkey via Carbon `RegisterEventHotKey`. Needs no Accessibility permission.
/// ⌥ Space is the default but other launchers (ChatGPT, Alfred, Raycast) use it too, so the
/// user can pick another and sees when the chosen one is taken.
@MainActor
final class HotKey: ObservableObject {
    static let shared = HotKey()

    enum Preset: String, CaseIterable, Identifiable {
        case optionSpace, controlOptionSpace, commandShiftSpace, controlOptionK
        var id: String { rawValue }
        var title: String {
            switch self {
            case .optionSpace: return "⌥ Space"
            case .controlOptionSpace: return "⌃⌥ Space"
            case .commandShiftSpace: return "⌘⇧ Space"
            case .controlOptionK: return "⌃⌥ K"
            }
        }
        fileprivate var keyCode: UInt32 { self == .controlOptionK ? UInt32(kVK_ANSI_K) : UInt32(kVK_Space) }
        fileprivate var modifiers: UInt32 {
            switch self {
            case .optionSpace: return UInt32(optionKey)
            case .controlOptionSpace, .controlOptionK: return UInt32(controlKey | optionKey)
            case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
            }
        }
    }

    static let presetKey = "hotKeyPreset"
    static var preset: Preset {
        UserDefaults.standard.string(forKey: presetKey).flatMap(Preset.init(rawValue:)) ?? .optionSpace
    }

    var onPress: (() -> Void)?
    /// True when the system refused the shortcut, most likely because another app owns it.
    @Published private(set) var conflict = false
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private init() {}

    func setEnabled(_ enabled: Bool) {
        unregister()
        if enabled { register(Self.preset) } else { conflict = false }
    }

    private func register(_ preset: Preset) {
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
        let status = RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        conflict = status != noErr
        if conflict { ref = nil }
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
