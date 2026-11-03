import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

enum AuthenticatorHelp {
    static let setup = "The 6-digit codes you read in Google Authenticator or Microsoft Authenticator come from a secret key. When you turn on two-step verification for a site, it shows a QR code and, under “Can't scan?”, the same key as text. Paste the text here, or take a screenshot of the QR code (⌃⌘⇧4) and click Paste QR image. Satchel then shows the same codes, ready to copy. Compare the first code with the site before you remove the old app."
    static let stored = "The secret behind your 6-digit codes. Anyone who has it can make your codes, so keep it hidden. You only need to copy it to set up another authenticator app."
}

/// The authenticator key of a login: type or paste the text key (or an otpauth:// link), or read it
/// from a QR code image: pasted from the clipboard (a screenshot), chosen from a file, or dropped
/// on the field. The code it produces is shown right away so it can be compared with the site's.
struct AuthenticatorKeyField: View {
    @Binding var text: String
    /// Called with the service and account found in a QR code, so an empty title can be filled in.
    var onImported: (TOTP.Label?) -> Void

    @EnvironmentObject private var session: VaultSession
    @State private var revealed = false
    @State private var copiedCode = false
    @State private var status: Status?
    @State private var dropping = false

    private struct Status { var text: String; var good: Bool }

    var body: some View {
        // Two form rows, like every other field: the key itself, then the ways to fill it in.
        Group {
            HStack(spacing: Theme.Space.xs) {
                Text("Authenticator key")
                InfoTip(text: AuthenticatorHelp.setup)
                Spacer(minLength: Theme.Space.l)
                PasswordInput(title: "Key or otpauth:// link", text: $text, revealed: $revealed, alignment: .trailing)
                    .font(Theme.body.monospaced())
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    PillButton("Paste QR image", icon: .clippy, compact: true, action: pasteImage)
                        .help("Take a screenshot of the QR code with ⌃⌘⇧4, then click here")
                    PillButton("Choose image…", icon: .fileMedia, compact: true, action: chooseImage)
                    Spacer(minLength: 0)
                }
                preview
            }
            .padding(.vertical, Theme.Space.xs)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])).opacity(dropping ? 1 : 0).allowsHitTesting(false))
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping, perform: drop)
        .animation(.easeOut(duration: 0.12), value: dropping)
    }

    // MARK: Live preview

    @ViewBuilder
    private var preview: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let status, trimmed.isEmpty || status.good == false {
            Label { Text(status.text) } icon: { Icon(status.good ? .check : .warning, size: 12) }
                .font(Theme.caption).foregroundStyle(status.good ? Color.green : Color.orange)
        }
        if trimmed.isEmpty {
            EmptyView()
        } else if let totp = TOTP(trimmed) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let real = ClockSkew.corrected(ctx.date)
                let code = totp.code(at: real)
                HStack(spacing: Theme.Space.s) {
                    Text("Code now").font(Theme.caption).foregroundStyle(.secondary)
                    Text(code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code)
                        .font(.system(size: 15, weight: .medium)).monospacedDigit()
                    Text("· \(totp.secondsRemaining(at: real))s").font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                    if let status, status.good { Text(status.text).font(Theme.caption).foregroundStyle(.green) }
                    IconButton(copiedCode ? .check : .copy, help: copiedCode ? "Copied" : "Copy one-time code", diameter: 24) {
                        session.copy(code)
                        copiedCode = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copiedCode = false }
                    }
                    .foregroundStyle(copiedCode ? Color.green : Color.secondary)
                }
            }
            Text("It should match the code the site or your authenticator app shows right now.")
                .font(Theme.caption).foregroundStyle(.secondary)
        } else {
            Label { Text("This is not a valid key. It is letters and digits, or a link that starts with otpauth://") } icon: { Icon(.warning, size: 12) }
                .font(Theme.caption).foregroundStyle(Color.orange)
        }
    }

    // MARK: Import

    private func ingest(_ payloads: [String]) {
        guard !payloads.isEmpty else { status = Status(text: "No QR code found in that image.", good: false); return }
        guard let link = payloads.first(where: { TOTP($0) != nil }) else {
            status = Status(text: payloads.contains { $0.hasPrefix("otpauth-migration://") }
                            ? "That is a Google Authenticator export. Use the QR code a site shows when you turn on two-step verification."
                            : "That QR code is not an authenticator key.", good: false)
            return
        }
        text = link
        revealed = false
        status = Status(text: "Read from the QR code.", good: true)
        onImported(TOTP.label(of: link))
    }

    private func read(_ data: Data) { ingest(QRCode.decode(data: data)) }

    private func pasteImage() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let data = try? Data(contentsOf: url, options: .mappedIfSafe) { return read(data) }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { return read(data) }
        status = Status(text: "No image on the clipboard. Press ⌃⌘⇧4 and drag over the QR code first.", good: false)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Read QR code"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) { read(data) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
                DispatchQueue.main.async { read(bytes) }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            if let data { DispatchQueue.main.async { read(data) } }
        }
        return true
    }
}
