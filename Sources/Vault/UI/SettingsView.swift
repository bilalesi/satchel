import SwiftUI
import VaultCore

/// Settings window: one tab per concern (macOS toolbar tabs). Each tab sizes the window to
/// its own content so short pages don't leave empty space.
struct SettingsView: View {
    enum Tab: String, CaseIterable { case general, security, sync, browsers, vault }

    @AppStorage("settingsTab") private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label { Text("General") } icon: { Image(nsImage: Codicon.settingsGear.image()) } }
                .tag(Tab.general)
            SecuritySettings()
                .tabItem { Label { Text("Security") } icon: { Image(nsImage: Codicon.shield.image()) } }
                .tag(Tab.security)
            SyncSettings()
                .tabItem { Label { Text("Sync") } icon: { Image(nsImage: Codicon.sync.image()) } }
                .tag(Tab.sync)
            BrowserSettings()
                .tabItem { Label { Text("Browsers") } icon: { Image(nsImage: Codicon.globe.image()) } }
                .tag(Tab.browsers)
            VaultSettings()
                .tabItem { Label { Text("Vault") } icon: { Image(nsImage: Codicon.archive.image()) } }
                .tag(Tab.vault)
        }
        .excludedFromCapture()
    }
}

/// Shared page chrome: grouped form, fixed width, per-tab height.
struct SettingsPage<Content: View>: View {
    static var width: CGFloat { 560 }
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: Self.width, height: height)
    }
}

// MARK: General

struct GeneralSettings: View {
    @AppStorage(AppSettings.autoLockMinutesKey) private var autoLock = 10
    @AppStorage(AppSettings.clipboardSecondsKey) private var clipboard = 30
    @AppStorage(AppSettings.hotKeyEnabledKey) private var hotKey = true
    @AppStorage(AppSettings.autoTypeEnabledKey) private var autoType = false
    @State private var axTrusted = AutoType.isTrusted

    var body: some View {
        SettingsPage(height: autoType ? 390 : 290) {
            Section {
                LabeledContent("Lock after") {
                    Dropdown(selection: $autoLock, options: [
                        .init(value: 1, title: "1 minute"), .init(value: 5, title: "5 minutes"),
                        .init(value: 10, title: "10 minutes"), .init(value: 30, title: "30 minutes"),
                        .init(value: 0, title: "Sleep or screen lock", subtitle: "No idle timer"),
                    ], minWidth: 190)
                }
                LabeledContent("Clear clipboard after") {
                    Dropdown(selection: $clipboard, options: [
                        .init(value: 15, title: "15 seconds"), .init(value: 30, title: "30 seconds"),
                        .init(value: 60, title: "60 seconds"), .init(value: 0, title: "Never", subtitle: "Not recommended"),
                    ], minWidth: 190)
                }
            }
            Section("Quick Access") {
                Toggle("Open with ⌥ Space", isOn: $hotKey)
                    .onChange(of: hotKey) { _, on in HotKey.shared.setEnabled(on) }
                Toggle("Auto-type into other apps (⇧↩)", isOn: $autoType)
                    .onChange(of: autoType) { _, on in
                        if on && !AutoType.isTrusted { AutoType.requestPermission() }
                        axTrusted = AutoType.isTrusted
                    }
                if autoType {
                    LabeledContent {
                        PillButton("System Settings", icon: .linkExternal, compact: true) { AutoType.openSystemSettings() }
                    } label: {
                        Label { Text(axTrusted ? "Accessibility permission granted" : "Accessibility permission missing") }
                            icon: { Icon(axTrusted ? .verifiedFilled : .warning, size: 13) }
                            .foregroundStyle(axTrusted ? .green : .orange)
                    }
                    Text("Types into the field that is focused in the app in front. Terminal's Secure Keyboard Entry blocks it. After an app update, grant the permission again if asked.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AutoType.isTrusted
        }
    }
}

// MARK: Security

struct SecuritySettings: View {
    @EnvironmentObject var session: VaultSession
    @AppStorage(AppSettings.allowScreenCaptureKey) private var allowCapture = false
    @State private var touchIDPassword = ""
    @State private var askTouchIDPassword = false
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var message: String?

    var body: some View {
        SettingsPage(height: 450) {
            Section("Touch ID") { touchID }
            Section("Master password") { passwordChange }
            Section("Privacy") {
                Toggle("Allow screenshots of Satchel windows", isOn: $allowCapture)
                    .onChange(of: allowCapture) { _, _ in AppSettings.applyCapturePolicyToAllWindows() }
                Text("When off, Satchel windows are hidden from screenshots, recordings and screen sharing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let err = session.lastError { Text(err).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private var touchID: some View {
        if !session.touchIDAvailable {
            Text("Touch ID is not available on this Mac.").foregroundStyle(.secondary)
        } else if session.touchIDEnabled {
            LabeledContent {
                PillButton("Turn off", icon: .close, kind: .danger, compact: true) { session.disableTouchID() }
            } label: {
                Label { Text("Enabled") } icon: { Icon(.verifiedFilled, size: 13) }.foregroundStyle(.green)
            }
        } else if session.state == .unlocked {
            LabeledContent {
                PillButton("Turn on", icon: .unlock, kind: .primary, compact: true) { askTouchIDPassword = true }
                    .disabled(session.busy)
            } label: {
                Label { Text("Off") } icon: { Icon(.circleSlash, size: 13) }.foregroundStyle(.secondary)
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
            Text("Bound to the fingerprints enrolled now. Changing fingerprints turns it off until you enable it again.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Unlock the vault to change this.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var passwordChange: some View {
        if session.state == .unlocked {
            SecureField("Current password", text: $oldPassword)
            SecureField("New password", text: $newPassword)
            SecureField("Confirm new password", text: $confirmPassword)
            LabeledContent {
                PillButton("Change password", icon: .key, kind: .primary, compact: true) {
                    Task {
                        if await session.changePassword(old: oldPassword, new: newPassword) {
                            message = "Password changed."
                            oldPassword = ""; newPassword = ""; confirmPassword = ""
                        }
                    }
                }
                .disabled(newPassword.count < 8 || newPassword != confirmPassword || oldPassword.isEmpty || session.busy)
            } label: {
                Text(passwordHint).font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Text("Unlock the vault to change this.").foregroundStyle(.secondary)
        }
    }

    private var passwordHint: String {
        if newPassword.isEmpty { return "At least 8 characters" }
        if newPassword.count < 8 { return "Too short" }
        if !confirmPassword.isEmpty && confirmPassword != newPassword { return "Passwords don't match" }
        return ""
    }
}

// MARK: Vault

struct VaultSettings: View {
    @EnvironmentObject var session: VaultSession

    var body: some View {
        SettingsPage(height: 340) {
            Section("Location") {
                LabeledContent("Folder") {
                    Text(session.vaultURL.path)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                LabeledContent {
                    PillButton("Open in Finder", icon: .folderOpened, compact: true) { NSWorkspace.shared.open(session.vaultURL) }
                } label: {
                    Text("Everything in this folder is encrypted. Copying it is a backup.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                LabeledContent("Items", value: "\(session.items.count)")
                LabeledContent("Icons") {
                    Link("Codicons by Microsoft, CC BY 4.0", destination: URL(string: "https://github.com/microsoft/vscode-codicons")!)
                        .font(.callout)
                }
            }
        }
    }
}
