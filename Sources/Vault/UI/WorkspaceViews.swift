import SwiftUI
import VaultCore

/// Pill that names the active workspace and switches between them. Used in the sidebar and on
/// the lock screen, so you can pick which vault to unlock.
struct WorkspaceSwitcher: View {
    @EnvironmentObject var session: VaultSession
    @State private var creating = false

    var body: some View {
        MenuButton(title: session.activeWorkspace.name, icon: .layers, compact: true) {
            var items = session.workspaces.map { ws in
                MenuItem(title: ws.name, icon: .layers, checked: ws.id == session.activeWorkspaceID) { session.switchWorkspace(ws.id) }
            }
            items.append(MenuItem(title: "New workspace…", icon: .add) { creating = true })
            items.append(MenuItem(title: "Manage workspaces…", icon: .settingsGear) {
                UserDefaults.standard.set(SettingsView.Tab.vault.rawValue, forKey: "settingsTab")
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            })
            return items
        }
        .help("Switch workspace")
        .disabled(session.busy)
        .sheet(isPresented: $creating) { NewWorkspaceSheet() }
    }
}

struct NewWorkspaceSheet: View {
    @EnvironmentObject var session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("New workspace").font(Theme.headline)
            Text("A workspace is a separate vault with its own master password, categories and sync. Use one for work and one for home, for example.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $name, prompt: Text("Work"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack(spacing: Theme.Space.s) {
                Spacer()
                PillButton("Cancel", icon: .close, kind: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
                PillButton("Create", icon: .add, kind: .primary, action: create).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 380)
        .excludedFromCapture()
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        session.addWorkspace(named: name)
        dismiss()
    }
}

/// Settings → Vault: rename, add and remove workspaces.
struct WorkspaceManager: View {
    @EnvironmentObject var session: VaultSession
    @State private var removing: Workspace?
    @State private var adding = false

    var body: some View {
        Section("Workspaces") {
            ForEach(session.workspaces) { (ws: Workspace) in
                WorkspaceRow(workspace: ws, onRemove: { removing = ws })
            }
            HStack {
                Spacer()
                PillButton("Add workspace", icon: .add, compact: true) { adding = true }
            }
        }
        .sheet(isPresented: $adding) { NewWorkspaceSheet() }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from this Mac?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) { if let removing { session.removeWorkspace(removing.id) } }
        } message: { Text("Its vault folder goes to the Trash. Copies on your sync target and other Macs are not touched.") }
    }
}

private struct WorkspaceRow: View {
    @EnvironmentObject var session: VaultSession
    let workspace: Workspace
    let onRemove: () -> Void
    @State private var name: String

    init(workspace: Workspace, onRemove: @escaping () -> Void) {
        self.workspace = workspace
        self.onRemove = onRemove
        _name = State(initialValue: workspace.name)
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Icon(.layers, size: 13).foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit { session.renameWorkspace(workspace.id, to: name) }
                .onChange(of: name) { _, new in session.renameWorkspace(workspace.id, to: new) }
            if workspace.id == session.activeWorkspaceID {
                Text("Open").font(Theme.caption).foregroundStyle(.secondary)
            } else {
                PillButton("Open", icon: .arrowRight, compact: true) { session.switchWorkspace(workspace.id) }
            }
            if session.workspaces.count > 1 {
                IconButton(.trash, help: "Remove from this Mac", diameter: 24, action: onRemove)
            }
        }
    }
}
