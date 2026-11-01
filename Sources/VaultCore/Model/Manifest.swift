import Clibsodium
import Foundation

/// `manifest.vman`: the vault-level commit point. Lists every item's current version,
/// carries a monotonic generation, and binds the header bytes. MAC'd with the manifest
/// sub-key so an untrusted remote cannot roll back, drop, or re-label anything unnoticed.
public struct Manifest: Codable, Equatable, Sendable {
    public static let fileName = "manifest.vman"

    public var generation: UInt64
    public var deviceID: UUID
    /// SHA-256 of the current `vault.vhdr` bytes.
    public var headerHash: Data
    /// Keyed by `UUID.uuidString`; JSON cannot key objects by UUID.
    public var versions: [String: UInt64]

    public init(generation: UInt64 = 0, deviceID: UUID, headerHash: Data, versions: [String: UInt64] = [:]) {
        self.generation = generation
        self.deviceID = deviceID
        self.headerHash = headerHash
        self.versions = versions
    }

    public func version(of id: UUID) -> UInt64? {
        versions[id.uuidString]
    }

    public mutating func set(version: UInt64, for id: UUID) {
        versions[id.uuidString] = version
    }

    public var itemIDs: [UUID] {
        versions.keys.compactMap(UUID.init(uuidString:))
    }

    /// Throws if `self` (read from a remote or disk) is older than what this device last saw.
    public func checkNotRolledBack(against lastSeen: UInt64) throws {
        if generation < lastSeen {
            throw VaultError.rollbackDetected(local: lastSeen, remote: generation)
        }
    }
}

public enum ManifestFile {
    static let macBytes = Int(crypto_auth_hmacsha256_bytes())

    /// `json ‖ HMAC-SHA256(json)`.
    public static func encode(_ manifest: Manifest, key: SecureBytes) throws -> Data {
        Sodium.ensureReady()
        guard key.count == Int(crypto_auth_hmacsha256_keybytes()) else { throw VaultError.cryptoFailure }
        let json = try JSONCoding.encoder.encode(manifest)
        var mac = [UInt8](repeating: 0, count: macBytes)
        json.withUnsafeBytes { j in
            key.withUnsafeBytes { k in
                _ = crypto_auth_hmacsha256(&mac, j.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                           UInt64(json.count), k.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
        return json + mac
    }

    public static func decode(_ data: Data, key: SecureBytes) throws -> Manifest {
        Sodium.ensureReady()
        guard key.count == Int(crypto_auth_hmacsha256_keybytes()) else { throw VaultError.cryptoFailure }
        guard data.count > macBytes else { throw VaultError.corruptManifest }
        let json = data.prefix(data.count - macBytes)
        let mac = data.suffix(macBytes)
        let ok: Int32 = json.withUnsafeBytes { j in
            mac.withUnsafeBytes { m in
                key.withUnsafeBytes { k in
                    crypto_auth_hmacsha256_verify(m.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                  j.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                  UInt64(json.count),
                                                  k.baseAddress!.assumingMemoryBound(to: UInt8.self))
                }
            }
        }
        guard ok == 0, let manifest = try? JSONCoding.decoder.decode(Manifest.self, from: json) else {
            throw VaultError.corruptManifest
        }
        return manifest
    }

    public static func sha256(_ data: Data) -> Data {
        Sodium.ensureReady()
        var out = [UInt8](repeating: 0, count: Int(crypto_hash_sha256_bytes()))
        data.withUnsafeBytes { d in
            _ = crypto_hash_sha256(&out, d.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt64(data.count))
        }
        return Data(out)
    }
}
