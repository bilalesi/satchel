import Clibsodium
import Foundation

/// A fixed-size byte buffer for secrets.
///
/// Backed by `sodium_malloc`: guard pages on both sides, `mlock`ed so it does not
/// reach swap, canary-checked, and zeroed by `sodium_free` on `deinit`.
/// Reason: Swift `String`/`Data` copy freely and never zero; this is the one type
/// allowed to hold key material, passwords and decrypted secrets.
public final class SecureBytes: @unchecked Sendable {
    private let pointer: UnsafeMutableRawPointer
    public let count: Int

    public init(count: Int) {
        Sodium.ensureReady()
        precondition(count >= 0)
        // sodium_malloc(0) is legal but we always allocate at least one byte so the
        // pointer is non-null and guard pages exist.
        guard let p = sodium_malloc(max(count, 1)) else {
            preconditionFailure("sodium_malloc failed")
        }
        sodium_memzero(p, max(count, 1)) // sodium_malloc pre-fills with 0xdb
        pointer = p
        self.count = count
    }

    public convenience init(copying bytes: some Collection<UInt8>) {
        self.init(count: bytes.count)
        withUnsafeMutableBytes { dst in
            var i = 0
            for b in bytes { dst[i] = b; i += 1 }
        }
    }

    public convenience init(data: Data) {
        self.init(count: data.count)
        withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self))
        }
    }

    /// For passwords typed in the UI. The source `String` cannot be wiped; callers
    /// must drop it immediately after this call.
    public convenience init(utf8 string: String) {
        self.init(copying: Array(string.utf8))
    }

    deinit {
        sodium_free(pointer) // zeroes before releasing
    }

    public func wipe() {
        sodium_memzero(pointer, max(count, 1))
    }

    public var isAllZero: Bool {
        count == 0 || sodium_is_zero(pointer.assumingMemoryBound(to: UInt8.self), count) == 1
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }

    /// Explicit copy out of secure memory. Use only at the boundary where a plain
    /// `Data` is unavoidable (e.g. ciphertext that is about to be written to disk).
    public func toData() -> Data {
        withUnsafeBytes { Data($0) }
    }

    /// Explicit copy into a `String`. Use only in a single expression at the output
    /// boundary (pasteboard, text field), never stored.
    public func utf8String() -> String? {
        withUnsafeBytes { String(bytes: $0, encoding: .utf8) }
    }
}

extension SecureBytes: Equatable {
    /// Constant-time comparison.
    public static func == (lhs: SecureBytes, rhs: SecureBytes) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.count == 0 { return true }
        return lhs.withUnsafeBytes { a in
            rhs.withUnsafeBytes { b in
                sodium_memcmp(a.baseAddress, b.baseAddress, lhs.count) == 0
            }
        }
    }
}
