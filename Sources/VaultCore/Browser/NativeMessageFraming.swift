import Foundation

/// Native messaging wire format, reused between the host and the app:
/// `u32 little-endian length ‖ UTF-8 JSON`. Browsers cap messages at 1 MiB.
public enum NativeMessageFraming {
    public static let maxLength = 1 << 20

    public static func frame(_ json: Data) -> Data {
        var len = UInt32(json.count).littleEndian
        var out = Data(bytes: &len, count: 4)
        out.append(json)
        return out
    }

    public struct Decoder: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) {
            buffer.append(data)
        }

        /// Next complete message, or nil when more bytes are needed.
        public mutating func next() throws -> Data? {
            guard buffer.count >= 4 else { return nil }
            // Index relative to startIndex: a Data that has been sliced does not start at 0.
            let start = buffer.startIndex
            let len = Int(buffer[start..<start + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard len <= maxLength else { throw VaultError.io("native message too large (\(len) bytes)") }
            guard buffer.count >= 4 + len else { return nil }
            let msg = Data(buffer[(start + 4)..<(start + 4 + len)])
            buffer = Data(buffer[(start + 4 + len)...])
            return msg
        }
    }
}
