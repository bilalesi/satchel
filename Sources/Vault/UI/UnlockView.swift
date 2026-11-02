import SwiftUI
import VaultCore

/// Shown when the vault is locked or does not exist yet.
struct UnlockView: View {
    @EnvironmentObject var session: VaultSession
    @State private var password = ""
    @State private var confirm = ""
    @State private var triedBiometrics = false
    @State private var connecting = false
    @FocusState private var focused: Bool

    var creating: Bool { session.state == .noVault }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack { HStack { Spacer(); WorkspaceSwitcher() }.padding(Theme.Space.l); Spacer() }
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
                        SecureField("Master password", text: $password)
                            .textFieldStyle(.plain)
                            .focused($focused)
                            .onSubmit { Task { await submit() } }
                        if creating {
                            Divider()
                            SecureField("Confirm password", text: $confirm)
                                .textFieldStyle(.plain)
                                .onSubmit { Task { await submit() } }
                        }
                    }
                    .font(Theme.body)
                }
                .frame(width: 320)

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
        .sheet(isPresented: $connecting) { ConnectVaultView() }
        .onAppear {
            focused = true
            if !creating && session.touchIDEnabled && !triedBiometrics {
                triedBiometrics = true
                Task { await session.unlockWithBiometrics() }
            }
        }
    }

    private var valid: Bool {
        creating ? (password.count >= 8 && password == confirm) : !password.isEmpty
    }

    private func submit() async {
        guard valid else { return }
        session.lastError = nil
        if creating { await session.createVault(password: password) } else { await session.unlock(password: password) }
        if session.state == .unlocked { password = ""; confirm = "" }
    }
}
