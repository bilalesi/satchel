import AppKit
import SwiftUI
import VaultCore

/// Shown instead of the workspace once the trial is over without a licence. Two ways out: a licence key, or an
/// export of every item. Unlocking keeps working so the export is always possible; nothing is deleted or locked away.
struct TrialEndedView: View {
    @EnvironmentObject var session: VaultSession
    @ObservedObject private var licensing = Licensing.shared
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 96, height: 96)
                Text("Your trial has ended").font(Theme.title)
                Text("Your items are safe and still encrypted on this Mac. Enter a licence key to keep using \(AppIdentity.name), or export your items to take them elsewhere.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(width: 400)
                Card(padding: Theme.Space.m) {
                    TextField("SATCHEL-…", text: $key, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(2...4)
                        .onSubmit(activate)
                }
                .frame(width: 400)
                Text(error ?? "Checked on this Mac. Nothing is sent anywhere.")
                    .font(Theme.caption).foregroundStyle(error == nil ? Color.secondary : Color.red)
                HStack(spacing: Theme.Space.s) {
                    PillButton("Buy a licence", icon: .linkExternal) { NSWorkspace.shared.open(AppIdentity.purchaseURL) }
                    PillButton("Enter licence key", icon: .key, kind: .primary, action: activate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                PillButton("Export my items…", icon: .save, kind: .ghost, compact: true) { ItemExport.run(session) }
                    .padding(.top, Theme.Space.s)
            }
            .padding(Theme.Space.xxl)
        }
    }

    private func activate() {
        if licensing.activate(key) {
            key = ""; error = nil
            NotchHUD.shared.show(title: "Licence activated", detail: "Thank you for buying \(AppIdentity.name)")
        } else {
            error = "This key is not valid. Paste it exactly as you received it."
        }
    }
}

/// "Export my items": a warning first (the file is not encrypted), then a save panel, then the result.
@MainActor
enum ItemExport {
    static func run(_ session: VaultSession) {
        guard session.state == .unlocked else { return }
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "Export \(session.items.count) items without encryption?"
        warning.informativeText = "The file holds every password, key and note of “\(session.activeWorkspace.name)” in plain text. Anyone who opens it can read them. Keep it somewhere safe and delete it once you have imported it."
        warning.addButton(withTitle: "Export…")
        warning.addButton(withTitle: "Cancel")
        guard warning.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(AppIdentity.name) \(session.activeWorkspace.name) \(Date().formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try session.exportItems(to: url)
            if result.unreadable == 0 {
                NotchHUD.shared.show(title: "Exported \(result.written) items", detail: url.lastPathComponent)
            } else {
                let alert = NSAlert()
                alert.messageText = "Exported \(result.written) items"
                alert.informativeText = "\(result.unreadable) damaged items could not be read and are not in the file."
                alert.runModal()
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
