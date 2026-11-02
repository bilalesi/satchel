import AppKit
import SwiftUI
import VaultCore

struct BrowserSettings: View {
    @State private var tick = 0
    @State private var message: String?

    var body: some View {
        SettingsPage(height: 520) {
            Section("Connection") { browsers }
            Section("Extension") { extensionFolder }
        }
    }

    @ViewBuilder
    private var browsers: some View {
        ForEach(NativeMessagingInstaller.Browser.allCases.filter(\.isInstalled)) { b in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title)
                    Text(status(b)).font(.callout).foregroundStyle(b.manifestPresent && !b.manifestStale ? .green : .secondary)
                }
                Spacer()
                if b.manifestPresent {
                    Button("Remove") { NativeMessagingInstaller.remove(b); tick += 1 }
                }
                Button(b.manifestPresent ? "Reinstall" : "Install") {
                    do { try NativeMessagingInstaller.install(b); message = nil } catch { message = error.localizedDescription }
                    tick += 1
                }
            }
            .id("\(b.rawValue)-\(tick)") // unique per row; a shared id made every row render the same browser
        }
        if NativeMessagingInstaller.Browser.allCases.filter(\.isInstalled).isEmpty {
            Text("No supported browser found (Dia, Arc, Chrome, Firefox).").foregroundStyle(.secondary)
        }
        bridgeStatus
        if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
                message = "Path copied. In the Load unpacked dialog press ⌘⇧G and paste it."
            }
            Button("Open in Finder") {
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
        Label(listening ? "Bridge listening" : "Bridge not running", systemImage: listening ? "dot.radiowaves.left.and.right" : "xmark.circle")
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
