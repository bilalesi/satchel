import Foundation

/// BSD unix-domain socket helpers shared by the app (server) and the host (client).
public enum UnixSocket {
    static let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// Builds a `sockaddr_un` for `path`, or nil when the path is too long (104 bytes).
    public static func address(for path: String) -> sockaddr_un? {
        guard path.utf8.count < pathCapacity else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        var copy = addr.sun_path
        withUnsafeMutablePointer(to: &copy) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                path.withCString { _ = strlcpy(dst, $0, pathCapacity) }
            }
        }
        addr.sun_path = copy
        return addr
    }

    public static func connect(path: String) -> Int32? {
        guard var addr = address(for: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }

    /// Creates, binds (mode 0600) and listens. Removes a stale socket file first.
    public static func listen(path: String, backlog: Int32 = 8) throws -> Int32 {
        guard var addr = address(for: path) else { throw VaultError.io("socket path too long") }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultError.io("socket: \(String(cString: strerror(errno)))") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw VaultError.io("bind: \(String(cString: strerror(e)))") }
        chmod(path, 0o600)
        // Non-blocking so the accept loop can drain pending connections and return.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        guard Darwin.listen(fd, backlog) == 0 else { let e = errno; close(fd); throw VaultError.io("listen: \(String(cString: strerror(e)))") }
        return fd
    }

    /// Accepts one pending connection (blocking mode on the client) or nil when none is pending.
    public static func acceptPending(_ listenFD: Int32) -> Int32? {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return nil } // EWOULDBLOCK: nothing pending
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK) // BSD inherits O_NONBLOCK
        return client
    }

    /// Process on the other end of a connected unix socket.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return nil }
        return pid
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    public static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in Darwin.write(fd, ptr.baseAddress! + offset, data.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
