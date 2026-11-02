import SwiftUI
import VaultCore

/// Shown when the vault is locked or does not exist yet.
struct UnlockView: View {
    @EnvironmentObject var session: VaultSession
    @State private var password = ""
    @State private var confirm = ""
    @State private var revealed = false
    @State private var triedBiometrics = false
    @State private var connecting = false

    var creating: Bool { session.state == .noVault }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack { WorkspaceStrip().padding(.top, Theme.Space.xl); Spacer() }
            VStack { Spacer(); HStack { UpdateIconButton(); Spacer() }.padding(Theme.Space.l) }
            VStack(spacing: Theme.Space.l) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 96, height: 96)
                Text(creating ? "Create the vault for “\(session.activeWorkspace.name)”" : "\(session.activeWorkspace.name) is locked")
                    .font(Theme.title)
                if creating {
                    Text("Pick a long passphrase. It cannot be recovered.")
                        .foregroundStyle(.secondary)
                }
                Card(padding: Theme.Space.m) {
                    VStack(spacing: Theme.Space.s) {
                        PasswordInput(title: "Master password", text: $password, revealed: $revealed, autofocus: true) { Task { await submit() } }
                        if creating {
                            Divider()
                            PasswordInput(title: "Confirm password", text: $confirm, revealed: $revealed) { Task { await submit() } }
                        }
                    }
                    .font(Theme.body)
                }
                .frame(width: 320)
                if creating {
                    // A reserved two-line slot: the text changes as you type, nothing around it moves.
                    Text(createHint).font(Theme.caption).foregroundStyle(createHintIsProblem ? Color.orange : Color.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 320, height: 30, alignment: .top)
                }

                HStack(spacing: Theme.Space.s) {
                    if !creating && session.touchIDEnabled {
                        PillButton("Touch ID", icon: .unlock) { Task { await session.unlockWithBiometrics() } }
                            .disabled(session.busy)
                    }
                    PillButton(creating ? "Create vault" : "Unlock", icon: creating ? .add : .unlock, kind: .primary) {
                        Task { await submit() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.busy || !valid)
                }
                if creating {
                    PillButton("Connect an existing vault", icon: .cloudDownload, kind: .ghost, compact: true) { connecting = true }
                        .help("Download a vault from GitHub or a synced folder")
                }
                // Reserved slot: the spinner and errors appear here without moving anything above.
                ZStack {
                    if session.busy {
                        ProgressView().controlSize(.small)
                    } else if let err = session.lastError {
                        Text(err).font(Theme.caption).foregroundStyle(.red)
                            .multilineTextAlignment(.center).lineLimit(2)
                    }
                }
                .frame(width: 320, height: 32)
            }
            .padding(Theme.Space.xxl + Theme.Space.s)
        }
        .excludedFromCapture()
        .onChange(of: session.activeWorkspaceID) { _, _ in password = ""; confirm = ""; revealed = false }
        .sheet(isPresented: $connecting) { ConnectVaultView() }
        .onAppear {
            if !creating && session.touchIDEnabled && !triedBiometrics {
                triedBiometrics = true
                Task { await session.unlockWithBiometrics() }
            }
        }
    }

    private var createHint: String {
        if password.isEmpty { return "At least 8 characters. Use the eye to check what you typed." }
        if password.count < 8 { return "Too short: \(password.count) of 8 characters." }
        if !confirm.isEmpty && confirm != password { return "The two passwords do not match." }
        return confirm == password ? "Looks good." : "Type it again to confirm."
    }

    private var createHintIsProblem: Bool {
        password.count < 8 && !password.isEmpty || (!confirm.isEmpty && confirm != password)
    }

    private var valid: Bool {
        creating ? (password.count >= 8 && password == confirm) : !password.isEmpty
    }

    private func submit() async {
        guard valid else { return }
        session.lastError = nil
        if creating { await session.createVault(password: password) } else { await session.unlock(password: password) }
        if session.state == .unlocked { password = ""; confirm = ""; revealed = false }
    }
}
