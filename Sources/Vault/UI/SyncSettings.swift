import AppKit
import SwiftUI
import VaultCore

/// Draft of a remote configuration, edited in Settings and in the Connect sheet.
struct RemoteDraft: Equatable {
    enum Backend: String, CaseIterable, Identifiable {
        case off, folder, github
        var id: String { rawValue }
        var title: String {
            switch self { case .off: return "Off"; case .folder: return "Folder"; case .github: return "GitHub" }
        }

        var icon: Codicon {
            switch self { case .off: return .circleSlash; case .folder: return .folder; case .github: return .github }
        }
    }

    var backend: Backend = .off
    var folderPath = ""
    var owner = ""
    var repo = ""
    var branch = "main"
    var prefix = ""
    var token = ""

    init() {}

    init(_ config: RemoteConfig) {
        switch config {
        case .off: backend = .off
        case .folder(let url): backend = .folder; folderPath = url.path
        case .github(let r): backend = .github; owner = r.owner; repo = r.name; branch = r.branch; prefix = r.prefix
        }
    }

    var isComplete: Bool {
        switch backend {
        case .off: return true
        case .folder: return !folderPath.isEmpty
        case .github: return !owner.isEmpty && !repo.isEmpty
        }
    }

    /// Builds the config. The token is handed to the caller, who stores it in the vault.
    func commit() -> RemoteConfig {
        switch backend {
        case .off:
            return .off
        case .folder:
            return .folder(URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true))
        case .github:
            return .github(GitHubRepo(owner: owner, name: repo, branch: branch, prefix: prefix))
        }
    }
}

/// Fields for one backend. Shared by Settings and the Connect sheet.
struct RemoteDraftFields: View {
    @Binding var draft: RemoteDraft
    var allowOff = true
    var tokenSaved = false

    var body: some View {
        LabeledContent("Remote") {
            CapsuleSegmented(selection: $draft.backend, options: RemoteDraft.Backend.allCases
                .filter { allowOff || $0 != .off }
                .map { .init(value: $0, title: $0.title, icon: $0.icon) })
        }
        switch draft.backend {
        case .off:
            Text("The vault stays on this Mac only.").foregroundStyle(.secondary)
        case .folder:
            HStack(spacing: Theme.Space.s) {
                TextField("Folder", text: $draft.folderPath, prompt: Text("~/Library/Mobile Documents/com~apple~CloudDocs/Vault"))
                PillButton("Choose", icon: .folderOpened, compact: true) { choose() }
            }
            Text("Any synced folder works: iCloud Drive, Dropbox, a network share.").font(.callout).foregroundStyle(.secondary)
        case .github:
            TextField("Owner", text: $draft.owner, prompt: Text("github username or org"))
            TextField("Repository", text: $draft.repo, prompt: Text("private repository name"))
            TextField("Branch", text: $draft.branch)
            TextField("Folder in repository (optional)", text: $draft.prefix)
            SecureField("Fine-grained token", text: $draft.token,
                        prompt: Text(tokenSaved ? "saved (encrypted in the vault); paste to replace" : "github_pat_…"))
            Text("github.com → Settings → Developer settings → Fine-grained tokens. Limit it to this repository with Contents: Read and write. Stored encrypted next to the vault, never synced.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url { draft.folderPath = url.path }
    }
}

struct SyncSettings: View {
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    @State private var draft = RemoteDraft()
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        SettingsPage(height: pageHeight) {
            Section {
                RemoteDraftFields(draft: $draft, tokenSaved: sync.hasToken)
            }
            Section {
                syncControls
                statusLine
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: draft.backend)
        .onAppear { draft = RemoteDraft(sync.config) }
    }

    /// Sized to the form of the selected remote so the window never shows empty space.
    private var pageHeight: CGFloat {
        switch draft.backend {
        case .off: return 250
        case .folder: return 330
        case .github: return 470
        }
    }

    private var syncControls: some View {
        HStack(spacing: Theme.Space.s) {
            PillButton("Test", icon: .pulse) { Task { await test() } }
                .disabled(!draft.isComplete || draft.backend == .off || testing)
                .help("Check the remote is reachable with these settings")
            PillButton("Save", icon: .save, kind: .primary) { save() }
                .disabled(!draft.isComplete || draft == RemoteDraft(sync.config) && draft.token.isEmpty)
            Spacer()
            PillButton("Sync now", icon: .sync) { Task { await sync.syncNow() } }
                .disabled(!sync.isConfigured || session.state != .unlocked || sync.status == .syncing)
        }
    }

    /// One fixed-height row whose icon and text change in place (no spinner swap, no jump).
    private var statusLine: some View {
        let (icon, text, color): (Codicon, String, Color) = {
            switch sync.status {
            case .off: return (.circleSlash, "Sync is off.", .secondary)
            case .syncing: return (.sync, "Syncing…", .accentColor)
            case .error(let m): return (.warning, m, .red)
            case .idle:
                guard let d = sync.lastSyncAt else { return (.info, "Saved. Syncs after the next change or unlock.", .secondary) }
                let report = sync.lastReport.map { " · ↓\($0.pulled) ↑\($0.pushed)" + ($0.conflicts > 0 ? " · \($0.conflicts) merged" : "") } ?? ""
                return (.passFilled, "Synced \(d.formatted(.relative(presentation: .named)))" + report, .green)
            }
        }()
        return HStack(spacing: Theme.Space.s) {
            Icon(icon, size: 13)
                .foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(color == .secondary ? .secondary : .primary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
        .animation(.easeOut(duration: 0.15), value: sync.status)
    }


    private func test() async {
        testing = true
        defer { testing = false }
        message = await sync.test(draft.commit(), token: draft.token)
    }

    private func save() {
        do {
            if !draft.token.isEmpty { try sync.saveToken(draft.token) }
            sync.config = draft.commit()
            draft.token = ""
            message = "Saved."
        } catch { message = error.localizedDescription }
    }
}

/// First launch on a second Mac: download the vault and unlock it.
struct ConnectVaultView: View {
    @EnvironmentObject var session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RemoteDraft = {
        var d = RemoteDraft()
        d.backend = .github
        return d
    }()
    @State private var password = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Connect an existing vault").font(Theme.headline).padding(Theme.Space.l)
            Divider()
            Form {
                Section("Where is it?") { RemoteDraftFields(draft: $draft, allowOff: false) }
                Section("Unlock") {
                    SecureField("Master password of that vault", text: $password)
                    Text("Touch ID is set up per Mac; enable it again here afterwards.").font(.callout).foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                PillButton("Cancel", icon: .close, kind: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
                PillButton("Connect", icon: .cloudDownload, kind: .primary) { Task { await connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isComplete || password.isEmpty || session.busy || (draft.backend == .github && draft.token.isEmpty))
            }
            .padding(14)
        }
        .frame(width: 520, height: 520)
        .excludedFromCapture()
    }

    private func connect() async {
        message = nil
        if await session.connectExisting(config: draft.commit(), token: draft.token, password: password) {
            password = ""
            dismiss()
        } else {
            message = session.lastError
        }
    }
}
