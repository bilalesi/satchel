import SwiftUI
import VaultCore

struct ItemDetailView: View {
    @EnvironmentObject var session: VaultSession
    let overview: ItemOverview
    let onEdit: () -> Void

    @State private var details: ItemDetails?
    @State private var revealed: Set<String> = []
    @State private var copied: String?
    @State private var confirmDelete = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let details {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            if let u = overview.username { fieldRow("Username", u, secret: false) }
                            ForEach(overview.type.fieldKeys, id: \.self) { key in
                                if let v = details.fields[key], !v.isEmpty {
                                    if key == "totpSeed", let totp = TOTP(v) {
                                        oneTimeCodeRow(totp)
                                    }
                                    fieldRow(Theme.label(key), v, secret: ItemType.secretFieldKeys.contains(key), key: key)
                                }
                            }
                        }
                    }
                    if !overview.urls.isEmpty || !overview.bundleIDs.isEmpty { linksCard }
                    if !details.history.isEmpty { historyCard(details.history) }
                } else if let loadError {
                    Card { Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                meta
            }
            .padding(20)
        }
        .background(Theme.canvas)
        .task(id: overview.updatedAt) { load() }
        .confirmationDialog("Delete “\(overview.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { session.delete(overview.id) }
        } message: { Text("The item becomes a tombstone; its secrets are removed.") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(type: overview.type, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(overview.title).font(.system(size: 20, weight: .semibold))
                Text(overview.type.displayName).font(.system(size: 12)).foregroundStyle(Theme.accent(overview.type))
            }
            Spacer()
            Button { rotate() } label: { Label("Rotate", systemImage: "arrow.triangle.2.circlepath") }
                .help("Generate a new \(Theme.label(overview.type.primarySecretField).lowercased()); the old one is kept in history")
                .disabled(details == nil || !ItemType.secretFieldKeys.contains(overview.type.primarySecretField))
            Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
        }
    }

    private func fieldRow(_ label: String, _ value: String, secret: Bool, key: String = "") -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(secret && !revealed.contains(key) ? String(repeating: "•", count: min(value.count, 18)) : value)
                    .font(.system(size: 13, design: secret ? .monospaced : .default))
                    .textSelection(.enabled)
                    .lineLimit(key == "notes" || key == "privateKey" ? nil : 2)
            }
            Spacer()
            HStack(spacing: 4) {
                if secret {
                    Button {
                        if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
                    } label: { Image(systemName: revealed.contains(key) ? "eye.slash" : "eye") }
                }
                Button {
                    session.copy(value)
                    copied = label
                    Task { try? await Task.sleep(for: .seconds(1.5)); if copied == label { copied = nil } }
                } label: { Image(systemName: copied == label ? "checkmark" : "doc.on.doc") }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 14) }
    }

    /// Live one-time code with a countdown; copy puts the code (not the seed) on the clipboard.
    private func oneTimeCodeRow(_ totp: TOTP) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let code = totp.code(at: ctx.date)
            let left = totp.secondsRemaining(at: ctx.date)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("One-time code").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code)
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        ZStack {
                            Circle().stroke(Theme.hairline, lineWidth: 3)
                            Circle().trim(from: 0, to: CGFloat(left) / CGFloat(totp.period))
                                .stroke(left <= 5 ? Color.orange : Theme.accent(.login), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(left)").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        }
                        .frame(width: 24, height: 24)
                    }
                }
                Spacer()
                Button {
                    session.copy(code)
                    copied = "One-time code"
                    Task { try? await Task.sleep(for: .seconds(1.5)); if copied == "One-time code" { copied = nil } }
                } label: { Image(systemName: copied == "One-time code" ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().padding(.leading, 14) }
        }
    }

    private var linksCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where it is used").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(overview.urls, id: \.self) { u in
                    Link(destination: URL(string: u.contains("://") ? u : "https://" + u) ?? URL(fileURLWithPath: "/")) {
                        Label(u, systemImage: "globe").font(.system(size: 12))
                    }
                }
                ForEach(overview.bundleIDs, id: \.self) { b in
                    Label(appName(b), systemImage: "app").font(.system(size: 12))
                }
            }
        }
    }

    private func historyCard(_ history: [SecretRevision]) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("History").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Array(history.enumerated()), id: \.offset) { _, rev in
                    HStack {
                        Text(Theme.label(rev.field)).font(.system(size: 12))
                        Text(rev.changedAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") { session.copy(rev.value) }.buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
            }
        }
    }

    private var meta: some View {
        HStack(spacing: 12) {
            Text("Created \(overview.createdAt, format: .dateTime.day().month().year())")
            Text("Updated \(overview.updatedAt, format: .relative(presentation: .named))")
            if !overview.tags.isEmpty { Text(overview.tags.map { "#" + $0 }.joined(separator: " ")) }
        }
        .font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    private func load() {
        do { details = try session.details(overview.id); loadError = nil }
        catch { details = nil; loadError = error.localizedDescription }
    }

    private func rotate() {
        guard var d = details else { return }
        d.fields[overview.type.primarySecretField] = PasswordGenerator.generate()
        session.save(overview, d)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}
