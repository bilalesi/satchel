<div align="center">

<p>
<img src="https://satchel.echospace.dev/satchel.png" width="96" height="96" alt=""><br>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://satchel.echospace.dev/brand/satchel-wordmark-cream.png">
  <img src="https://satchel.echospace.dev/brand/satchel-wordmark-ink.png" width="157" height="40" alt="Satchel">
</picture>
</p>

**A native macOS vault for the secrets developers work with.**<br>
Encrypted on your Mac. Synced through storage you already own. No account, no Satchel server.

[Website](https://satchel.echospace.dev) &nbsp;&nbsp; [Download](https://satchel.echospace.dev/download) &nbsp;&nbsp; [Security model](https://satchel.echospace.dev/security) &nbsp;&nbsp; [Sponsor](https://github.com/sponsors/bilalesi)

<br>

<img src="https://satchel.echospace.dev/og.png" width="820" alt="Satchel: your secrets, your Mac, your cloud">

</div>

<br>

Satchel keeps logins with their one-time codes, API keys, database connections, webhooks, notes and SSH keys in one
place, each with the fields it needs. It unlocks with a master password or Touch ID, answers ⌥ Space from any app,
fills logins in the browser, and syncs through iCloud Drive, Dropbox, a NAS, GitHub, any git host, WebDAV or
S3-compatible storage. Only ciphertext leaves the Mac.

macOS 15 or later, Apple silicon or Intel.

## Contents

- [Design](#design)
- [Security model](#security-model)
- [Sync](#sync)
- [Browser integration](#browser-integration)
- [Architecture](#architecture)
- [Build and test](#build-and-test)
- [Using Satchel](#using-satchel)
- [Licence and pricing](#licence-and-pricing)
- [Support the project](#support-the-project)

## Design

| Principle | In practice |
|---|---|
| **Local first** | The vault is a folder of encrypted files on your Mac. Every feature works offline. |
| **Bring your own sync** | Sync is a storage interface with six backends. Satchel never hosts your data. |
| **Native** | SwiftUI and AppKit, Swift 6 strict concurrency. One third-party dependency: libsodium. |
| **Verifiable** | The source is public. Every claim on this page points at code you can read. |
| **Never locked out** | No licence state, sync error or update can make a vault unreadable. Export is always available. |

## Security model

### Keys

```
master password ── Argon2id (256 MiB, 3 passes, salted) ──▶ password KEK ──┐
                                                                           ├─▶ unwraps ─▶ vault key (256-bit, random)
Touch ID ──── Secure Enclave P-256 key agreement ─────────▶ enclave KEK ───┘                  │
                                                                                     HKDF-SHA256 │ info:
                                                    ┌──────────────┬──────────────┬──────────────┤
                                                  "item"       "overview"     "manifest"    "local-secret"
                                                 secrets       metadata      manifest MAC    sync credentials,
                                                                                             never synced
```

The master password and Touch ID never encrypt items. Each only unwraps a copy of the vault key, so changing the
password or turning on Touch ID rewraps 32 bytes and re-encrypts nothing. The password is never stored, not even in the
Keychain. The Secure Enclave key cannot leave the Mac it was created on.

### Primitives

| Purpose | Primitive | Notes |
|---|---|---|
| Password stretching | Argon2id (libsodium `crypto_pwhash`) | 256 MiB, 3 passes; parameters live in the vault header so they can be raised later |
| Item and key encryption | XChaCha20-Poly1305-IETF | Random 24-byte nonce per box |
| Sub-key derivation | HKDF-SHA256 | One key per purpose, from the vault key |
| Manifest integrity | HMAC-SHA256 | Keyed with the manifest sub-key |
| Touch ID slot | Secure Enclave P-256 (CryptoKit) | Ephemeral key agreement wraps the vault key |
| Update and licence signatures | Ed25519 | Separate key pairs; public halves are built into the app |

Secrets are held in `SecureBytes`, backed by `sodium_malloc`: guard pages on both sides, locked out of swap,
canary-checked, and zeroed when freed. They never pass through Swift arrays.

### On disk and on the remote

```
vault.vhdr              header: KDF parameters, key slots (password, Touch ID)
manifest.vman           json ‖ HMAC-SHA256: every item's version, a generation counter, SHA-256 of the header
items/<uuid>.vitem      header(41 bytes) ‖ u32 ‖ overview box ‖ u32 ‖ details box
```

The 41-byte item header is the additional authenticated data of both boxes, so a box cannot be moved to another item
or replayed under another version. Search reads only the overview box; the details box is opened when you view or copy
a secret.

### Rollback and tampering

The manifest's generation only grows. A remote that serves an older manifest, drops an item, edits a file or relabels
one fails verification, and sync stops with an explanation instead of reverting anything. A remote that is suddenly
empty is treated the same way: Satchel uploads nothing until you choose **Start over**.

### Around the Mac

- Windows are excluded from screenshots and screen sharing unless you allow them.
- The clipboard clears itself after a delay you choose.
- The vault locks on idle, sleep and screen lock.

### What Satchel cannot protect against

Malware running as you while the vault is unlocked, a weak master password, and a forgotten one: there is no reset and
no recovery key held by anyone.

Full threat model and design notes: [docs/INVESTIGATION.md](docs/INVESTIGATION.md) and
[satchel.echospace.dev/security](https://satchel.echospace.dev/security).

## Sync

Each workspace syncs through one backend, set in **Settings → Sync**.

| Backend | Target | Concurrency control |
|---|---|---|
| Synced folder | iCloud Drive, Dropbox, an SMB share, a USB drive | Compare-then-write on content hashes |
| GitHub | A private repository, fine-grained token with Contents: Read and write | Blob SHAs; one commit per change |
| Git | Any repository your SSH key can push to | A rejected push is a conflict, retried on the new head; one commit per sync round |
| WebDAV | Nextcloud, ownCloud, a NAS, any `mod_dav` server, over https | `If-Match` / `If-None-Match: *` on ETags |
| S3-compatible | AWS S3, Cloudflare R2, MinIO, Backblaze B2 | Conditional `PutObject` on ETags |

**Guarantees**

- Before trusting a WebDAV or S3 server, Satchel proves it refuses a second create of the same object and a write over
  a changed one. A server that accepts either would let two Macs overwrite each other, so Satchel refuses it.
- Two Macs editing different items merge cleanly. The same item edited on both: the newer edit wins, the other
  version's secrets go into the item's history, the item is tagged `conflict`, and both Macs converge on the same bytes.
- A folder that is not there (an unmounted share, an ejected drive) is reported as unavailable, never as an empty
  remote, and is never created.
- Each Mac chooses what it uploads, per category or per item. Items kept local are never sent.
- Credentials for the sync target are encrypted inside the vault with the `local-secret` sub-key and never synced.

Every backend can be tested against a real server; see the live tests under [Build and test](#build-and-test).

## Browser integration

```
extension (Dia, Arc, Chrome, Firefox)
   │  native messaging (stdio, length-prefixed JSON)
   ▼
satchel-host  ── unix socket ──▶  Satchel.app   (vault, matching, fill decisions)
```

- The browser launches `satchel-host`, a small relay; the app makes every decision.
- The host manifest allows only Satchel's extension IDs, and the app checks the caller's origin again.
- Logins are offered by registrable domain from the Public Suffix List, so `accounts.google.com.evil.io` does not match
  `google.com`. Only the top frame is filled, only after a click or ⌘⇧L, and forms are never submitted.
- The extension makes no network requests and stores nothing.

## Architecture

| Target | Role |
|---|---|
| `VaultCore` | Crypto, file formats, the vault store, sync engine and backends, search, browser matching, licensing, updates. No UI. |
| `Satchel` (`Sources/Vault`) | The SwiftUI and AppKit app: session, Quick Access, auto-type, settings, sync coordinator, updater. |
| `satchel-host` (`Sources/VaultHost`) | The native messaging relay between the browser and the app. |
| `extension/` | The browser extension, plain JavaScript, no build step and no dependencies. |
| `VaultCoreTests` | Unit tests, fakes for every HTTP backend, a real-git backend test, and opt-in live tests. |

Dependencies: [swift-sodium](https://github.com/jedisct1/swift-sodium), used through its raw C API (`Clibsodium`) so
secrets stay in libsodium's secure memory. Everything else is the macOS SDK.

## Build and test

Requires Xcode 26 (Swift 6.3).

```bash
swift build                     # debug build
swift test                      # the full suite
scripts/install.sh              # build, sign ad hoc, install to /Applications
scripts/demo.sh                 # an isolated copy on throwaway demo vaults, next to your real app
UNIVERSAL=1 VERSION=0.1.0 scripts/make-dmg.sh    # build/Satchel-0.1.0.dmg
```

Live tests run the sync backends against real servers and are skipped unless configured:

```bash
SATCHEL_FOLDER_TEST_ROOT=~/some-share   swift test --filter FolderStoreTests
SATCHEL_WEBDAV_TEST_URL=http://localhost:8088/dav   swift test --filter WebDAVStoreTests/testLiveServer
SATCHEL_GIT_TEST_URL=ssh://git@localhost:2222/srv/git/vault.git   swift test --filter GitStoreTests/testLiveServer
SATCHEL_S3_TEST_ENDPOINT=… SATCHEL_S3_TEST_BUCKET=… SATCHEL_S3_TEST_ACCESS_KEY=… SATCHEL_S3_TEST_SECRET=… \
  swift test --filter S3StoreTests/testLiveBucket
```

### Releases

Every push to `main` that changes the app runs [`release.yml`](.github/workflows/release.yml): tests, a universal
build (version `0.1.<commit count>`), Developer ID signing with hardened runtime, notarization and stapling, an Ed25519
update signature, and an upload to a private Cloudflare R2 bucket. The website serves the download and the update feed
from there; nothing is published on GitHub. Installed apps verify the size, SHA-256 and signature before installing.

## Using Satchel

| | |
|---|---|
| Quick Access | ⌥ Space from any app, type, Return to copy |
| Fill in the browser | Click a suggestion under a login field, or ⌘⇧L |
| Auto-type into other apps | Quick Access, then ⇧↩ (secret) or ⌥↩ (username) |
| Lock | ⇧⌘L, the menu bar icon, or automatically on idle, sleep and screen lock |
| Workspaces | Separate vaults, each with its own password, Touch ID and sync |
| Second Mac | On the first screen, **Connect an existing vault** |

The full user guide is on [satchel.echospace.dev](https://satchel.echospace.dev).

## Licence and pricing

Satchel is paid software with public source. Every feature is free for 7 days; then a licence is **€23, once**, for one
person on all their Macs, with a year of updates and the last version of that year kept for good. No subscription, no
account: the licence is an Ed25519-signed key checked offline. After the trial, without a key, Satchel still unlocks
and exports, so your data is never held hostage.

The code is public so it can be audited; it is not open source. Terms: [LICENSE](LICENSE).

## Support the project

Satchel is built by one person. If it is useful to you, you can
[sponsor its development on GitHub](https://github.com/sponsors/bilalesi), or simply
[buy a licence](https://satchel.echospace.dev/pricing).

## Contributing and security

- Contributions through forks and pull requests; read [CONTRIBUTING.md](CONTRIBUTING.md) first.
- Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md). Please do not open public issues for
  them.

## Credits

Cryptography by [libsodium](https://libsodium.org). Icons: [Codicons](https://github.com/microsoft/vscode-codicons)
by Microsoft (CC BY 4.0). Site matching: the [Public Suffix List](https://publicsuffix.org). Full notices:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
