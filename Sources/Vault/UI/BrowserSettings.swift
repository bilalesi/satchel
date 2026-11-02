import AppKit
import SwiftUI
import VaultCore

struct BrowserSettings: View {
    /// Manifest state per browser, re-read after each action. Rows keep a stable identity
    /// (the browser), so a click updates the row in place instead of rebuilding the list.
    @State private var states: [NativeMessagingInstaller.Browser: ManifestState] = [:]
    @State private var message: String?

    enum ManifestState { case missing, installed, stale }

    private var browsers: [NativeMessagingInstaller.Browser] {
        NativeMessagingInstaller.Browser.allCases.filter(\.isInstalled)
    }

    var body: some View {
        SettingsPage(height: 560) {
            Section("Connection") { connection }
            Section("Extension") { extensionFolder }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var next: [NativeMessagingInstaller.Browser: ManifestState] = [:]
        for b in browsers { next[b] = !b.manifestPresent ? .missing : (b.manifestStale ? .stale : .installed) }
        states = next
    }

    @ViewBuilder
    private var connection: some View {
        ForEach(browsers) { b in
            let state = states[b] ?? .missing
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title)
                    Text(statusText(state)).font(.callout)
                        .foregroundStyle(state == .installed ? Color.green : state == .stale ? Color.orange : Color.secondary)
                }
                Spacer()
                // Fixed trailing area: switching between one and two buttons never moves the row.
                HStack(spacing: Theme.Space.s) {
                    if state == .missing {
                        PillButton("Install", icon: .plug, kind: .primary, compact: true) { install(b) }
                    } else {
                        IconButton(.trash, help: "Remove \(b.title) connection", kind: .danger, diameter: 24) {
                            NativeMessagingInstaller.remove(b)
                            refresh()
                        }
                        PillButton("Reinstall", icon: .refresh, compact: true) { install(b) }
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
        }
        if browsers.isEmpty {
            Text("No supported browser found (Dia, Arc, Chrome, Firefox).").foregroundStyle(.secondary)
        }
        bridgeStatus
        if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
    }

    private func install(_ b: NativeMessagingInstaller.Browser) {
        do { try NativeMessagingInstaller.install(b); message = nil } catch { message = error.localizedDescription }
        refresh()
    }

    private func statusText(_ state: ManifestState) -> String {
        switch state {
        case .missing: return "Not connected"
        case .installed: return "Connected"
        case .stale: return "Points at another copy of the app"
        }
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            IconButton(.copy, help: "Copy path", kind: .secondary, diameter: 26) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
                message = "Path copied. In the Load unpacked dialog press ⌘⇧G and paste it."
            }
            IconButton(.folderOpened, help: "Open in Finder", kind: .secondary, diameter: 26) {
                if !NSWorkspace.shared.open(url) { message = "Finder could not open \(url.path)" }
            }
        }
    }

    private func status(_ b: NativeMessagingInstaller.Browser) -> String {
        if !b.manifestPresent { return "Host manifest not installed" }
        if b.manifestStale { return "Host manifest points at another copy of the app" }
        return "Host manifest installed"
    }

    @ViewBuilder
    private var bridgeStatus: some View {
        let listening = FileManager.default.fileExists(atPath: AppIdentity.bridgeSocketURL.path)
        Label { Text(listening ? "Bridge listening" : "Bridge not running") } icon: { Icon(listening ? .radioTower : .error, size: 13) }
            .font(.callout).foregroundStyle(listening ? .green : .red)
    }

    @ViewBuilder
    private var extensionFolder: some View {
        if let dist = BrowserIntegration.extensionDistURL, FileManager.default.fileExists(atPath: dist.path) {
            folderRow("Dia, Arc, Chrome", dist.appendingPathComponent("chromium", isDirectory: true))
            folderRow("Firefox", dist.appendingPathComponent("firefox", isDirectory: true))
            Text("Extensions page → Developer mode → Load unpacked → ⌘⇧G and paste the path. Firefox: about:debugging → Load Temporary Add-on → manifest.json.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Extension files are not inside this build. Run scripts/bundle.sh.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
