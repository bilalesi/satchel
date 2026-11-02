import SwiftUI
import VaultCore

struct SettingsView: View {
    @EnvironmentObject var session: VaultSession
    @AppStorage(AppSettings.autoLockMinutesKey) private var autoLock = 10
    @AppStorage(AppSettings.clipboardSecondsKey) private var clipboard = 30
    @AppStorage(AppSettings.hotKeyEnabledKey) private var hotKey = true
    @AppStorage(AppSettings.autoTypeEnabledKey) private var autoType = false
    @AppStorage(AppSettings.allowScreenCaptureKey) private var allowCapture = false
    @State private var axTrusted = AutoType.isTrusted
    @State private var touchIDPassword = ""
    @State private var askTouchIDPassword = false
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("Security") {
                Picker("Lock after", selection: $autoLock) {
                    Text("1 minute").tag(1); Text("5 minutes").tag(5); Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30); Text("Never (sleep and screen lock still lock)").tag(0)
                }
                Picker("Clear clipboard after", selection: $clipboard) {
                    Text("15 seconds").tag(15); Text("30 seconds").tag(30); Text("60 seconds").tag(60); Text("Never").tag(0)
                }
                Toggle("Allow screenshots of Satchel windows", isOn: $allowCapture)
                    .onChange(of: allowCapture) { _, _ in AppSettings.applyCapturePolicyToAllWindows() }
                    .help("Off keeps every Satchel window out of screenshots, recordings and screen sharing.")
                Toggle("Quick Access hotkey (⌥ Space)", isOn: $hotKey)
                    .onChange(of: hotKey) { _, on in HotKey.shared.setEnabled(on) }
                Toggle("Auto-type into other apps (⇧↩ in Quick Access)", isOn: $autoType)
                    .onChange(of: autoType) { _, on in
                        if on && !AutoType.isTrusted { AutoType.requestPermission() }
                        axTrusted = AutoType.isTrusted
                    }
                if autoType {
                    HStack {
                        Label(axTrusted ? "Accessibility permission granted" : "Accessibility permission missing",
                              systemImage: axTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(axTrusted ? .green : .orange)
                        Spacer()
                        Button("Open System Settings") { AutoType.openSystemSettings() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        axTrusted = AutoType.isTrusted
                    }
                    Text("Types the secret into the field that was focused in the app in front, through Accessibility first and keystrokes second. Secure keyboard entry (Terminal) blocks keystrokes. After rebuilding the app the permission may need to be granted again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Touch ID") {
                if !session.touchIDAvailable {
                    Text("Touch ID is not available on this Mac.").foregroundStyle(.secondary)
                } else if session.touchIDEnabled {
                    HStack {
                        Label("Enabled", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Disable") { session.disableTouchID() }
                    }
                } else if session.state == .unlocked {
                    HStack {
                        Label("Disabled", systemImage: "touchid").foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable Touch ID…") { askTouchIDPassword = true }
                            .disabled(session.busy)
                    }
                    .alert("Confirm your master password", isPresented: $askTouchIDPassword) {
                        SecureField("Master password", text: $touchIDPassword)
                        Button("Enable") {
                            let pw = touchIDPassword
                            touchIDPassword = ""
                            Task { await session.enableTouchID(password: pw) }
                        }
                        Button("Cancel", role: .cancel) { touchIDPassword = "" }
                    } message: {
                        Text("Touch ID is an extra way to unlock. Your password keeps working.")
                    }
                    Text("The vault key is wrapped by a Secure Enclave key bound to the current fingerprints. Changing fingerprints disables it until you enable it again.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Unlock the vault to change this.").foregroundStyle(.secondary)
                }
            }
            Section("Master password") {
                if session.state == .unlocked {
                    SecureField("Current password", text: $oldPassword)
                    SecureField("New password", text: $newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                    Button("Change password") {
                        Task {
                            if await session.changePassword(old: oldPassword, new: newPassword) {
                                message = "Password changed."
                                oldPassword = ""; newPassword = ""; confirmPassword = ""
                            }
                        }
                    }
                    .disabled(newPassword.count < 8 || newPassword != confirmPassword || oldPassword.isEmpty || session.busy)
                } else {
                    Text("Unlock the vault to change this.").foregroundStyle(.secondary)
                }
            }
            Section("Sync") {
                SyncSettings()
            }
            Section("Browsers") {
                BrowserSettings()
            }
            Section("Vault") {
                LabeledContent("Location", value: session.vaultURL.path)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.vaultURL]) }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let err = session.lastError { Text(err).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .excludedFromCapture()
    }
}
