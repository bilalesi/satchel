import AppKit
import Foundation
import VaultCore

// vault-host: spawned by the browser for the extension. Relays native-messaging frames
// between stdin/stdout and the app's unix socket, adding the caller's origin to each
// request. Holds no keys, keeps no state; one request in flight at a time.

let socketPath = AppIdentity.bridgeSocketURL.path

/// Chromium passes `chrome-extension://<id>/` as argv[1]; Firefox passes the manifest
/// path then the extension id.
func callerOrigin() -> String {
    let args = Array(CommandLine.arguments.dropFirst())
    if let o = args.first(where: { $0.hasPrefix("chrome-extension://") }) { return o }
    if let id = args.first(where: { $0.contains("@") || ($0.hasPrefix("{") && $0.hasSuffix("}")) }) { return id }
    return args.last ?? ""
}

/// The app bundle this host lives in: Contents/MacOS/vault-host → ../../..
func launchApp() {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app" else { return }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false
    cfg.addsToRecentItems = false
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in sem.signal() }
    _ = sem.wait(timeout: .now() + 5)
}

func connectWithLaunch() -> Int32? {
    if let fd = UnixSocket.connect(path: socketPath) { return fd }
    launchApp()
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
        if let fd = UnixSocket.connect(path: socketPath) { return fd }
    }
    return nil
}

func readFrame(_ fd: Int32) -> Data? {
    var decoder = NativeMessageFraming.Decoder()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        do { if let msg = try decoder.next() { return msg } } catch { return nil } // oversized frame: drop the app connection
        let n = read(fd, &buf, buf.count)
        if n <= 0 { return nil }
        decoder.append(Data(buf[0..<n]))
    }
}

func reply(_ id: Any, error: String) {
    let obj: [String: Any] = ["id": id, "ok": false, "error": error]
    if let json = try? JSONSerialization.data(withJSONObject: obj) {
        FileHandle.standardOutput.write(NativeMessageFraming.frame(json))
    }
}

let origin = callerOrigin()
var appFD: Int32? = nil
var stdinDecoder = NativeMessageFraming.Decoder()
let stdinHandle = FileHandle.standardInput

while true {
    var request: Data?
    while request == nil {
        // Browsers cap a message at 1 MiB: anything larger is not a browser, and the frame would never complete.
        do { if let m = try stdinDecoder.next() { request = m; break } } catch { exit(1) }
        let chunk = stdinHandle.availableData
        if chunk.isEmpty { exit(0) } // browser closed the port
        stdinDecoder.append(chunk)
    }
    guard var obj = (try? JSONSerialization.jsonObject(with: request!)) as? [String: Any] else {
        reply(0, error: "bad_request"); continue
    }
    obj["origin"] = origin
    let id = obj["id"] ?? 0
    guard let payload = try? JSONSerialization.data(withJSONObject: obj) else { reply(id, error: "bad_request"); continue }

    if appFD == nil { appFD = connectWithLaunch() }
    guard let fd = appFD else { reply(id, error: "app_not_running"); continue }

    if !UnixSocket.writeAll(fd, NativeMessageFraming.frame(payload)) {
        close(fd); appFD = nil
        reply(id, error: "app_disconnected"); continue
    }
    guard let response = readFrame(fd) else {
        close(fd); appFD = nil
        reply(id, error: "app_disconnected"); continue
    }
    FileHandle.standardOutput.write(NativeMessageFraming.frame(response))
}
