import AppKit
import SwiftUI

// MARK: - Icon

/// A Codicon glyph in a fixed square. The fixed frame is the point: swapping icons
/// (copy → check, eye → eye-closed) never changes layout.
struct Icon: View {
    let icon: Codicon
    var size: CGFloat = 14

    init(_ icon: Codicon, size: CGFloat = 14) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Text(String(icon.character))
            .font(.custom("codicon", fixedSize: size))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Codicon {
    /// Template image for APIs that need an Image (Settings tab items, menu bar).
    func image(size: CGFloat = 16) -> NSImage {
        let glyph = String(character)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let font = NSFont(name: "codicon", size: size) ?? .systemFont(ofSize: size)
            let str = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.black])
            let b = str.size()
            str.draw(at: NSPoint(x: (rect.width - b.width) / 2, y: (rect.height - b.height) / 2))
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Buttons

enum PillKind {
    case primary, secondary, danger, ghost
}

/// Fully rounded button. Fixed height and `fixedSize()` so neighbours never squeeze or
/// wrap it; pressed feedback is a transform (scale), which never triggers layout.
struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: PillKind
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(compact ? Theme.caption.weight(.medium) : Theme.body.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? Theme.Space.m - 2 : Theme.Space.l - 2)
            .frame(height: compact ? 24 : 30)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering = enabled && $0 }
            .pointerStyle(enabled ? .link : nil) // hand cursor on every pill
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .danger: return .red
        case .secondary: return .primary
        case .ghost: return hovering ? .primary : .secondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Color.accentColor.opacity(hovering ? 0.85 : 1)
        case .danger: return Color.red.opacity(hovering ? 0.18 : 0.10)
        case .secondary: return Color.primary.opacity(hovering ? 0.10 : 0.06)
        case .ghost: return Color.primary.opacity(hovering ? 0.07 : 0)
        }
    }

    private var border: Color {
        kind == .secondary ? Theme.hairline : .clear
    }
}

/// Circular icon-only button with the same states as PillButtonStyle.
struct CircleButtonStyle: ButtonStyle {
    var kind: PillKind = .ghost
    var diameter: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, kind: kind, diameter: diameter)
    }
}

private struct CircleBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: PillKind
    let diameter: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .foregroundStyle(kind == .danger ? Color.red : (hovering ? Color.primary : Color.secondary))
            .background(Circle().fill(fill))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering = enabled && $0 }
            .pointerStyle(enabled ? .link : nil)
    }

    private var fill: Color {
        switch kind {
        case .danger: return Color.red.opacity(hovering ? 0.18 : 0.10)
        case .secondary: return Color.primary.opacity(hovering ? 0.10 : 0.06)
        default: return Color.primary.opacity(hovering ? 0.08 : 0)
        }
    }
}

/// The standard button: capsule, icon + title.
struct PillButton: View {
    let title: String
    let icon: Codicon
    var kind: PillKind = .secondary
    var compact = false
    let action: () -> Void

    init(_ title: String, icon: Codicon, kind: PillKind = .secondary, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s - 2) {
                Icon(icon, size: compact ? 12 : 13)
                Text(title)
            }
        }
        .buttonStyle(PillButtonStyle(kind: kind, compact: compact))
    }
}

/// Icon-only circular button. `help` is both the tooltip and the accessibility name.
struct IconButton: View {
    let icon: Codicon
    let help: String
    var kind: PillKind = .ghost
    var diameter: CGFloat = 28
    let action: () -> Void

    init(_ icon: Codicon, help: String, kind: PillKind = .ghost, diameter: CGFloat = 28, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.kind = kind
        self.diameter = diameter
        self.action = action
    }

    var body: some View {
        Button(action: action) { Icon(icon, size: (diameter * 0.5).rounded()) }
            .buttonStyle(CircleButtonStyle(kind: kind, diameter: diameter))
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: - Password input

/// A password field with an eye that shows what was typed, so a new master password can be
/// checked before it becomes the only key to the vault. `revealed` is shared by the fields of one
/// form, so one eye reveals or hides them together.
struct PasswordInput: View {
    let title: String
    @Binding var text: String
    @Binding var revealed: Bool
    var autofocus = false
    /// Right-aligned inside forms, where every other value sits at the right edge.
    var alignment: TextAlignment = .leading
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if revealed { TextField("", text: $text, prompt: Text(title)) } else { SecureField("", text: $text, prompt: Text(title)) }
            }
            .labelsHidden()
            .multilineTextAlignment(alignment)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit(onSubmit)
            IconButton(revealed ? .eyeClosed : .eye, help: revealed ? "Hide password" : "Show password", diameter: 24) {
                let hadFocus = focused
                revealed.toggle()
                // The field is replaced by the other kind; keep the caret where the user was typing.
                if hadFocus { DispatchQueue.main.async { focused = true } }
            }
        }
        .onAppear { if autofocus { focused = true } }
    }
}

// MARK: - Segmented control

struct CapsuleSegmented<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        let icon: Codicon
    }

    @Binding var selection: Value
    let options: [Option]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    HStack(spacing: Theme.Space.s - 2) {
                        Icon(option.icon, size: 12)
                        Text(option.title)
                    }
                    .font(Theme.caption.weight(.medium))
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: 26)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .background {
                        if selected {
                            Capsule().fill(Theme.card)
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Floating menu (custom dropdown)

struct MenuItem: Identifiable {
    let id = UUID()
    var title: String
    var icon: Codicon? = nil
    var image: NSImage? = nil
    var subtitle: String? = nil
    var checked = false
    var action: () -> Void
}

/// Holds the AppKit view under a trigger so the menu can be placed in screen coordinates.
final class AnchorBox {
    weak var view: NSView?
}

struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

/// Shows a borderless panel under an anchor view. A child window of the anchor's window:
/// it floats above everything (no clipping by Forms or scroll views), moves with the
/// window, and closes on selection, Escape, or a click elsewhere.
@MainActor
final class MenuPanelController {
    static let shared = MenuPanelController()
    private var panel: MenuPanel?
    private var dismissHandler: (() -> Void)?

    /// `alignTrailing`: the card's right edge lines up with the anchor's (a button at the window's right side).
    func show(items: [MenuItem], anchor: NSView, minWidth: CGFloat, alignTrailing: Bool = false) {
        close()
        guard let window = anchor.window, !items.isEmpty else { return }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let showsChecks = items.contains(where: \.checked)
        let host = NSHostingView(rootView: MenuList(items: items, showsChecks: showsChecks, minWidth: minWidth) { [weak self] in
            self?.close()
        })
        let fitting = host.fittingSize
        let size = NSSize(width: max(minWidth, fitting.width), height: min(fitting.height, 380))
        present(host, size: size, anchorRect: anchorRect, window: window,
                xOffset: alignTrailing ? anchorRect.width - size.width : 0)
    }

    /// A small text card under an anchor (the "i" explanations). Same look and closing
    /// rules as the menus: Escape, selection elsewhere, or focus loss.
    func showText(_ text: String, anchor: NSView, width: CGFloat = 288) {
        close()
        guard let window = anchor.window else { return }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let host = NSHostingView(rootView: InfoCard(text: text, width: width) { [weak self] in self?.close() })
        let size = host.fittingSize
        present(host, size: size, anchorRect: anchorRect, window: window, xOffset: -12)
    }

    enum Placement { case below, above, trailing }

    /// Any SwiftUI content in the same floating card as the menus (the main menu, the icon and
    /// colour picker). `content` gets a closure that closes the card. The card keeps the app's
    /// environment only through what the caller passes in: it lives in its own window.
    func showContent<Content: View>(anchor: NSView, placement: Placement = .below, onDismiss: (() -> Void)? = nil,
                                    @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        close()
        guard let window = anchor.window else { return }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let body = content { [weak self] in self?.close() }
        dismissHandler = onDismiss
        let host = NSHostingView(rootView: body)
        let size = host.fittingSize
        present(host, size: size, anchorRect: anchorRect, window: window, xOffset: 0, placement: placement)
    }

    private func present(_ host: NSView, size: NSSize, anchorRect: NSRect, window: NSWindow, xOffset: CGFloat,
                         placement: Placement = .below) {
        var origin: NSPoint
        switch placement {
        case .below: origin = NSPoint(x: anchorRect.minX + xOffset, y: anchorRect.minY - size.height - 4)
        case .above: origin = NSPoint(x: anchorRect.minX + xOffset, y: anchorRect.maxY + 4)
        case .trailing: origin = NSPoint(x: anchorRect.maxX + 8, y: anchorRect.maxY - size.height)
        }
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if placement == .below, origin.y < visible.minY { origin.y = anchorRect.maxY + 4 } // flip above when no room below
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        let p = MenuPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // The window shadow follows the blur view's rounded mask, as it does for system menus.
        p.hasShadow = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.contentView = Self.cardView(for: host, size: size)
        p.onDismiss = { [weak self] in self?.close() }
        AppSettings.applyCapturePolicy(to: p)
        window.addChildWindow(p, ordered: .above)
        p.makeKeyAndOrderFront(nil)
        panel = p
        // The shadow is computed from the first frame; recompute it once the content has drawn.
        DispatchQueue.main.async { [weak p] in p?.invalidateShadow() }
    }

    /// A translucent rounded card the way AppKit makes non-rectangular blur windows: a visual-effect view
    /// whose `maskImage` is a stretchable rounded rectangle, so the blur, the window shadow and the corners
    /// all follow the same shape. SwiftUI's glass drawn inside a pop-up window paints a rectangle the size
    /// of the window instead. A hairline on top gives the edge.
    private static func cardView(for host: NSView, size: NSSize) -> NSView {
        let bounds = NSRect(origin: .zero, size: size)
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = roundedMask(radius: Theme.radius)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        let edge = EdgeView(frame: bounds, radius: Theme.radius)
        edge.autoresizingMask = [.width, .height]
        blur.addSubview(edge)
        return blur
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private final class EdgeView: NSView {
        init(frame: NSRect, radius: CGFloat) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = radius
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidChangeEffectiveAppearance() { layer?.borderColor = NSColor.separatorColor.cgColor }
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        let handler = dismissHandler
        dismissHandler = nil
        handler?()
    }
}

final class MenuPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

/// The look every floating card shares: Liquid Glass (a material before macOS 26), a hairline edge so the
/// card stands out from a white window, and a soft shadow. The transparent `inset` around the card is where
/// the shadow is drawn; the window is that much larger than the card.
private struct MenuList: View {
    let items: [MenuItem]
    let showsChecks: Bool
    let minWidth: CGFloat
    let onDone: () -> Void
    @State private var highlighted: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { row($0) }
            }
            .padding(Theme.Space.xs + 2)
        }
        .scrollIndicators(.automatic)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            if let item = items.first(where: { $0.id == highlighted }) { activate(item) }
            return .handled
        }
        .onKeyPress(.escape) { onDone(); return .handled }
        .onAppear {
            focused = true
            highlighted = items.first(where: \.checked)?.id ?? items.first?.id
        }
    }

    /// A real Button, so mouse clicks, Return and accessibility "press" all activate it.
    private func row(_ item: MenuItem) -> some View {
        let isOn = highlighted == item.id
        return Button { activate(item) } label: { rowLabel(item, isOn: isOn) }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { if $0 { highlighted = item.id } }
    }

    private func rowLabel(_ item: MenuItem, isOn: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if showsChecks {
                Icon(.check, size: 12).opacity(item.checked ? 1 : 0)
            }
            if let image = item.image {
                Image(nsImage: image).resizable().frame(width: 18, height: 18)
            } else if let icon = item.icon {
                Icon(icon, size: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Theme.body).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(Theme.caption).opacity(0.7).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.l)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: item.subtitle == nil ? 28 : 38)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background(isOn ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == highlighted } ?? -1
        highlighted = items[max(0, min(items.count - 1, i + delta))].id
    }

    private func activate(_ item: MenuItem) {
        onDone()
        item.action()
    }
}

/// A value picker: pill trigger showing the current choice, custom floating menu.
struct Dropdown<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var icon: Codicon? = nil
        var subtitle: String? = nil
    }

    @Binding var selection: Value
    let options: [Option]
    var minWidth: CGFloat = 170
    @State private var anchor = AnchorBox()

    private var current: Option? { options.first { $0.value == selection } }

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Space.s) {
                if let icon = current?.icon { Icon(icon, size: 13) }
                Text(current?.title ?? "Choose…").lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                Icon(.chevronDown, size: 12).foregroundStyle(.secondary)
            }
            .frame(minWidth: minWidth - 28, alignment: .leading)
        }
        .buttonStyle(PillButtonStyle(kind: .secondary))
        .background(AnchorReader(box: anchor))
        .accessibilityValue(current?.title ?? "")
    }

    private func open() {
        guard let view = anchor.view else { return }
        let binding = $selection
        let items = options.map { option in
            MenuItem(title: option.title, icon: option.icon, subtitle: option.subtitle,
                     checked: option.value == selection) { binding.wrappedValue = option.value }
        }
        MenuPanelController.shared.show(items: items, anchor: view, minWidth: view.bounds.width)
    }
}

/// An action menu with a pill trigger ("New", "Link a running app").
struct MenuButton: View {
    let title: String
    let icon: Codicon
    var kind: PillKind = .secondary
    var compact = false
    var alignTrailing = false
    let items: () -> [MenuItem]
    @State private var anchor = AnchorBox()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            MenuPanelController.shared.show(items: items(), anchor: view, minWidth: max(view.bounds.width, 200),
                                            alignTrailing: alignTrailing)
        } label: {
            HStack(spacing: Theme.Space.s - 2) {
                Icon(icon, size: compact ? 12 : 13)
                Text(title)
                Icon(.chevronDown, size: 10).opacity(0.6)
            }
        }
        .buttonStyle(PillButtonStyle(kind: kind, compact: compact))
        .background(AnchorReader(box: anchor))
    }
}

/// Toolbar button that opens the custom menu. Uses the system toolbar style (macOS 26
/// draws its own glass capsule), so no custom pill is nested inside the system one.
struct ToolbarMenuButton: View {
    let title: String
    let icon: Codicon
    let items: () -> [MenuItem]
    @State private var anchor = AnchorBox()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            MenuPanelController.shared.show(items: items(), anchor: view, minWidth: max(view.bounds.width, 200))
        } label: {
            Label { Text(title) } icon: { Image(nsImage: icon.image(size: 15)) }
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, Theme.Space.xs) // room inside the system capsule on both sides
        }
        .background(AnchorReader(box: anchor))
        .pointerStyle(.link)
    }
}

// MARK: - Info tip

/// Small "i" that explains a field. Click opens a floating card (same panel as the dropdowns).
struct InfoTip: View {
    let text: String
    @State private var anchor = AnchorBox()
    @State private var hovering = false

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            MenuPanelController.shared.showText(text, anchor: view)
        } label: {
            Icon(.info, size: 12)
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AnchorReader(box: anchor))
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .tooltip("What is this?")
        .accessibilityLabel("What is this?")
        .accessibilityHint(text)
    }
}

struct InfoCard: View {
    let text: String
    let width: CGFloat
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Icon(.info, size: 14).foregroundStyle(Color.accentColor).padding(.top, 1)
            Text(text).font(Theme.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(width: width, alignment: .leading)
        .onTapGesture(perform: onDone)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let icon: Codicon
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Icon(icon, size: 32).foregroundStyle(.tertiary)
            Text(title).font(Theme.headline).foregroundStyle(.secondary)
            if let message { Text(message).font(Theme.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tooltip

/// A tooltip that does not depend on SwiftUI's `.help`: that one does not show on controls that also set
/// `.pointerStyle(.link)`. This is an AppKit tooltip on a transparent overlay that ignores clicks.
private struct ToolTipOverlay: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView {
        let v = PassThroughView()
        v.toolTip = text
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.toolTip = text }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func tooltip(_ text: String) -> some View { overlay(ToolTipOverlay(text: text)) }
}
