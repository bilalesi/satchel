import Foundation
import CryptoKit

public struct GitConfig: Codable, Equatable, Sendable {
    /// Anything `git` can clone over ssh or https, e.g. git@github.com:me/vault.git
    public var url: String
    public var branch: String
    /// Folder inside the repository, "" for the root. Normalised to end with "/".
    public var prefix: String

    public init(url: String, branch: String = "main", prefix: String = "") {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.branch = branch.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : branch.trimmingCharacters(in: .whitespaces)
        var p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !p.isEmpty { p += "/" }
        self.prefix = p
    }

    /// Rejects values that git would read as options or as exotic transports.
    public var isValid: Bool {
        !url.isEmpty && !url.hasPrefix("-") && !url.contains("::") && url.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
            && !branch.hasPrefix("-") && !branch.contains("..") && branch.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
            && !prefix.hasPrefix("-") && !prefix.contains("..")
    }
}

/// Git over SSH (or https) through the system `git` and the user's own SSH keys or credential
/// helper. Works against any host: GitHub, GitLab, Gitea, a bare repo on a NAS.
///
/// Reads and writes happen in a local clone. A sync round is one batch: fetch, apply the
/// round's changes, one commit, one push. A rejected push (another device pushed first) is a
/// `SyncError.conflict`, so the engine just retries against the new head. Etags are git blob ids.
public final class GitStore: BatchingRemoteStore, @unchecked Sendable {
    public let config: GitConfig
    private let dir: URL
    private let allowedProtocols: String
    private let lock = NSLock()
    private var inBatch = false
    private var batchLock = AsyncGate()

    public var displayName: String { "Git " + config.url }

    public init(config: GitConfig, cacheRoot: URL, allowedProtocols: String = "ssh:https") throws {
        guard config.isValid else { throw SyncError.remote(status: 0, message: "That repository address is not valid.") }
        self.config = config
        self.allowedProtocols = allowedProtocols
        let id = SHA256.hash(data: Data("\(config.url)|\(config.branch)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        self.dir = cacheRoot.appendingPathComponent(id, isDirectory: true)
    }

    public static var defaultCacheRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("git-cache", isDirectory: true)
    }

    // MARK: RemoteStore

    public func get(_ path: String) async throws -> RemoteObject? {
        try await readOp { try self.readFile(path) }
    }

    public func list(prefix: String) async throws -> [String: String] {
        try await readOp {
            let folder = self.dir.appendingPathComponent(self.config.prefix + prefix, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
            var out: [String: String] = [:]
            for name in names where !name.hasPrefix(".") {
                var isDir: ObjCBool = false
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                      let data = try? Data(contentsOf: url) else { continue }
                out[prefix + name] = GitBlob.sha(data)
            }
            return out
        }
    }

    public func put(_ path: String, data: Data, ifMatch: String?) async throws -> String {
        try await writeOp {
            let current = try self.readFile(path)?.etag
            guard current == ifMatch else { throw SyncError.conflict(path) }
            let target = self.file(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFile.write(data, to: target)
            return GitBlob.sha(data)
        }
    }

    public func delete(_ path: String, ifMatch: String?) async throws {
        try await writeOp {
            guard let current = try self.readFile(path) else { return }
            if let ifMatch, current.etag != ifMatch { throw SyncError.conflict(path) }
            try FileManager.default.removeItem(at: self.file(path))
        }
    }

    public func probeConditionalWrites() async throws -> ProbeResult {
        try await withBatch { try await self.defaultProbe() }
    }

    // MARK: Batching

    public func withBatch<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await batchLock.enter()
        defer { batchLock.leave() }
        try await syncDown()
        setBatch(true)
        defer { setBatch(false) }
        let result: T
        do { result = try await body() } catch {
            try? await discardLocalChanges()
            throw error
        }
        try await publish()
        return result
    }

    private func setBatch(_ on: Bool) { lock.withLock { inBatch = on } }
    private var batching: Bool { lock.withLock { inBatch } }

    /// Outside a batch every read refreshes from the remote first.
    private func readOp<T: Sendable>(_ body: @Sendable () throws -> T) async throws -> T {
        if batching { return try body() }
        return try await withBatch { try body() }
    }

    /// Outside a batch a single write is its own fetch-commit-push.
    private func writeOp<T: Sendable>(_ body: @Sendable () throws -> T) async throws -> T {
        if batching { return try body() }
        return try await withBatch { try body() }
    }

    // MARK: Files

    private func file(_ path: String) -> URL { dir.appendingPathComponent(config.prefix + path) }

    private func readFile(_ path: String) throws -> RemoteObject? {
        let url = file(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return RemoteObject(data: data, etag: GitBlob.sha(data))
    }

    // MARK: Git

    private func ensureRepo() async throws {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await git(["init", "-q", "-b", config.branch])
        try await git(["remote", "add", "origin", config.url])
    }

    /// Makes the working tree equal the remote branch (or empty when the remote has no commits yet).
    private func syncDown() async throws {
        try await ensureRepo()
        let r = try await git(["fetch", "-q", "--depth", "1", "origin", config.branch], allowFailure: true)
        if r.status == 0 {
            try await git(["checkout", "-q", "-f", "-B", config.branch, "FETCH_HEAD"])
            try await git(["clean", "-fdxq"])
        } else if r.stderr.contains("couldn't find remote ref") || r.stderr.contains("Couldn't find remote ref") {
            try await discardLocalChanges() // brand new, empty remote
        } else {
            throw Self.map(r.stderr)
        }
    }

    private func discardLocalChanges() async throws {
        if (try await git(["rev-parse", "-q", "--verify", "HEAD"], allowFailure: true)).status == 0 {
            try await git(["reset", "-q", "--hard"])
        } else {
            try await git(["rm", "-rfq", "--cached", "--ignore-unmatch", "."], allowFailure: true)
        }
        try await git(["clean", "-fdxq"])
    }

    private func publish() async throws {
        try await git(["add", "-A"])
        let staged = try await git(["diff", "--cached", "--quiet"], allowFailure: true)
        guard staged.status == 1 else { return } // nothing changed: no commit, no push
        try await git(["commit", "-q", "-m", "vault: sync"])
        let r = try await git(["push", "-q", "origin", "HEAD:refs/heads/\(config.branch)"], allowFailure: true)
        guard r.status == 0 else {
            try? await discardLocalChanges()
            throw Self.map(r.stderr, pushing: true)
        }
    }

    /// Checks git is installed and the repository is reachable. Returns nothing on success.
    public func verify() async throws {
        _ = try await Self.locateGit()
        let r = try await git(["ls-remote", "-q", "--exit-code", config.url], allowFailure: true, inRepo: false)
        // 2 = reachable but no matching refs (an empty repository is fine)
        guard r.status == 0 || r.status == 2 else { throw Self.map(r.stderr) }
    }

    static func map(_ stderr: String, pushing: Bool = false) -> SyncError {
        let s = stderr.lowercased()
        if pushing, s.contains("rejected") || s.contains("non-fast-forward") || s.contains("fetch first") || s.contains("failed to update ref") {
            return .conflict("git push")
        }
        if s.contains("permission denied") || s.contains("authentication failed") || s.contains("could not read username") {
            return .remote(status: 0, message: "Git could not sign in. Add your SSH key to the agent (ssh-add --apple-use-keychain) or use a deploy key without a passphrase.")
        }
        if s.contains("host key verification failed") {
            return .remote(status: 0, message: "The server's SSH host key changed or is unknown. Check it with ssh in Terminal first.")
        }
        if s.contains("could not resolve") || s.contains("connection") || s.contains("timed out") || s.contains("network") {
            return .network(stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "network error")
        }
        if s.contains("repository not found") || s.contains("does not appear to be a git repository") {
            return .notFound("the repository")
        }
        return .remote(status: 0, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "git failed")
    }

    // MARK: Process

    struct GitResult { var status: Int32; var stdout: String; var stderr: String }

    static func locateGit() async throws -> String {
        if let p = lockedGit { return p }
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] where FileManager.default.isExecutableFile(atPath: candidate) {
            if let r = try? await run(candidate, ["--version"], cwd: nil, env: [:]), r.status == 0 {
                lockedGit = candidate
                return candidate
            }
        }
        throw SyncError.remote(status: 0, message: "Git is not installed. Run `xcode-select --install` in Terminal, then try again.")
    }
    private static let gitCache = GitPathCache()
    private static var lockedGit: String? {
        get { gitCache.value }
        set { gitCache.value = newValue }
    }

    @discardableResult
    private func git(_ args: [String], allowFailure: Bool = false, inRepo: Bool = true) async throws -> GitResult {
        let exe = try await Self.locateGit()
        let base = ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Satchel", "-c", "user.email=satchel@localhost",
                    "-c", "commit.gpgsign=false", "-c", "protocol.ext.allow=never", "-c", "core.autocrlf=false",
                    "-c", "gc.auto=0", "-c", "advice.detachedHead=false"]
        var env = [
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ALLOW_PROTOCOL": allowedProtocols,
            "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20",
        ]
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { env["SSH_AUTH_SOCK"] = sock }
        let r = try await Self.run(exe, base + args, cwd: inRepo ? dir : nil, env: env)
        if r.status != 0, !allowFailure { throw Self.map(r.stderr) }
        return r
    }

    static func run(_ exe: String, _ args: [String], cwd: URL?, env: [String: String]) async throws -> GitResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = cwd
            var environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C"]
            environment.merge(env) { _, new in new }
            p.environment = environment
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            let buffers = Buffers()
            out.fileHandleForReading.readabilityHandler = { buffers.appendOut($0.availableData) }
            err.fileHandleForReading.readabilityHandler = { buffers.appendErr($0.availableData) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                buffers.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                buffers.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                let (o, e) = buffers.snapshot()
                cont.resume(returning: GitResult(status: proc.terminationStatus, stdout: o, stderr: e))
            }
            do { try p.run() } catch { cont.resume(throwing: SyncError.network(error.localizedDescription)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) { if p.isRunning { p.terminate() } }
        }
    }

    private final class Buffers: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func appendOut(_ d: Data) { lock.withLock { out.append(d) } }
        func appendErr(_ d: Data) { lock.withLock { err.append(d) } }
        func snapshot() -> (String, String) { lock.withLock { (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) } }
    }
}

private final class GitPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?
    var value: String? { get { lock.withLock { path } } set { lock.withLock { path = newValue } } }
}

/// A mutual-exclusion gate usable across `await` (a batch spans network calls).
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if held { waiters.append(c); lock.unlock() } else { held = true; lock.unlock(); c.resume() }
        }
    }

    func leave() {
        lock.lock()
        if waiters.isEmpty { held = false; lock.unlock() } else { let next = waiters.removeFirst(); lock.unlock(); next.resume() }
    }
}
