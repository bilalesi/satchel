import SwiftUI
import VaultCore

/// The update affordance: one round icon button, nothing else. A download arrow when a newer
/// version exists, a progress ring while it downloads, a restart arrow when it is ready. The
/// explanation is the tooltip. Shown only when there is something to do.
struct UpdateIconButton: View {
    @EnvironmentObject var updates: UpdateManager

    var body: some View {
        if let model = Model(updates.state) {
            Button(action: act) {
                ZStack {
                    Circle().fill(model.failed ? Color.red : Color.accentColor)
                    if let p = model.progress {
                        Circle().stroke(Color.white.opacity(0.3), lineWidth: 2).padding(5)
                        Circle().trim(from: 0, to: max(0.04, p)).stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(5)
                    } else {
                        Icon(model.icon, size: 13).foregroundStyle(.white)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(model.enabled ? .link : nil)
            .disabled(!model.enabled)
            .tooltip(model.help)
            .accessibilityLabel(model.help)
            .transition(.scale.combined(with: .opacity))
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
        var icon: Codicon
        var progress: Double?
        var enabled = true
        var failed = false
        var help: String

        init?(_ state: UpdateManager.State) {
            switch state {
            case .idle, .checking: return nil
            case .available(let o):
                icon = .arrowDown; help = "Update available: download Satchel \(o.version)"
            case .downloading(let o, let p):
                icon = .arrowDown; progress = p; enabled = false; help = "Downloading Satchel \(o.version): \(Int(p * 100))%"
            case .ready(let o, _):
                icon = .debugRestart; help = "Restart to install Satchel \(o.version)"
            case .installing:
                icon = .sync; progress = 0.5; enabled = false; help = "Installing the update"
            case .failed(let m):
                icon = .warning; failed = true; help = "Update failed: \(m) Click to try again."
            }
        }
    }
}
