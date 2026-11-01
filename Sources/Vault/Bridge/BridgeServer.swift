import Foundation
import VaultCore

/// Listens on the unix socket for `vault-host` connections. Each frame is decoded,
/// handled on the main actor, and answered in order. The peer must be an executable
/// inside this app's own bundle; other processes are dropped.
/// ponytail: same-user malware can copy the bundle; a Team ID requirement would need a
/// paid developer identity. Documented in the investigation threat model.
final class BridgeServer: @unchecked Sendable {
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
        guard let path = UnixSocket.peerExecutablePath(client) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix(bundlePath + "/") && resolved.hasSuffix("/vault-host")
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
