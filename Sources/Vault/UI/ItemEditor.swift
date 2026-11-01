import SwiftUI
import VaultCore

struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss
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

    init(type: ItemType, overview: ItemOverview?, details: ItemDetails?, onSave: @escaping (ItemOverview, ItemDetails) -> Void) {
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
            HStack(spacing: 10) {
                IconTile(type: type, size: 28)
                Text(existing == nil ? "New \(type.displayName)" : "Edit \(type.displayName)")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Toggle(isOn: $favorite) { Image(systemName: favorite ? "star.fill" : "star") }
                    .toggleStyle(.button).buttonStyle(.borderless)
            }
            .padding(16)
            Divider()
            Form {
                Section {
                    TextField("Title", text: $title)
                    if type == .login || type == .dbCredential || type == .apiKey {
                        TextField(type == .apiKey ? "Account / owner" : "Username", text: $username)
                    }
                    TextField("Websites (comma separated)", text: $urls)
                    TextField("Tags (comma separated)", text: $tags)
                }
                Section("Secrets") {
                    ForEach(type.fieldKeys, id: \.self) { key in
                        secretField(key)
                    }
                }
                Section("Apps") {
                    ForEach(bundleIDs, id: \.self) { b in
                        HStack {
                            Text(runningApps.first { $0.id == b }?.name ?? b)
                            Spacer()
                            Button { bundleIDs.removeAll { $0 == b } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Menu("Link a running app") {
                        ForEach(runningApps, id: \.id) { app in
                            Button(app.name) { if !bundleIDs.contains(app.id) { bundleIDs.append(app.id) } }
                        }
                    }
                    .help("Quick Access shows this item first when that app is in front")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520, height: 560)
        .excludedFromCapture()
    }

    @ViewBuilder
    private func secretField(_ key: String) -> some View {
        let isSecret = ItemType.secretFieldKeys.contains(key)
        let binding = Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
        if key == "notes" || key == "privateKey" || key == "publicKey" {
            VStack(alignment: .leading, spacing: 4) {
                Text(Theme.label(key)).font(.system(size: 11)).foregroundStyle(.secondary)
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
                    Button { if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) } } label: {
                        Image(systemName: revealed.contains(key) ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    if key == "password" || key == "apiKey" || key == "secret" || key == "passphrase" {
                        Button { fields[key] = PasswordGenerator.generate(); revealed.insert(key) } label: {
                            Image(systemName: "wand.and.stars")
                        }
                        .buttonStyle(.borderless)
                        .help("Generate")
                    }
                }
            }
        }
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
        o.bundleIDs = bundleIDs
        let cleaned = fields.filter { !$0.value.isEmpty }
        onSave(o, ItemDetails(fields: cleaned, history: []))
        dismiss()
    }
}
