import SwiftUI
import VaultCore

/// Search → Enter copies the primary secret, ⌘Enter copies the username, Esc closes.
struct QuickAccessView: View {
    @EnvironmentObject var session: VaultSession
    @State private var query = ""
    @State private var selected: UUID?
    @State private var password = ""
    @State private var copiedTitle: String?
    @State private var typeError: String?
    @FocusState private var focused: Bool

    private var results: [ItemOverview] {
        session.search(query, frontmostBundleID: QuickAccessController.shared.frontmostBundleID, limit: 8)
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.state == .unlocked { searchUI } else { lockedUI }
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .onReceive(NotificationCenter.default.publisher(for: .quickAccessDidShow)) { _ in
            query = ""
            copiedTitle = nil
            typeError = nil
            selected = results.first?.id
            focused = true
            if session.state == .locked && session.touchIDEnabled {
                Task { await session.unlockWithBiometrics() }
            }
        }
        .onChange(of: query) { _, _ in selected = results.first?.id }
    }

    // MARK: Unlocked

    private var searchUI: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular))
                    .focused($focused)
                    .onSubmit { act(copyUsername: false) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { typeSelected(field: nil) }
                        else if press.modifiers.contains(.option) { typeSelected(field: "username") }
                        else if press.modifiers.contains(.control) { copyCode() }
                        else { act(copyUsername: press.modifiers.contains(.command)) }
                        return .handled
                    }
                if let app = QuickAccessController.shared.frontmostBundleID {
                    Text(appName(app)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.hairline, in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()
            if results.isEmpty {
                Text(query.isEmpty ? "No items yet" : "No matches").foregroundStyle(.secondary).padding(24)
            } else {
                VStack(spacing: 2) {
                    ForEach(results) { item in
                        row(item)
                    }
                }
                .padding(8)
            }
            Divider()
            HStack(spacing: 12) {
                hint("↩", "copy \(Theme.label(selectedType.primarySecretField).lowercased())")
                hint("⌘↩", "copy username")
                hint("⌃↩", "copy one-time code")
                if QuickAccessController.shared.frontmostApp != nil && AppSettings.autoTypeEnabled {
                    hint("⇧↩", "type into \(appName(QuickAccessController.shared.frontmostBundleID ?? ""))")
                    hint("⌥↩", "type username")
                }
                hint("esc", "close")
                Spacer()
                if let typeError {
                    Label(typeError, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                } else if let copiedTitle {
                    Label("Copied from \(copiedTitle)", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var selectedType: ItemType {
        results.first { $0.id == selected }?.type ?? .login
    }

    private var prompt: String {
        if let app = QuickAccessController.shared.frontmostBundleID, results.contains(where: { $0.bundleIDs.contains(app) }) {
            return "Items for \(appName(app))"
        }
        return "Search \(AppIdentity.name)"
    }

    private func row(_ item: ItemOverview) -> some View {
        let isSel = item.id == selected
        return HStack(spacing: 10) {
            IconTile(type: item.type, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium))
                Text([item.username, item.hosts.first].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(isSel ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
            if item.favorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(isSel ? .white : .yellow) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(isSel ? .white : .primary)
        .background(isSel ? Theme.accent(item.type) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { if $0 { selected = item.id } }
        .onTapGesture { selected = item.id; act(copyUsername: false) }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func move(_ delta: Int) {
        let r = results
        guard !r.isEmpty else { return }
        let i = r.firstIndex { $0.id == selected } ?? 0
        selected = r[max(0, min(r.count - 1, i + delta))].id
    }

    private func act(copyUsername: Bool) {
        guard let item = results.first(where: { $0.id == selected }) else { return }
        if copyUsername {
            if let u = item.username { session.copy(u) }
        } else {
            session.copyField(item.type.primarySecretField, of: item.id)
        }
        copiedTitle = item.title
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            QuickAccessController.shared.hide()
        }
    }

    private func copyCode() {
        guard let item = results.first(where: { $0.id == selected }) else { return }
        if let code = session.oneTimeCode(of: item.id) {
            session.copy(code)
            copiedTitle = item.title + " (one-time code)"
            Task { try? await Task.sleep(for: .milliseconds(350)); QuickAccessController.shared.hide() }
        } else {
            typeError = "\(item.title) has no one-time code"
        }
    }

    /// ⇧↩ / ⌥↩: hide the panel so the target app regains focus, then type.
    private func typeSelected(field: String?) {
        guard let item = results.first(where: { $0.id == selected }) else { return }
        let target = QuickAccessController.shared.frontmostApp
        let fieldName = field ?? item.type.primarySecretField
        QuickAccessController.shared.hide()
        Task {
            if let error = await session.typeField(fieldName, of: item.id, into: target) {
                typeError = error
                QuickAccessController.shared.show()
            }
        }
    }

    private func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    // MARK: Locked

    private var lockedUI: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            SecureField("Master password to unlock", text: $password)
                .textFieldStyle(.plain).font(.system(size: 16))
                .focused($focused)
                .onSubmit {
                    Task { await session.unlock(password: password); if session.state == .unlocked { password = ""; selected = results.first?.id } }
                }
            if session.touchIDEnabled {
                Button { Task { await session.unlockWithBiometrics() } } label: { Image(systemName: "touchid") }
                    .buttonStyle(.borderless)
            }
            if session.busy { ProgressView().controlSize(.small) }
        }
        .padding(16)
    }
}
