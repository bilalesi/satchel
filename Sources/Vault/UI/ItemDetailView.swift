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
                        let rows = fieldRows(details)
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                switch row {
                                case let .field(label, value, secret, key): fieldRow(label, value, secret: secret, key: key)
                                case let .code(totp): oneTimeCodeRow(totp)
                                }
                                if index < rows.count - 1 { Divider().padding(.leading, Theme.Space.l) }
                            }
                        }
                        // Hover highlights stay inside the card's rounded corners.
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }
                    if !overview.urls.isEmpty || !overview.bundleIDs.isEmpty { linksCard }
                    if !details.history.isEmpty { historyCard(details.history) }
                } else if let loadError {
                    Card { Label { Text(loadError) } icon: { Icon(.warning) }.foregroundStyle(.red) }
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
        let rotateHelp = "Generate a new \(Theme.label(overview.type.primarySecretField).lowercased()); the old one is kept in history"
        let canRotate = details != nil && ItemType.secretFieldKeys.contains(overview.type.primarySecretField)
        return HStack(spacing: Theme.Space.s) {
            if labels {
                PillButton("Rotate", icon: .refresh) { rotate() }.help(rotateHelp).disabled(!canRotate)
                PillButton("Edit", icon: .edit) { onEdit() }.help("Edit this item")
            } else {
                IconButton(.refresh, help: "Rotate", kind: .secondary, diameter: 30) { rotate() }.disabled(!canRotate)
                IconButton(.edit, help: "Edit", kind: .secondary, diameter: 30) { onEdit() }
            }
            IconButton(.trash, help: "Delete", kind: .danger, diameter: 30) { confirmDelete = true }
        }
        .fixedSize()
    }


    private enum FieldRow {
        case field(label: String, value: String, secret: Bool, key: String)
        case code(TOTP)
    }

    private func fieldRows(_ details: ItemDetails) -> [FieldRow] {
        var rows: [FieldRow] = []
        if let u = overview.username { rows.append(.field(label: "Username", value: u, secret: false, key: "username")) }
        for key in overview.type.fieldKeys {
            guard let v = details.fields[key], !v.isEmpty else { continue }
            if key == "totpSeed", let totp = TOTP(v) { rows.append(.code(totp)) }
            rows.append(.field(label: Theme.label(key), value: v, secret: ItemType.secretFieldKeys.contains(key), key: key))
        }
        return rows
    }

    /// Fixed mask length: the dots never reveal how long a secret is.
    private static let mask = String(repeating: "•", count: 12)

    private func fieldRow(_ label: String, _ value: String, secret: Bool, key: String) -> some View {
        let shown = !secret || revealed.contains(key)
        let multiline = key == "notes" || key == "privateKey"
        return HStack(alignment: multiline ? .top : .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(label).font(Theme.caption).foregroundStyle(.secondary)
                Text(shown ? value : Self.mask)
                    .font(shown && secret ? Theme.body.monospaced() : Theme.body)
                    .tracking(shown ? 0 : 1)
                    .foregroundStyle(shown ? .primary : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(multiline ? nil : 2)
            }
            Spacer(minLength: Theme.Space.s)
            // Fixed-size circles: eye/eye-closed and copy/check swaps never move the row.
            HStack(spacing: 2) {
                if secret {
                    IconButton(revealed.contains(key) ? .eyeClosed : .eye, help: revealed.contains(key) ? "Hide" : "Show") {
                        if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
                    }
                }
                IconButton(copied == label ? .check : .copy, help: copied == label ? "Copied" : "Copy \(label.lowercased())") {
                    session.copy(value)
                    copied = label
                    Task { try? await Task.sleep(for: .seconds(1.5)); if copied == label { copied = nil } }
                }
                .foregroundStyle(copied == label ? Color.green : Color.secondary)
            }
        }
        // Trailing inset is smaller because the 28pt circle pads its glyph by 7pt:
        // the icon's edge then sits as far from the card edge as the text does on the left.
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.s)
        .padding(.vertical, Theme.Space.m)
        .frame(minHeight: 60)
        .hoverHighlight(radius: 0)
    }


    /// Live one-time code with a countdown; copy puts the code (not the seed) on the clipboard.
    private func oneTimeCodeRow(_ totp: TOTP) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let code = totp.code(at: ctx.date)
            let left = totp.secondsRemaining(at: ctx.date)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("One-time code").font(Theme.caption).foregroundStyle(.secondary)
                    HStack(spacing: Theme.Space.s) {
                        Text(code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code)
                            .font(.system(size: 22, weight: .light)).monospacedDigit()
                            .contentTransition(.numericText())
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
                IconButton(copied == "One-time code" ? .check : .copy, help: "Copy one-time code") {
                    session.copy(code)
                    copied = "One-time code"
                    Task { try? await Task.sleep(for: .seconds(1.5)); if copied == "One-time code" { copied = nil } }
                }
            }
            .padding(.leading, Theme.Space.l)
            .padding(.trailing, Theme.Space.s)
            .padding(.vertical, Theme.Space.m)
            .frame(minHeight: 60)
            .hoverHighlight(radius: 0)
        }
    }

    /// Card padding 8 + row padding 8 = text at 16pt, the same edge as the section label.
    private var linksCard: some View {
        Card(padding: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Where it is used")
                    .padding(.horizontal, Theme.Space.s).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.xs)
                ForEach(overview.urls, id: \.self) { u in
                    Link(destination: URL(string: u.contains("://") ? u : "https://" + u) ?? URL(fileURLWithPath: "/")) {
                        linkRow(Text(u)) { Icon(.globe, size: 14).foregroundStyle(.secondary).frame(width: 20, height: 20) }
                    }
                    .pointerStyle(.link)
                }
                ForEach(overview.bundleIDs, id: \.self) { b in
                    linkRow(Text(appName(b)).foregroundStyle(.primary)) {
                        if let icon = appIcon(b) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else {
                            Icon(.extensions, size: 14).foregroundStyle(.secondary).frame(width: 20, height: 20)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func linkRow<I: View>(_ title: Text, @ViewBuilder icon: () -> I) -> some View {
        HStack(spacing: Theme.Space.s) {
            icon()
            title.font(Theme.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 32)
        .contentShape(Rectangle())
        .hoverHighlight()
    }

    private func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private func historyCard(_ history: [SecretRevision]) -> some View {
        Card(padding: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "History")
                    .padding(.horizontal, Theme.Space.s).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.xs)
                ForEach(Array(history.enumerated()), id: \.offset) { _, rev in
                    HStack(spacing: Theme.Space.s) {
                        Text(Theme.label(rev.field)).font(Theme.body)
                        Text(rev.changedAt, format: .dateTime.day().month().year().hour().minute())
                            .font(Theme.caption).foregroundStyle(.secondary)
                        Spacer()
                        PillButton("Copy", icon: .copy, kind: .ghost, compact: true) { session.copy(rev.value) }
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: 32)
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
            // displayName keeps ".app" when Finder shows extensions; the user wants the app's name.
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundleID
    }
}

