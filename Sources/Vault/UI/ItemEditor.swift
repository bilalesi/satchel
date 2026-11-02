import SwiftUI
import VaultCore

struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var session: VaultSession
    @EnvironmentObject var sync: SyncCoordinator
    let type: ItemType
    let existing: ItemOverview?
    let onSave: (ItemOverview, ItemDetails) -> Void

    @State private var title: String
    @State private var username: String
    @State private var urls: String
    @State private var tags: String
    @State private var favorite: Bool
    @State private var bundleIDs: [String]
    @State private var fields: [String: String]
    @State private var revealed: Set<String> = []
    @State private var categoryID: UUID?
    @State private var syncChoice: SyncCoordinator.ItemSyncChoice

    init(type: ItemType, overview: ItemOverview?, details: ItemDetails?, defaultCategory: UUID? = nil, syncChoice: SyncCoordinator.ItemSyncChoice = .followCategory, onSave: @escaping (ItemOverview, ItemDetails) -> Void) {
        self.type = type
        self.existing = overview
        self.onSave = onSave
        _title = State(initialValue: overview?.title ?? "")
        _username = State(initialValue: overview?.username ?? "")
        _urls = State(initialValue: overview?.urls.joined(separator: ", ") ?? "")
        _tags = State(initialValue: overview?.tags.joined(separator: ", ") ?? "")
        _favorite = State(initialValue: overview?.favorite ?? false)
        _bundleIDs = State(initialValue: overview?.bundleIDs ?? [])
        _fields = State(initialValue: details?.fields ?? [:])
        _categoryID = State(initialValue: overview?.categoryID ?? defaultCategory)
        _syncChoice = State(initialValue: syncChoice)
    }

    /// Sized to the fields of the type, but never taller than the window it slides out of.
    private var editorHeight: CGFloat {
        min(560 + (type == .login ? 150 : 0) + (sync.isConfigured ? 36 : 0),
            (NSApp.windows.first { $0.isVisible && $0.title == AppIdentity.name }?.frame.height ?? 680) - 56)
    }

    var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { $0.0 != AppIdentity.bundleID }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                IconTile(type: type, size: 28)
                Text(existing == nil ? "New \(type.displayName)" : "Edit \(type.displayName)")
                    .font(Theme.headline)
                Spacer()
                IconButton(favorite ? .starFull : .starEmpty, help: favorite ? "Remove from favorites" : "Add to favorites") {
                    favorite.toggle()
                }
                .foregroundStyle(favorite ? Color.yellow : Color.secondary)
            }
            .padding(Theme.Space.l)
            Divider()
            Form {
                Section {
                    TextField("Title", text: $title)
                    LabeledContent("Category") {
                        Dropdown(selection: $categoryID, options: [.init(value: nil, title: "None", icon: .circleSlash)]
                                 + session.categories.map { .init(value: $0.id, title: $0.name, icon: $0.icon) }, minWidth: 190)
                    }
                    if sync.isConfigured {
                        LabeledContent("Sync") {
                            Dropdown(selection: $syncChoice, options: [
                                .init(value: .followCategory, title: "Follow the category", icon: .sync),
                                .init(value: .always, title: "Always sync", icon: .cloudUpload),
                                .init(value: .never, title: "Keep on this Mac", icon: .lock),
                            ], minWidth: 190)
                        }
                    }
                    if type == .login || type == .dbCredential || type == .apiKey {
                        TextField(type == .apiKey ? "Account / owner" : "Username", text: $username)
                    }
                    TextField("Websites (comma separated)", text: $urls)
                    TextField("Tags (comma separated)", text: $tags)
                }
                Section("Secrets") {
                    ForEach(type.fieldKeys, id: \.self) { key in
                        if key == "totpSeed" {
                            AuthenticatorKeyField(text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })) { label in
                                // A QR code names the service and the login: fill what is still empty.
                                if title.trimmingCharacters(in: .whitespaces).isEmpty, let issuer = label?.issuer { title = issuer }
                                if username.isEmpty, let account = label?.account { username = account }
                            }
                        } else {
                            secretField(key)
                        }
                    }
                }
                Section("Apps") {
                    ForEach(bundleIDs, id: \.self) { b in
                        HStack(spacing: Theme.Space.s) {
                            if let icon = appIcon(b) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                            Text(runningApps.first { $0.id == b }?.name ?? b)
                            Spacer()
                            IconButton(.close, help: "Unlink", diameter: 24) { bundleIDs.removeAll { $0 == b } }
                        }
                    }
                    MenuButton(title: "Link a running app", icon: .plug, compact: true) {
                        runningApps.filter { !bundleIDs.contains($0.id) }.map { app in
                            MenuItem(title: app.name, image: appIcon(app.id)) { bundleIDs.append(app.id) }
                        }
                    }
                    .help("Quick Access shows this item first when that app is in front")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: Theme.Space.s) {
                Spacer()
                PillButton("Cancel", icon: .close, kind: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
                PillButton("Save", icon: .check, kind: .primary) { save() }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 520, height: editorHeight)
        .excludedFromCapture()
    }

    @ViewBuilder
    private func secretField(_ key: String) -> some View {
        let isSecret = ItemType.secretFieldKeys.contains(key)
        let binding = Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
        if key == "notes" || key == "privateKey" || key == "publicKey" {
            VStack(alignment: .leading, spacing: 4) {
                Text(Theme.label(key)).font(Theme.caption).foregroundStyle(.secondary)
                TextEditor(text: binding)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: key == "notes" ? 60 : 90)
            }
        } else {
            HStack {
                if isSecret && !revealed.contains(key) {
                    SecureField(Theme.label(key), text: binding)
                } else {
                    TextField(Theme.label(key), text: binding).font(.system(size: 13, design: isSecret ? .monospaced : .default))
                }
                if isSecret {
                    IconButton(revealed.contains(key) ? .eyeClosed : .eye, help: revealed.contains(key) ? "Hide" : "Show", diameter: 24) {
                        if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
                    }
                    if key == "password" || key == "apiKey" || key == "secret" || key == "passphrase" {
                        IconButton(.sparkle, help: "Generate a strong value", diameter: 24) {
                            fields[key] = PasswordGenerator.generate(); revealed.insert(key)
                        }
                    }
                }
            }
        }
    }

    private func appIcon(_ bundleID: String) -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private func save() {
        let split: (String) -> [String] = { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        var o = existing ?? ItemOverview(type: type, title: "")
        o.type = type
        o.title = title.trimmingCharacters(in: .whitespaces)
        o.username = username.isEmpty ? nil : username
        o.urls = split(urls)
        o.tags = split(tags)
        o.favorite = favorite
        o.categoryID = categoryID
        o.bundleIDs = bundleIDs
        let cleaned = fields.filter { !$0.value.isEmpty }
        sync.setChoice(syncChoice, for: o.id)
        onSave(o, ItemDetails(fields: cleaned, history: []))
        dismiss()
    }
}
