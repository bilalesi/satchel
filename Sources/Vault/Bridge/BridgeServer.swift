import Foundation
import Security
import VaultCore

/// Listens on the unix socket for `satchel-host` connections. Each frame is decoded,
/// handled on the main actor, and answered in order. The peer must be the host executable
/// inside this app's own bundle, spawned by a browser signed by a known vendor; the host
/// takes the extension origin from its argv, so any other parent could claim any origin.
/// ponytail: same-user malware can still inject into the browser; documented in the threat model.
final class BridgeServer: @unchecked Sendable {
    /// Apple Team IDs of the browsers allowed to spawn the host. Read off the installed apps with
    /// `codesign -dv`: Chrome EQHXZ8M8AV, Firefox 43AQ936H96, Arc and Dia S6N382Y83G. The rest are the
    /// vendors' published IDs, not checked on a machine here: Edge UBF8T346G9, Brave KL8N8XSYF4,
    /// Vivaldi 4XF3XNRN6Y, Opera A2P9LX4JPN. An unsigned Chromium build is refused.
    static let browserTeamIDs = ["EQHXZ8M8AV", "43AQ936H96", "S6N382Y83G", "UBF8T346G9", "KL8N8XSYF4", "4XF3XNRN6Y", "A2P9LX4JPN"]

    /// Signed by Apple's chain and one of the Team IDs above. Kept as a string (Sendable) and parsed
    /// per connection: one accept per browser launch, so the parse cost does not matter.
    private static let browserRequirement = "anchor apple generic and ("
        + browserTeamIDs.map { "certificate leaf[subject.OU] = \"\($0)\"" }.joined(separator: " or ") + ")"
    typealias Handler = @MainActor (BridgeRequest) async -> BridgeResponse

    private let fd: Int32
    private let queue = DispatchQueue(label: AppIdentity.bundleID + ".bridge")
    private let acceptSource: DispatchSourceRead
    private let handler: Handler
    private let bundlePath: String

    init(socketURL: URL = AppIdentity.bridgeSocketURL, handler: @escaping Handler) throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = try UnixSocket.listen(path: socketURL.path)
        self.handler = handler
        bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        acceptSource.setEventHandler { [weak self] in self?.acceptPending() }
        acceptSource.resume()
    }

    deinit {
        acceptSource.cancel()
        close(fd)
    }

    private func acceptPending() {
        while let client = UnixSocket.acceptPending(fd) {
            guard peerAllowed(client) else { close(client); continue }
            serve(client)
        }
    }

    private func peerAllowed(_ client: Int32) -> Bool {
        guard let pid = UnixSocket.peerPID(client), let path = UnixSocket.executablePath(of: pid) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(bundlePath + "/"), resolved.hasSuffix("/" + AppIdentity.hostExecutableName) else { return false }
        // The isolated debug copy is driven by scripts/bridge-smoke.sh, which spawns the host itself.
        if AppIdentity.isIsolatedCopy { return true }
        guard let parent = UnixSocket.parentPID(of: pid), parent > 1 else { return false }
        return Self.isBrowser(parent)
    }

    /// True when the process is signed by one of the allowed browser vendors (chain verified by Security.framework).
    static func isBrowser(_ pid: pid_t) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(browserRequirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    private func serve(_ client: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        let state = ConnectionState()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(client, &buf, buf.count)
            if n <= 0 { source.cancel(); return }
            state.decoder.append(Data(buf[0..<n]))
            while let frame = (try? state.decoder.next()) ?? nil {
                self.dispatch(frame, to: client, state: state)
            }
        }
        source.setCancelHandler { close(client) }
        source.resume()
    }

    private func dispatch(_ frame: Data, to client: Int32, state: ConnectionState) {
        let handler = self.handler
        let queue = self.queue
        let request = try? JSONDecoder().decode(BridgeRequest.self, from: frame)
        // Serialise per connection so answers keep request order.
        let previous = state.chain
        state.chain = Task {
            await previous?.value
            let response: BridgeResponse
            if let request { response = await handler(request) }
            else { response = .failure(0, "bad_request") }
            let json = (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
            queue.async { _ = UnixSocket.writeAll(client, NativeMessageFraming.frame(json)) }
        }
    }

    private final class ConnectionState: @unchecked Sendable {
        var decoder = NativeMessageFraming.Decoder()
        var chain: Task<Void, Never>?
    }
}
