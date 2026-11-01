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
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Theme.accent(.login))
                Text(creating ? "Create your vault" : "\(AppIdentity.name) is locked")
                    .font(.system(size: 22, weight: .semibold))
                if creating {
                    Text("Pick a long passphrase. It cannot be recovered.")
                        .foregroundStyle(.secondary)
                }
                Card(padding: 14) {
                    VStack(spacing: 10) {
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

                HStack(spacing: 10) {
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
            .padding(40)
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
