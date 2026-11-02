import SwiftUI
import VaultCore

/// Floating cards to create and edit workspaces. One place, used by the rail, the lock screen
/// and Settings.
@MainActor
enum WorkspaceCards {
    static func create(anchor: NSView, placement: MenuPanelController.Placement, session: VaultSession) {
        let count = session.workspaces.count
        MenuPanelController.shared.showContent(anchor: anchor, placement: placement) { close in
            LookEditorCard(title: "New workspace", confirmTitle: "Create", namePlaceholder: "Work, Home, Client…",
                           name: "", iconName: "briefcase", colorName: CategoryStyle.palette[count % CategoryStyle.palette.count].name,
                           onConfirm: { name, icon, color in close(); session.addWorkspace(named: name, iconName: icon, colorName: color) },
                           onCancel: close)
        }
    }

    static func edit(_ workspace: Workspace, anchor: NSView, placement: MenuPanelController.Placement, session: VaultSession) {
        MenuPanelController.shared.showContent(anchor: anchor, placement: placement) { close in
            LookEditorCard(title: "Edit workspace", confirmTitle: "Save", namePlaceholder: "Name",
                           name: workspace.name, iconName: workspace.look.icon, colorName: workspace.look.color,
                           onConfirm: { name, icon, color in close(); session.updateWorkspace(workspace.id, name: name, iconName: icon, colorName: color) },
                           onCancel: close)
        }
    }
}

/// The vertical strip of workspaces at the left edge: one tile each, the open one marked.
/// Switching is one click, and every workspace keeps its own colour and glyph, so the one you are
/// in is recognisable at a glance.
struct WorkspaceRail: View {
    @EnvironmentObject var session: VaultSession
    @State private var removing: Workspace?
    @State private var addAnchor = AnchorBox()

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ForEach(session.workspaces) { ws in
                RailTile(workspace: ws, onRemove: { removing = ws })
            }
            Button {
                guard let view = addAnchor.view else { return }
                WorkspaceCards.create(anchor: view, placement: .trailing, session: session)
            } label: {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 40, height: 40)
                    .overlay(Icon(.add, size: 14).foregroundStyle(.secondary))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .background(AnchorReader(box: addAnchor))
            .disabled(session.busy)
            .help("New workspace")
            .accessibilityLabel("New workspace")
            Spacer()
        }
        .padding(.top, 60) // below the traffic lights, level with the search field
        .padding(.bottom, Theme.Space.m)
        .frame(width: 60)
        .frame(maxHeight: .infinity)
        .background(Theme.canvas.overlay(Color.primary.opacity(0.04)))
        .overlay(alignment: .trailing) { Divider() }
        .ignoresSafeArea(edges: .top) // the strip runs up under the window's title bar
        .confirmationDialog("Remove “\(removing?.name ?? "")” from this Mac?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) { if let removing { session.removeWorkspace(removing.id) } }
        } message: { Text("Its vault folder goes to the Trash. Copies on your sync target and other Macs are not touched.") }
    }
}

private struct RailTile: View {
    @EnvironmentObject var session: VaultSession
    let workspace: Workspace
    let onRemove: () -> Void
    @State private var anchor = AnchorBox()
    @State private var hovering = false

    private var active: Bool { workspace.id == session.activeWorkspaceID }

    var body: some View {
        Button { session.switchWorkspace(workspace.id) } label: {
            LookTile(iconName: workspace.look.icon, colorName: workspace.look.color, size: 40)
                .opacity(active || hovering ? 1 : 0.62)
                .overlay(alignment: .leading) {
                    // The marker sits in the rail's margin, outside the tile.
                    Capsule().fill(Color.primary.opacity(0.8)).frame(width: 3, height: active ? 22 : 0).offset(x: -7)
                }
                .animation(.easeOut(duration: 0.15), value: active)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .background(AnchorReader(box: anchor))
        .disabled(session.busy)
        .help(workspace.name)
        .accessibilityLabel(workspace.name)
        .accessibilityAddTraits(active ? .isSelected : [])
        .contextMenu {
            Button("Rename and change look…") {
                if let view = anchor.view { WorkspaceCards.edit(workspace, anchor: view, placement: .trailing, session: session) }
            }
            if session.workspaces.count > 1 {
                Divider()
                Button("Remove from this Mac…", role: .destructive, action: onRemove)
            }
        }
    }
}

/// Lock screen: the workspaces as larger tiles with names, like the user picker of the macOS
/// login window. Choose which vault to unlock.
struct WorkspaceStrip: View {
    @EnvironmentObject var session: VaultSession
    @State private var addAnchor = AnchorBox()

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            ForEach(session.workspaces) { ws in
                let active = ws.id == session.activeWorkspaceID
                Button { session.switchWorkspace(ws.id) } label: {
                    VStack(spacing: Theme.Space.xs + 2) {
                        LookTile(iconName: ws.look.icon, colorName: ws.look.color, size: 44)
                            .overlay(RoundedRectangle(cornerRadius: 44 * 0.28 + 4, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: active ? 2 : 0).padding(-4))
                        Text(ws.name).font(Theme.caption).lineLimit(1)
                            .foregroundStyle(active ? Color.primary : Color.secondary)
                            .frame(width: 64)
                    }
                    .opacity(active ? 1 : 0.7)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .disabled(session.busy)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            Button {
                guard let view = addAnchor.view else { return }
                WorkspaceCards.create(anchor: view, placement: .below, session: session)
            } label: {
                VStack(spacing: Theme.Space.xs + 2) {
                    RoundedRectangle(cornerRadius: 44 * 0.28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 44, height: 44)
                        .overlay(Icon(.add, size: 15).foregroundStyle(.secondary))
                    Text("New").font(Theme.caption).foregroundStyle(.secondary).frame(width: 64)
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .background(AnchorReader(box: addAnchor))
            .disabled(session.busy)
        }
    }
}

/// Settings → Vault: the workspaces of this Mac. The tile opens the same card as the rail.
struct WorkspaceManager: View {
    @EnvironmentObject var session: VaultSession
    @State private var removing: Workspace?
    @State private var addAnchor = AnchorBox()

    var body: some View {
        Section("Workspaces") {
            ForEach(session.workspaces) { (ws: Workspace) in
                WorkspaceRow(workspace: ws, onRemove: { removing = ws })
            }
            HStack {
                Spacer()
                PillButton("Add workspace", icon: .add, compact: true) {
                    if let view = addAnchor.view { WorkspaceCards.create(anchor: view, placement: .below, session: session) }
                }
                .background(AnchorReader(box: addAnchor))
                .disabled(session.busy)
            }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from this Mac?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) { if let removing { session.removeWorkspace(removing.id) } }
        } message: { Text("Its vault folder goes to the Trash. Copies on your sync target and other Macs are not touched.") }
    }
}

private struct WorkspaceRow: View {
    @EnvironmentObject var session: VaultSession
    let workspace: Workspace
    let onRemove: () -> Void
    @State private var anchor = AnchorBox()

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button {
                if let view = anchor.view { WorkspaceCards.edit(workspace, anchor: view, placement: .below, session: session) }
            } label: { LookTile(iconName: workspace.look.icon, colorName: workspace.look.color, size: 26) }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .background(AnchorReader(box: anchor))
                .help("Rename and change look")
            Text(workspace.name).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            if workspace.id == session.activeWorkspaceID {
                Text("Open").font(Theme.caption).foregroundStyle(.secondary)
            } else {
                PillButton("Open", icon: .arrowRight, compact: true) { session.switchWorkspace(workspace.id) }
                    .disabled(session.busy)
            }
            if session.workspaces.count > 1 {
                IconButton(.trash, help: "Remove from this Mac", diameter: 24, action: onRemove)
                    .disabled(session.busy)
            }
        }
    }
}
