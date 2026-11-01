import AppKit
import SwiftUI
import VaultCore

struct BrowserSettings: View {
    @State private var tick = 0
    @State private var message: String?

    var body: some View {
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
            .id(tick)
        }
        if NativeMessagingInstaller.Browser.allCases.filter(\.isInstalled).isEmpty {
            Text("No supported browser found (Dia, Arc, Chrome, Firefox).").foregroundStyle(.secondary)
        }
        bridgeStatus
        extensionFolder
        if let message { Text(message).foregroundStyle(.red) }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Load the extension").font(.callout.weight(.semibold))
                Text("Dia, Arc, Chrome: open the Extensions page, turn on Developer mode, choose “Load unpacked” and pick the chromium folder. Firefox: about:debugging → This Firefox → Load Temporary Add-on → pick manifest.json in the firefox folder (or sign it as unlisted on addons.mozilla.org for a permanent install).")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(dist.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([dist.appendingPathComponent("chromium")]) }
                }
            }
        } else {
            Text("Extension files are not inside this build. Run scripts/bundle.sh.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
