import SwiftUI
import VaultCore

struct SettingsView: View {
    @EnvironmentObject var session: VaultSession
    @AppStorage(AppSettings.autoLockMinutesKey) private var autoLock = 10
    @AppStorage(AppSettings.clipboardSecondsKey) private var clipboard = 30
    @AppStorage(AppSettings.hotKeyEnabledKey) private var hotKey = true
    @State private var touchIDPassword = ""
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
                Toggle("Quick Access hotkey (⌥ Space)", isOn: $hotKey)
                    .onChange(of: hotKey) { _, on in HotKey.shared.setEnabled(on) }
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
                    SecureField("Master password", text: $touchIDPassword)
                    Button("Enable Touch ID") {
                        Task { await session.enableTouchID(password: touchIDPassword); touchIDPassword = "" }
                    }
                    .disabled(touchIDPassword.isEmpty || session.busy)
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
            Section("Vault") {
                LabeledContent("Location", value: session.vaultURL.path)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.vaultURL]) }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let err = session.lastError { Text(err).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .excludedFromCapture()
    }
}
