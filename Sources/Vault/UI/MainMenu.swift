import SwiftUI
import VaultCore

/// One row of the main menu card: glyph, title, optional trailing hint (shortcut or state).
struct MenuCardRow: View {
    let icon: Codicon
    let title: String
    var trailing: String?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Icon(icon, size: 14).frame(width: 18)
                Text(title).font(Theme.body).lineLimit(1)
                Spacer(minLength: Theme.Space.m)
                if let trailing { Text(trailing).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 30)
            .background(hovering && enabled ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .pointerStyle(enabled ? .link : nil)
    }
}

/// The card under the avatar at the bottom left: who you are in, the few things you do
/// all day (sync, Quick Access, updates, lock) and the way into Settings.
struct MainMenuCard: View {
    struct Content {
        var workspaceName: String
        var statusText: String
        var shortcutLabel: String
        var updateText: String
        var syncAvailable: Bool
        var syncing: Bool
    }

    let content: Content
    let syncNow: () -> Void
    let quickAccess: () -> Void
    let checkForUpdates: () -> Void
    let workspaces: () -> Void
    let settings: () -> Void
    let lock: () -> Void
    let quit: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.m) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppIdentity.name).font(Theme.headline)
                    Text("\(content.workspaceName) · \(content.statusText)").font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            Divider().padding(.vertical, Theme.Space.xs)
            row(.sync, "Sync now", trailing: content.syncAvailable ? (content.syncing ? "Syncing…" : nil) : "Off", enabled: content.syncAvailable && !content.syncing, syncNow)
            row(.search, "Quick Access", trailing: content.shortcutLabel, quickAccess)
            row(.cloudDownload, "Check for updates", trailing: content.updateText, checkForUpdates)
            Divider().padding(.vertical, Theme.Space.xs)
            row(.layers, "Workspaces", workspaces)
            row(.settingsGear, "Settings", trailing: "⌘,", settings)
            Divider().padding(.vertical, Theme.Space.xs)
            row(.lock, "Lock \(AppIdentity.name)", trailing: "⇧⌘L", lock)
            row(.signOut, "Quit", trailing: "⌘Q", quit)
        }
        .padding(Theme.Space.xs + 2)
        .frame(width: 272)
    }

    private func row(_ icon: Codicon, _ title: String, trailing: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        MenuCardRow(icon: icon, title: title, trailing: trailing, enabled: enabled) { close(); action() }
    }
}
