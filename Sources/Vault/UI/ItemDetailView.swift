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
            VStack(alignment: .leading, spacing: Theme.Space.l) {
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
            .padding(Theme.Space.xl)
            // Readable line length on wide windows; values stay next to their copy buttons.
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .task(id: overview.updatedAt) { load() }
        .confirmationDialog("Delete “\(overview.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { session.delete(overview.id) }
        } message: { Text("The item becomes a tombstone; its secrets are removed.") }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(type: overview.type, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(overview.title).font(Theme.title).lineLimit(1)
                Text(overview.type.displayName).font(Theme.caption).foregroundStyle(Theme.accent(overview.type))
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            // Labeled buttons when there is room, icon-only (with tooltips) when narrow.
            ViewThatFits(in: .horizontal) {
                actions(labels: true)
                actions(labels: false)
            }
        }
    }

    private func actions(labels: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button { rotate() } label: {
                Label("Rotate", systemImage: "arrow.triangle.2.circlepath").detailLabel(labels)
            }
            .help("Generate a new \(Theme.label(overview.type.primarySecretField).lowercased()); the old one is kept in history")
            .disabled(details == nil || !ItemType.secretFieldKeys.contains(overview.type.primarySecretField))
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil").detailLabel(labels)
            }
            .help("Edit this item")
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .help("Delete this item")
        }
        .fixedSize()
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
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .hoverHighlight(radius: 0)
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
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .hoverHighlight(radius: 0)
            .overlay(alignment: .bottom) { Divider().padding(.leading, 14) }
        }
    }

    private var linksCard: some View {
        Card(padding: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel(text: "Where it is used")
                ForEach(overview.urls, id: \.self) { u in
                    Link(destination: URL(string: u.contains("://") ? u : "https://" + u) ?? URL(fileURLWithPath: "/")) {
                        Label(u, systemImage: "globe").font(Theme.body)
                            .padding(.vertical, Theme.Space.xs).padding(.horizontal, Theme.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hoverHighlight()
                    }
                    .pointerStyle(.link)
                }
                ForEach(overview.bundleIDs, id: \.self) { b in
                    Label(appName(b), systemImage: "app").font(Theme.body)
                        .padding(.vertical, Theme.Space.xs).padding(.horizontal, Theme.Space.s)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func historyCard(_ history: [SecretRevision]) -> some View {
        Card(padding: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                SectionLabel(text: "History").padding(.bottom, Theme.Space.xs)
                ForEach(Array(history.enumerated()), id: \.offset) { _, rev in
                    HStack(spacing: Theme.Space.s) {
                        Text(Theme.label(rev.field)).font(Theme.body)
                        Text(rev.changedAt, format: .dateTime.day().month().year().hour().minute())
                            .font(Theme.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") { session.copy(rev.value) }.buttonStyle(.borderless).font(Theme.caption)
                    }
                    .padding(.vertical, Theme.Space.xs).padding(.horizontal, Theme.Space.s)
                    .hoverHighlight()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var meta: some View {
        HStack(spacing: Theme.Space.m) {
            Text("Created \(overview.createdAt, format: .dateTime.day().month().year())")
            Text("Updated \(overview.updatedAt, format: .relative(presentation: .named))")
            if !overview.tags.isEmpty { Text(overview.tags.map { "#" + $0 }.joined(separator: " ")) }
        }
        .font(Theme.caption).foregroundStyle(.tertiary)
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

private extension View {
    /// System label styles keep the title as the accessibility name even when only the icon shows.
    @ViewBuilder func detailLabel(_ showTitle: Bool) -> some View {
        if showTitle { labelStyle(.titleAndIcon) } else { labelStyle(.iconOnly) }
    }
}
