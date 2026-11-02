import AppKit

/// A thin, rounded scroll bar: a soft pill with no track and no arrows, light instead of near-black,
/// a little wider while the pointer is on it. It replaces the system look in every scroll view of
/// the app, so lists, panes, sheets and settings all scroll the same way.
final class RoundedScroller: NSScroller {
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 12 }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {} // no track

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let thickness: CGFloat = hovering ? 7 : 4
        let vertical = bounds.height >= bounds.width
        let pill = vertical
            ? NSRect(x: bounds.maxX - thickness - 3, y: knob.minY + 2, width: thickness, height: max(knob.height - 4, thickness))
            : NSRect(x: knob.minX + 2, y: bounds.maxY - thickness - 3, width: max(knob.width - 4, thickness), height: thickness)
        NSColor.labelColor.withAlphaComponent(hovering ? 0.34 : 0.2).setFill()
        NSBezierPath(roundedRect: pill, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

extension NSScrollView {
    /// Gives every scroll view of the app the rounded scroll bars. Done once, when a scroll view
    /// enters a window; the system's own scroll bar setting ("always show") is overridden because it
    /// brings back the wide track.
    @MainActor static func installRoundedScrollers() {
        let cls: AnyClass = NSScrollView.self
        let originalSel = #selector(NSScrollView.viewDidMoveToWindow)
        let styledSel = #selector(NSScrollView.satchel_viewDidMoveToWindow)
        guard let original = class_getInstanceMethod(cls, originalSel), let styled = class_getInstanceMethod(cls, styledSel) else { return }
        // NSScrollView inherits viewDidMoveToWindow from NSView. Exchanging the inherited method
        // would change it for every view in the app, so the override is first added to NSScrollView
        // alone, and the inherited implementation is kept behind the new selector.
        if class_addMethod(cls, originalSel, method_getImplementation(styled), method_getTypeEncoding(styled)) {
            class_replaceMethod(cls, styledSel, method_getImplementation(original), method_getTypeEncoding(original))
        } else {
            method_exchangeImplementations(original, styled)
        }
    }

    @objc fileprivate func satchel_viewDidMoveToWindow() {
        satchel_viewDidMoveToWindow() // the original, after the exchange
        guard window != nil else { return }
        scrollerStyle = .overlay
        if hasVerticalScroller, !(verticalScroller is RoundedScroller) { verticalScroller = RoundedScroller() }
        if hasHorizontalScroller, !(horizontalScroller is RoundedScroller) { horizontalScroller = RoundedScroller() }
    }
}
