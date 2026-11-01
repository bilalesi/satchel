import AppKit
import CoreGraphics

/// Locks on screen lock, sleep, termination, and after system-wide idle time.
/// Idle comes from `CGEventSource.secondsSinceLastEventType`, which needs no permission
/// and no event monitor.
@MainActor
final class AutoLock {
    var idleSeconds: () -> TimeInterval
    private let onLock: @MainActor @Sendable () -> Void
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(idleSeconds: @escaping () -> TimeInterval, onLock: @escaping @MainActor @Sendable () -> Void) {
        self.idleSeconds = idleSeconds
        self.onLock = onLock

        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        let nc = NotificationCenter.default
        let lock: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in onLock() }
        }
        observers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock),
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock),
            ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lock),
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock),
            nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: lock),
        ]
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let limit = idleSeconds()
        guard limit > 0 else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= limit { onLock() }
    }
}
