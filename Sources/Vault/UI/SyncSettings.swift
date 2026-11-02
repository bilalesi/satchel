import AppKit
import SwiftUI
import VaultCore

/// Draft of a remote configuration, edited in Settings and in the Connect sheet.
struct RemoteDraft: Equatable {
    enum Backend: String, CaseIterable, Identifiable {
        case off, folder, github, git, webdav, s3
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .folder: return "Synced folder"
            case .github: return "GitHub"
            case .git: return "Git (SSH)"
            case .webdav: return "WebDAV"
            case .s3: return "S3-compatible"
            }
        }

        var subtitle: String? {
            switch self {
            case .off: return "Keep the vault on this Mac only"
            case .folder: return "iCloud Drive, Dropbox, a network share"
            case .github: return "A private repository, with a token"
            case .git: return "Any git host, using your SSH keys"
            case .webdav: return "Nextcloud, Synology, a NAS"
            case .s3: return "AWS S3, Cloudflare R2, MinIO, Backblaze"
            }
        }

        var icon: Codicon {
            switch self {
            case .off: return .circleSlash
            case .folder: return .folder
            case .github: return .github
            case .git: return .gitMerge
            case .webdav: return .server
            case .s3: return .cloud
            }
        }
    }

    var backend: Backend = .off
    var folderPath = ""
    var owner = ""
    var repo = ""
    var branch = "main"
    var prefix = ""
    var gitURL = ""
    var davURL = ""
    var davUser = ""
    var s3Endpoint = ""
    var s3Region = ""
    var s3Bucket = ""
    var s3AccessKey = ""
    /// Token, password or secret key typed in this session. Never read back from the vault.
    var secret = ""

    init() {}

    init(_ config: RemoteConfig) {
        switch config {
        case .off: backend = .off
        case .folder(let url): backend = .folder; folderPath = url.path
        case .github(let r): backend = .github; owner = r.owner; repo = r.name; branch = r.branch; prefix = r.prefix
        case .git(let g): backend = .git; gitURL = g.url; branch = g.branch; prefix = g.prefix
        case .webdav(let url, let user): backend = .webdav; davURL = url.absoluteString; davUser = user
        case .s3(let c): backend = .s3; s3Endpoint = c.endpoint; s3Region = c.region; s3Bucket = c.bucket; prefix = c.prefix; s3AccessKey = c.accessKeyID
        }
    }

    var isComplete: Bool {
        switch backend {
        case .off: return true
        case .folder: return !folderPath.isEmpty
        case .github: return !owner.isEmpty && !repo.isEmpty
        case .git: return GitConfig(url: gitURL, branch: branch, prefix: prefix).isValid
        case .webdav: return URL(string: davURL)?.host != nil && !davUser.isEmpty
        case .s3: return URL(string: s3Endpoint)?.host != nil && !s3Bucket.isEmpty && !s3AccessKey.isEmpty
        }
    }

    /// Whether a credential has to exist (typed now or saved earlier) for this backend.
    var needsSecret: Bool { [.github, .webdav, .s3].contains(backend) }

    func commit() -> RemoteConfig {
        switch backend {
        case .off:
            return .off
        case .folder:
            return .folder(URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true))
        case .github:
            return .github(GitHubRepo(owner: owner, name: repo, branch: branch, prefix: prefix))
        case .git:
            return .git(GitConfig(url: gitURL, branch: branch, prefix: prefix))
        case .webdav:
            return .webdav(url: URL(string: davURL.trimmingCharacters(in: .whitespaces)) ?? URL(string: "https://invalid")!, username: davUser)
        case .s3:
            return .s3(S3Config(endpoint: s3Endpoint, region: s3Region, bucket: s3Bucket, prefix: prefix, accessKeyID: s3AccessKey))
        }
    }

    /// Height of the form in Settings, so the window never shows empty space.
    var settingsHeight: CGFloat {
        switch backend {
        case .off: return 250
        case .folder: return 330
        case .github: return 470
        case .git: return 450
        case .webdav: return 440
        case .s3: return 520
        }
    }
}

/// Fields for one backend. Shared by Settings and the Connect sheet.
struct RemoteDraftFields: View {
    @Binding var draft: RemoteDraft
    var allowOff = true
    var secretSaved = false

    var body: some View {
        LabeledContent("Sync method") {
            Dropdown(selection: $draft.backend, options: RemoteDraft.Backend.allCases
                .filter { allowOff || $0 != .off }
                .map { .init(value: $0, title: $0.title, icon: $0.icon, subtitle: $0.subtitle) }, minWidth: 220)
        }
        switch draft.backend {
        case .off:
            Text("The vault stays on this Mac only.").foregroundStyle(.secondary)
        case .folder:
            HStack(spacing: Theme.Space.s) {
                TextField("Folder", text: $draft.folderPath, prompt: Text("~/Library/Mobile Documents/com~apple~CloudDocs/Satchel"))
                PillButton("Choose", icon: .folderOpened, compact: true) { choose() }
            }
            Text("Any synced folder works: iCloud Drive, Dropbox, a network share.").font(.callout).foregroundStyle(.secondary)
        case .github:
            TextField("Owner", text: $draft.owner, prompt: Text("github username or org"))
            TextField("Repository", text: $draft.repo, prompt: Text("private repository name"))
            TextField("Branch", text: $draft.branch)
            TextField("Folder in repository (optional)", text: $draft.prefix)
            secretField("Fine-grained token", placeholder: "github_pat_…")
            hint("github.com → Settings → Developer settings → Fine-grained tokens. Limit it to this repository with Contents: Read and write. Stored encrypted in the vault, never synced.")
        case .git:
            TextField("Repository address", text: $draft.gitURL, prompt: Text("git@github.com:you/vault.git"))
            TextField("Branch", text: $draft.branch)
            TextField("Folder in repository (optional)", text: $draft.prefix)
            hint("Uses the git and SSH keys already set up on this Mac. If the key has a passphrase, add it to the agent once: ssh-add --apple-use-keychain. Use a private repository.")
        case .webdav:
            TextField("Folder address", text: $draft.davURL, prompt: Text("https://cloud.example.com/remote.php/dav/files/you/Satchel"))
            TextField("Username", text: $draft.davUser)
            secretField("Password", placeholder: "app password")
            hint("Use an app password, not your account password. The folder must exist or be creatable. The server must be reached over https.")
        case .s3:
            TextField("Endpoint", text: $draft.s3Endpoint, prompt: Text("https://s3.eu-west-1.amazonaws.com"))
            TextField("Region", text: $draft.s3Region, prompt: Text("us-east-1; \"auto\" for Cloudflare R2"))
            TextField("Bucket", text: $draft.s3Bucket)
            TextField("Folder in bucket (optional)", text: $draft.prefix)
            TextField("Access key ID", text: $draft.s3AccessKey)
            secretField("Secret access key", placeholder: "secret key")
            hint("Create a key limited to this bucket. Satchel checks that the service protects against overwriting changes from another device and refuses services that do not.")
        }
    }

    private func secretField(_ title: String, placeholder: String) -> some View {
        SecureField(title, text: $draft.secret,
                    prompt: Text(secretSaved ? "saved (encrypted in the vault); type to replace" : placeholder))
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
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
    @State private var saving = false

    var body: some View {
        SettingsPage(height: pageHeight) {
            Section {
                RemoteDraftFields(draft: $draft, secretSaved: sync.hasSecret(for: draft.commit()))
            }
            Section {
                syncControls
                statusLine
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if sync.isConfigured { whatToSync }
        }
        .animation(.easeOut(duration: 0.2), value: draft.backend)
        .onAppear { draft = RemoteDraft(sync.config) }
    }

    private var pageHeight: CGFloat { draft.settingsHeight + (sync.isConfigured ? 120 + CGFloat(session.categories.count) * 32 + (sync.selection.itemOverrides.isEmpty ? 0 : 36) : 0) }

    /// Device-local choice of what leaves this Mac.
    @ViewBuilder private var whatToSync: some View {
        Section("What to sync on this Mac") {
            Toggle("Items without a category", isOn: Binding(get: { sync.selection.syncUncategorized },
                                                             set: { sync.setSyncUncategorized($0) }))
            ForEach(session.categories) { c in
                Toggle(isOn: Binding(get: { sync.isSynced(category: c.id) }, set: { sync.setSynced(category: c.id, $0) })) {
                    Label { Text(c.name) } icon: { CategoryTile(category: c, size: 16) }
                }
            }
            let overrides = sync.selection.itemOverrides.count
            if overrides > 0 {
                HStack {
                    Text("\(overrides) item\(overrides == 1 ? "" : "s") with their own setting").foregroundStyle(.secondary)
                    Spacer()
                    PillButton("Reset", icon: .debugRestart, compact: true) { sync.resetItemOverrides() }
                }
            }
            Text("Items left out stay on this Mac and are never uploaded. Items already uploaded stay on the remote; other Macs choose for themselves.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var syncControls: some View {
        HStack(spacing: Theme.Space.s) {
            PillButton("Test", icon: .pulse) { Task { await test() } }
                .disabled(!draft.isComplete || draft.backend == .off || testing)
                .help("Check the remote is reachable with these settings")
            PillButton("Save", icon: .save, kind: .primary) { save() }
                .disabled(!draft.isComplete || saving || draft == RemoteDraft(sync.config) && draft.secret.isEmpty)
            Spacer()
            PillButton("Sync now", icon: .sync) { Task { await sync.syncNow(announce: true) } }
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
        message = await sync.test(draft.commit(), secret: draft.secret)
    }

    private func save() {
        Task {
            saving = true
            defer { saving = false }
            let config = draft.commit()
            do {
                if config.needsConditionalWriteProbe { _ = try await sync.check(config, typedSecret: draft.secret) }
                try sync.apply(config, secret: draft.secret)
                draft.secret = ""
                message = "Saved."
            } catch { message = SyncCoordinator.describe(error, config: config) }
        }
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
    @State private var showPassword = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Connect an existing vault").font(Theme.headline).padding(Theme.Space.l)
            Divider()
            Form {
                Section("Where is it?") { RemoteDraftFields(draft: $draft, allowOff: false) }
                Section("Unlock") {
                    LabeledContent("Master password") { PasswordInput(title: "Of that vault", text: $password, revealed: $showPassword, alignment: .trailing) }
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
                    .disabled(!draft.isComplete || password.isEmpty || session.busy || (draft.needsSecret && draft.secret.isEmpty))
            }
            .padding(14)
        }
        .frame(width: 520, height: 520)
        .excludedFromCapture()
    }

    private func connect() async {
        message = nil
        if await session.connectExisting(config: draft.commit(), secret: draft.secret, password: password) {
            password = ""
            dismiss()
        } else {
            message = session.lastError
        }
    }
}
