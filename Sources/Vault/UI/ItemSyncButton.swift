import SwiftUI
import VaultCore

/// Whether one secret may sync at all, or stays on this Mac. (This sets permission; it does not run a sync.) Shown on the item screen whenever sync is
/// set up, so choosing what leaves the Mac is one click per secret (categories have their own switch in
/// Settings and in the category's menu). The choice is device-local, like the rest of the selection.
struct ItemSyncButton: View {
    @EnvironmentObject var sync: SyncCoordinator
    let overview: ItemOverview
    var labels: Bool
    @State private var anchor = AnchorBox()

    private var synced: Bool { sync.selection.includes(overview) }
    private var choice: SyncCoordinator.ItemSyncChoice { sync.choice(for: overview.id) }

    var body: some View {
        Button(action: open) {
            if labels {
                HStack(spacing: Theme.Space.s - 2) {
                    Icon(synced ? .cloudUpload : .lock, size: 13)
                    Text(synced ? "Sync allowed" : "Local only")
                    Icon(.chevronDown, size: 10).opacity(0.6)
                }
            } else {
                Icon(synced ? .cloudUpload : .lock, size: 15)
            }
        }
        .buttonStyle(labels ? AnyButtonStyle(PillButtonStyle(kind: .secondary)) : AnyButtonStyle(CircleButtonStyle(kind: .secondary, diameter: 30)))
        .background(AnchorReader(box: anchor))
        .tooltip(synced ? "This secret may sync. Click to change." : "This secret never leaves this Mac. Click to change.")
    }

    private func open() {
        guard let view = anchor.view else { return }
        func item(_ title: String, _ subtitle: String, _ icon: Codicon, _ value: SyncCoordinator.ItemSyncChoice) -> MenuItem {
            MenuItem(title: title, icon: icon, subtitle: subtitle, checked: choice == value) { sync.setChoice(value, for: overview.id) }
        }
        MenuPanelController.shared.show(items: [
            item("Follow the category", "Allowed when its category is", .sync, .followCategory),
            item("Allow sync", "Whatever its category says", .cloudUpload, .always),
            item("Keep on this Mac", "Never leaves this Mac", .lock, .never),
        ], anchor: view, minWidth: 250, alignTrailing: true)
    }
}

/// Lets one `buttonStyle` call take either of two style types.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
