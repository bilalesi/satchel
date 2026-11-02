import SwiftUI

extension View {
    /// Liquid Glass on macOS 26 and newer; a material with a hairline before that. One helper so
    /// every floating or chrome surface (menu column, search field, cards, buttons) looks alike.
    /// `interactive` adds the system's press and hover response, for things you click.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline))
        }
    }
}

/// An empty strip that moves the window when dragged and zooms it on a double click: the part of
/// a custom title band that is not a button.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}
