#!/usr/bin/env swift
// Ed25519 keys for signing app updates.
//   swift scripts/update-key.swift generate          prints "private <base64>" and "public <base64>"
//   swift scripts/update-key.swift sign <file>       signature (base64) of <file>; key from $UPDATE_SIGNING_KEY
//   swift scripts/update-key.swift verify <file> <sigfile> <public-key-file>
// The private key is the raw 32-byte seed, base64. Keep it secret; the app embeds only the public key.
import CryptoKit
import Foundation

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print("private \(key.rawRepresentation.base64EncodedString())")
    print("public \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    guard args.count == 2, let seedText = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
          let seed = Data(base64Encoded: seedText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
          let data = FileManager.default.contents(atPath: String(args[args.startIndex + 1])) else { fail("usage: UPDATE_SIGNING_KEY=… sign <file>") }
    print(try key.signature(for: data).base64EncodedString())
case "verify":
    let a = Array(args)
    guard a.count == 4, let data = FileManager.default.contents(atPath: a[1]),
          let sigText = try? String(contentsOfFile: a[2], encoding: .utf8),
          let pubText = try? String(contentsOfFile: a[3], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let pub = Data(base64Encoded: pubText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { fail("usage: verify <file> <sigfile> <public-key-file>") }
    if key.isValidSignature(sig, for: data) { print("ok") } else { fail("signature does not match") }
default:
    fail("usage: generate | sign <file> | verify <file> <sigfile> <public-key-file>")
}
