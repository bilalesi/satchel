import SwiftUI

/// A rounded tile with a glyph on a colour: the identity of a workspace or a category.
struct LookTile: View {
    let iconName: String
    let colorName: String
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(CategoryStyle.color(named: colorName).gradient)
            .frame(width: size, height: size)
            .overlay(Icon(CategoryStyle.icon(named: iconName), size: (size * 0.52).rounded()).foregroundStyle(.white))
    }
}

/// Colour row and icon grid. Writes straight into the bindings, so the owner decides when to save.
struct StylePicker: View {
    @Binding var iconName: String
    @Binding var colorName: String

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 0) {
                ForEach(Array(CategoryStyle.palette.enumerated()), id: \.element.name) { index, entry in
                    Button { colorName = entry.name } label: {
                        Circle().fill(entry.color).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(colorName == entry.name ? 0.85 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help(entry.name.capitalized)
                    .accessibilityLabel(entry.name)
                    if index < CategoryStyle.palette.count - 1 { Spacer(minLength: 0) }
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(CategoryStyle.icons, id: \.self) { icon in
                    let selected = iconName == "\(icon)"
                    Button { iconName = "\(icon)" } label: {
                        Icon(icon, size: 14)
                            .frame(width: 28, height: 26)
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: Theme.rowRadius - 2, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityLabel("\(icon)")
                }
            }
        }
    }
}

/// Floating card with only the picker (used while typing a new category's name).
struct StylePickerCard: View {
    @Binding var iconName: String
    @Binding var colorName: String

    var body: some View {
        StylePicker(iconName: $iconName, colorName: $colorName)
            .padding(Theme.Space.l)
            .frame(width: 300)
    }
}

/// Floating card to create or edit a workspace or category: a live preview tile, the name, the look.
struct LookEditorCard: View {
    let title: String
    let confirmTitle: String
    let namePlaceholder: String
    var onConfirm: (_ name: String, _ iconName: String, _ colorName: String) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var iconName: String
    @State private var colorName: String
    @FocusState private var focused: Bool

    init(title: String, confirmTitle: String, namePlaceholder: String, name: String, iconName: String, colorName: String,
         onConfirm: @escaping (String, String, String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.namePlaceholder = namePlaceholder
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = State(initialValue: name)
        _iconName = State(initialValue: iconName)
        _colorName = State(initialValue: colorName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title).font(Theme.headline)
            HStack(spacing: Theme.Space.m) {
                LookTile(iconName: iconName, colorName: colorName, size: 36)
                TextField(namePlaceholder, text: $name)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(confirm)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: 36)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            }
            StylePicker(iconName: $iconName, colorName: $colorName)
            HStack(spacing: Theme.Space.s) {
                Spacer()
                PillButton("Cancel", icon: .close, kind: .ghost, compact: true, action: onCancel)
                PillButton(confirmTitle, icon: .check, kind: .primary, compact: true, action: confirm)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 300)
        .onAppear { focused = true }
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed, iconName, colorName)
    }
}
