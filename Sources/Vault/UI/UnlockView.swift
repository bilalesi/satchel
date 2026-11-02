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
            VStack(spacing: Theme.Space.l) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 96, height: 96)
                Text(creating ? "Create your vault" : "\(AppIdentity.name) is locked")
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
                    .font(.system(size: 14))
                }
                .frame(width: 320)

                HStack(spacing: Theme.Space.s) {
                    if !creating && session.touchIDEnabled {
                        Button {
                            Task { await session.unlockWithBiometrics() }
                        } label: {
                            Label("Touch ID", systemImage: "touchid")
                        }
                        .disabled(session.busy)
                    }
                    Button(creating ? "Create vault" : "Unlock") { Task { await submit() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(session.busy || !valid)
                }
                if creating {
                    Button("Connect an existing vault from GitHub or a folder…") { connecting = true }
                        .buttonStyle(.link).font(.callout)
                }
                if session.busy { ProgressView().controlSize(.small) }
                if let err = session.lastError {
                    Text(err).font(.callout).foregroundStyle(.red).frame(width: 320)
                }
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
