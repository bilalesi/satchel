import SwiftUI
import VaultCore

/// Settings window: one tab per concern (macOS toolbar tabs). Each tab sizes the window to
/// its own content so short pages don't leave empty space.
struct SettingsView: View {
    enum Tab: String, CaseIterable { case general, security, sync, browsers, vault, license }

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
            LicenseSettings()
                .tabItem { Label { Text("Licence") } icon: { Image(nsImage: Codicon.key.image()) } }
                .tag(Tab.license)
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
    @EnvironmentObject var updates: UpdateManager
    @AppStorage(UpdateManager.enabledKey) private var autoUpdate = true
    @AppStorage(AppSettings.autoLockMinutesKey) private var autoLock = 10
    @AppStorage(AppSettings.clipboardSecondsKey) private var clipboard = 30
    @AppStorage(AppSettings.hotKeyEnabledKey) private var hotKey = true
    @ObservedObject private var hotKeyState = HotKey.shared
    @AppStorage(AppSettings.autoTypeEnabledKey) private var autoType = false
    @State private var axTrusted = AutoType.isTrusted

    var body: some View {
        SettingsPage(height: (autoType ? 390 : 290) + (updates.isAvailable ? 150 : 0) + (hotKey ? 56 : 0) + (hotKey && hotKeyState.conflict ? 28 : 0)) {
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
            if updates.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $autoUpdate)
                    LabeledContent {
                        PillButton("Check now", icon: .sync, compact: true) { Task { await updates.check(manual: true) } }
                            .disabled(updates.state == .checking)
                    } label: {
                        Text(updates.message ?? "Version \(updates.currentVersion.description)").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Satchel contacts github.com only to look for a newer release. Updates are verified with a signature before they are installed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Quick Access") {
                Toggle("Open from anywhere with a shortcut", isOn: $hotKey)
                    .onChange(of: hotKey) { _, on in HotKey.shared.setEnabled(on) }
                if hotKey {
                    LabeledContent("Shortcut") { ShortcutRecorder(hotKey: hotKeyState) }
                    if hotKeyState.conflict {
                        Label { Text("Another app already uses this shortcut. Record a different one.") } icon: { Icon(.warning, size: 13) }
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
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
    @State private var showPasswords = false
    @State private var message: String?

    var body: some View {
        SettingsPage(height: 540) {
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
            LabeledContent("Current password") { PasswordInput(title: "Required", text: $oldPassword, revealed: $showPasswords, alignment: .trailing) }
            LabeledContent("New password") { PasswordInput(title: "Choose a new one", text: $newPassword, revealed: $showPasswords, alignment: .trailing) }
            LabeledContent("Confirm") { PasswordInput(title: "Same again", text: $confirmPassword, revealed: $showPasswords, alignment: .trailing) }
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
        SettingsPage(height: 540 + CGFloat(session.workspaces.count) * 36) {
            WorkspaceManager()
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
            Section("Welcome") {
                LabeledContent {
                    PillButton("Play", icon: .sparkle, compact: true) {
                        session.welcomeRequested = true
                        AppDelegate.openMainWindow()
                    }
                } label: {
                    Text("The short intro shown the first time Satchel opens.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                LabeledContent("Items", value: "\(session.items.count)")
                LabeledContent("Open source") {
                    PillButton("Licenses", icon: .note, compact: true) {
                        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }
}

// MARK: Licence

struct LicenseSettings: View {
    @EnvironmentObject var updates: UpdateManager
    @ObservedObject private var licensing = Licensing.shared
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        SettingsPage(height: licensing.license == nil ? 370 : 300) {
            if !licensing.isEnforced {
                Section {
                    Text("Licensing is not set up in this build. Every feature is on.").foregroundStyle(.secondary)
                }
            } else if let l = licensing.license {
                Section("Licence") {
                    LabeledContent("Plan", value: l.planName)
                    LabeledContent("Bought", value: l.purchased.formatted(date: .long, time: .omitted))
                    LabeledContent("Updates until", value: l.updatesUntil.formatted(date: .long, time: .omitted))
                    LabeledContent("Key", value: l.id)
                    LabeledContent {
                        PillButton("Remove", icon: .close, kind: .danger, compact: true) { licensing.remove(); updates.licenseChanged() }
                    } label: {
                        Text("Releases after the last day keep being offered as a renewal. The version you have stays yours.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Trial") {
                    let left = licensing.trial.daysLeft()
                    LabeledContent("Status", value: left > 0 ? "\(left) \(left == 1 ? "day" : "days") left" : "Ended")
                    Text(left > 0
                         ? "Every feature is on during the trial. Your vault never depends on a licence."
                         : "Your vault stays open: unlock, read, copy and edit every item. Browser fill and auto-type need a licence.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Licence key") {
                    TextField("SATCHEL-…", text: $key, axis: .vertical)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(3...4).labelsHidden()
                    LabeledContent {
                        HStack {
                            PillButton("Buy", icon: .linkExternal, compact: true) { NSWorkspace.shared.open(AppIdentity.purchaseURL) }
                            PillButton("Activate", icon: .key, kind: .primary, compact: true) {
                                if licensing.activate(key) { key = ""; error = nil; updates.licenseChanged() }
                                else { error = "This key is not valid. Paste it exactly as you received it." }
                            }
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } label: {
                        if let error { Text(error).font(.callout).foregroundStyle(.red) }
                        else { Text("Checked on this Mac. Nothing is sent anywhere.").font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}
