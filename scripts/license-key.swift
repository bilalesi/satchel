#!/usr/bin/env swift
// Ed25519 keys for Satchel licences (a separate pair from the update key).
//   swift scripts/license-key.swift generate                       prints "private <base64>" and "public <base64>"
//   swift scripts/license-key.swift issue <single|family> <yyyy-MM-dd> <id>
//                                                                   licence key; private key from $LICENSE_SIGNING_KEY
// Keep the private key out of the repo (a password manager); Resources/license-public-key.txt holds the public half.
// The payload format must match License.payload in Sources/VaultCore/Licensing/License.swift.
import CryptoKit
import Foundation

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print("private \(key.rawRepresentation.base64EncodedString())")
    print("public \(key.publicKey.rawRepresentation.base64EncodedString())")
case "issue":
    guard args.count == 4, ["single", "family"].contains(args[1]),
          args[2].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
          !args[3].isEmpty, !args[3].contains("|"),
          let seedText = ProcessInfo.processInfo.environment["LICENSE_SIGNING_KEY"],
          let seed = Data(base64Encoded: seedText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("usage: LICENSE_SIGNING_KEY=… issue <single|family> <yyyy-MM-dd> <id>")
    }
    let payload = Data("1|\(args[1])|\(args[2])|\(args[3])".utf8)
    print("SATCHEL-" + b64url(payload) + "." + b64url(try key.signature(for: payload)))
default:
    fail("usage: generate | issue <single|family> <yyyy-MM-dd> <id>")
}
