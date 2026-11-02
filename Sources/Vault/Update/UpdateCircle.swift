import SwiftUI
import VaultCore

/// The update affordance: a round button with a label pill next to it. A download arrow when
/// an update exists, a progress ring while it downloads, a restart arrow when it is ready.
struct UpdateCircle: View {
    @EnvironmentObject var updates: UpdateManager
    @State private var hovering = false

    var body: some View {
        if let model = Model(updates.state) {
            Button(action: act) {
                HStack(spacing: Theme.Space.s) {
                    Text(model.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.failed ? Color.red : Color.primary)
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs + 2)
                        .background(Color.primary.opacity(hovering ? 0.12 : 0.07), in: Capsule())
                    ZStack {
                        Circle().fill(model.failed ? Color.red : Color.accentColor)
                        if let p = model.progress {
                            Circle().stroke(Color.white.opacity(0.3), lineWidth: 2).padding(3)
                            Circle().trim(from: 0, to: max(0.03, p)).stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90)).padding(3)
                        } else {
                            Icon(model.icon, size: 13).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(model.enabled ? .link : .default)
            .disabled(!model.enabled)
            .onHover { hovering = $0 }
            .help(model.help)
            .accessibilityLabel(model.label)
            .animation(.easeOut(duration: 0.15), value: model.label)
        }
    }

    private func act() {
        switch updates.state {
        case .available, .failed: Task { await updates.download() }
        case .ready: Task { await updates.installAndRelaunch() }
        default: break
        }
    }

    private struct Model {
        var label: String
        var icon: Codicon
        var progress: Double?
        var enabled = true
        var failed = false
        var help: String

        init?(_ state: UpdateManager.State) {
            switch state {
            case .idle, .checking: return nil
            case .available(let o):
                label = "Update available"; icon = .arrowDown; help = "Download Satchel \(o.version)"
            case .downloading(let o, let p):
                label = "Downloading \(Int(p * 100))%"; icon = .arrowDown; progress = p; enabled = false; help = "Downloading Satchel \(o.version)"
            case .ready(let o, _):
                label = "Restart to update"; icon = .debugRestart; help = "Install Satchel \(o.version) and relaunch"
            case .installing:
                label = "Installing…"; icon = .sync; progress = 0.5; enabled = false; help = "Installing the update"
            case .failed(let m):
                label = "Update failed"; icon = .warning; failed = true; help = m + " Click to retry."
            }
        }
    }
}
