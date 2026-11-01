import AppKit

enum Clipboard {
    /// nspasteboard.org convention: clipboard managers skip items carrying this type.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Copies `value`, marks it concealed, and clears it after `clearAfter` seconds unless
    /// the user has copied something else in the meantime (change count check).
    @MainActor
    static func copyConcealed(_ value: String, clearAfter: TimeInterval) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string, concealedType], owner: nil)
        pb.setString(value, forType: .string)
        pb.setString("", forType: concealedType)
        let count = pb.changeCount
        guard clearAfter > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(clearAfter))
            if NSPasteboard.general.changeCount == count {
                NSPasteboard.general.clearContents()
            }
        }
    }
}
