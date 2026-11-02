# Native macOS Secret Vault — Investigation & Design Proposal

Date: 2026-11-01. Status: **proposal; decisions 1, 2, 3 and 6 taken by the owner (see §11); name pending**. Nothing is built yet.
Target machine seen during research: macOS 26.6.2, browsers Arc / Chrome / Firefox (+ Safari), apps DBeaver (Java), DBX, Discord (Electron), Microsoft Teams (Electron).

This document answers four questions:

1. What can a native macOS app actually do for autofill, and where does it need help (browser extension, accessibility fill)?
2. How should the vault be encrypted, unlocked (password / Touch ID), and stored so it is safe on an untrusted remote (GitHub, S3)?
3. What are the security mistakes to avoid, and what is the honest threat model?
4. What is the smallest build order that gives a usable product early?

Sources are listed at the end. Where a claim comes from community reports instead of Apple documentation, it is marked **(community)**.

---

## 1. Executive summary

- **Build it in Swift (SwiftUI + AppKit), one process, one dependency (libsodium).** No Rust core, no Electron, no Tauri. Rust is a reasonable future option only if Windows/Linux ever matter.
- **Autofill on macOS is three different mechanisms, not one.** The native app alone cannot fill into Chrome, Arc, Firefox, Discord, Teams or DBeaver. The honest matrix:

| Target | Mechanism | Phase |
|---|---|---|
| Safari, Mac apps with standard login fields | Apple **Credential Provider Extension** (system AutoFill, Touch ID gated, passkeys too) | 3 |
| Dia, Chrome, Arc, Firefox, Edge | **Browser extension** (WebExtension) talking to the app over **native messaging** | 4 (moved before 3, see §10) |
| Electron apps (Discord, Teams), Java apps (DBeaver), terminals, anything else | **Quick Access window** (global hotkey, search, copy or type) with Accessibility-based "auto-type" | 1 (copy) / 5 (type) |
| Everything, always | Copy to clipboard marked concealed + auto-clear | 1 |

- **Vault design: LUKS-style key slots + per-item encryption + signed manifest.** Random 256-bit vault key wraps every item; the vault key is itself wrapped once by the master password (Argon2id) and once by a Secure Enclave key (Touch ID). Adding Touch ID, changing the password, or adding a recovery key never re-encrypts items. The remote store (GitHub/S3) sees only ciphertext and cannot roll back or delete items without detection.
- **Sync: one encrypted file per item + conditional writes.** GitHub Contents API (`sha`) and S3 (`If-Match`) both give compare-and-swap for free. Conflicts are resolved per item, newest wins, loser kept as a conflict copy. No CRDT library needed.
- **Threat model is honest:** we protect data at rest, in transit, on the remote, and against other apps while locked. We do **not** protect against malware running as your user while the vault is unlocked, nor against a compromised kernel. No consumer password manager does, and claiming otherwise is the first "stupid idea" to avoid.
- **Piracy/licensing:** offline Ed25519-signed license keys. Perfect DRM is impossible in a native binary and not worth chasing; the vault's security does not depend on the license code.

---

## 2. What the user actually needs (restated)

| Need | Design answer |
|---|---|
| Store logins, API keys, webhooks, DB credentials, notes | Typed items: `login`, `apiKey`, `dbCredential`, `secureNote`, `sshKey`, `totp`. All share one envelope; the type only changes the UI fields. |
| Browse, search, add, remove, edit, rotate | Main window + Quick Access window. "Rotate" = generate new secret, keep old one in item history. |
| Suggestions when on Gmail login; fill with Touch ID | Browser extension (Chrome/Arc/Firefox) + Credential Provider (Safari). Touch ID via Secure Enclave key slot. |
| Fill into desktop apps (DBeaver, Discord, Teams) | Quick Access → copy, or auto-type into focused field. |
| Encrypted locally, decryptable by password or Touch ID | Argon2id slot + Secure Enclave slot. |
| Store the vault in GitHub private repo or S3; sync on change | Pluggable `RemoteStore` with two first implementations (GitHub Contents API, S3-compatible). Local folder / iCloud Drive comes for free. |
| Very good looking | SwiftUI with AppKit where SwiftUI falls short (menu bar, non-activating panel). Visual direction waits for the reference app you will share. |
| Browser extension only if needed | It **is** needed for Chrome/Arc/Firefox. There is no public API for a Mac app to fill into Chromium or Firefox form fields reliably (see §3). |

---

## 3. Autofill on macOS — what is real

### 3.1 Apple Credential Provider Extension (`ASCredentialProviderExtension`)

What it is: an app extension that plugs into the system's Password AutoFill. The user enables it in System Settings → General → AutoFill & Passwords. When Safari or a native app shows a login field, the system asks enabled providers for matching credentials and shows them in the system AutoFill menu. Touch ID gating is done by the system ("Use Touch ID for autofilling passwords").

Verified facts:

- Supported on macOS 13+. Supports passwords, passkeys (macOS 14+), and one-time codes (macOS 15/26 era). 1Password shipped this in 2025 and reports it works in Safari and "other supported desktop apps", i.e. apps using standard login text fields. **(community, 1Password forum)**
- The extension can hand the system credential *metadata* (site + username) so suggestions appear without unlocking; the password is fetched only on selection.
- **"Text to insert" (fill arbitrary text into any field) is iOS/iPadOS 18 only.** The `ProvidesTextToInsert` key documents no macOS availability; an Apple forum thread confirms macOS did not get it. **(Apple docs + community)** So this extension cannot fill an API key into DBeaver.
- **Chrome, Arc, Firefox do not consume third-party credential providers for passwords.** Chromium reaches Apple's own passwords through Apple's "iCloud Passwords" extension, and since macOS 15.5 Apple restricts that native messaging host to known browsers. Zen/Firefox-family users report the same gap. **(community)** Passkeys are a partial exception: Chromium on macOS 14+ can route passkey requests through the system dialog, and users report third-party providers appearing there, but behavior is inconsistent and Chrome often shows its own dialog. **(community)**
- Requires the `com.apple.developer.authentication-services.autofill-credential-provider` entitlement and a provisioning profile. Works with Developer ID distribution (outside the App Store). The extension must be sandboxed; it shares data with the app through an App Group container.

Verdict: build it, because it gives the best possible experience in Safari and native apps and unlocks passkeys later. But it is phase 3, not phase 1, and it does not cover your browsers.

### 3.2 Browser extension + native messaging (Chrome, Arc, Firefox, Edge)

This is how 1Password, Bitwarden and KeePassXC-Browser work. Architecture:

```
[page]──content script──▶[extension background]──native messaging (stdio)──▶[host binary in app bundle]──XPC/App Group──▶[vault app]
```

Verified facts:

- Chrome native messaging: the browser launches a host binary registered by a JSON manifest in `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/<name>.json`. The host speaks length-prefixed JSON over stdin/stdout. The manifest's `allowed_origins` restricts which extension IDs may connect, and the host receives the caller's origin as its first argument. `connectNative` keeps one host process alive for the port's lifetime. Arc and Edge use the same mechanism with their own manifest directories; Firefox uses `~/Library/Application Support/Mozilla/NativeMessagingHosts/` with `allowed_extensions`.
- Safari web extensions use a different bridge (a native app extension inside the app bundle). Since the Credential Provider already covers Safari, the Safari web extension is optional and deferred.
- One WebExtension codebase (MV3) runs on Chrome, Arc, Edge and Firefox with small manifest differences.

What the extension must do well (this is where password managers get hacked, see §6):

1. Match credentials on the **registrable domain (eTLD+1) of the top-level frame**, not substring, not title. Use the Public Suffix List.
2. Never fill into cross-origin iframes unless the user explicitly picks the credential for that frame's origin.
3. Never auto-submit. Never fill on page load without a user gesture (click on the field or on the suggestion).
4. Treat `http://` as a different origin from `https://` unless the item was saved as http.
5. Fill by setting the value **and** dispatching `input`/`change` events so React/Vue forms accept it.
6. Request Touch ID (via the app) before releasing the secret for sites marked "require authentication".

The native messaging host is tiny: it validates the browser's identity, relays JSON to the app, and dies with the port. The host **must not** hold vault keys. All decisions happen in the app process.

### 3.3 Accessibility "auto-type" (Electron, Java, terminals)

Two techniques, both need the Accessibility permission (System Settings → Privacy → Accessibility):

| Technique | How | Works where | Fails where |
|---|---|---|---|
| **AX value set** | `AXUIElementSetAttributeValue(focused, kAXValueAttribute, text)` | Native AppKit fields, many Java/SWT fields | Web/Electron fields often ignore it (no `input` event, React state not updated) **(community)**; fields that are not "settable" |
| **Synthetic keystrokes** | `CGEventPost` of key-down/up for each character (keyboard-layout aware) | Almost everything, including Electron | **Secure Input**: when an app (Terminal "Secure Keyboard Entry", any `NSSecureTextField`) enables secure event input, other processes cannot *observe* keys; whether *posted* keys are delivered is not documented and must be tested. KeePassXC ships a "Secure Input Mode" workaround. **(Apple TN2150 + community)** Also: the user must have the right field focused; typing goes wherever focus is. |

KeePassXC additionally needs Screen Recording permission to read window titles for matching. We can avoid that: match on the frontmost app's bundle identifier (available via `NSWorkspace` without any permission) and let the user pick the item in Quick Access.

Verdict: Quick Access + copy is phase 1 (zero permissions, works everywhere). Auto-type is phase 5, opt-in, with the AX attempt first and keystrokes as fallback. It is not sandbox-compatible (sandboxed apps cannot drive other apps via AX), which is one reason the main app ships outside the App Store (see §7).

### 3.4 Clipboard hygiene (phase 1)

- Write the secret with the `org.nspasteboard.ConcealedType` marker so clipboard managers (Maccy, Raycast, Alfred) skip it. 1Password, Bitwarden, KeePassXC follow this convention.
- Auto-clear after N seconds (default 30) **only if the clipboard still contains our value** (compare change count).
- Universal Clipboard (Handoff to iPhone): macOS has no per-item opt-out API (iOS has `localOnly`, macOS does not). Document this; offer a setting that tells the user to disable Handoff if they care.

### 3.5 Detecting "the user is on Gmail"

- In browsers: the extension knows the URL. The app never needs to see it.
- In desktop apps: the app knows the frontmost app's bundle id (`NSWorkspace.shared.frontmostApplication`). Items can be linked to bundle ids (`com.hnc.Discord`, `org.jkiss.dbeaver.product`). Window-title matching needs Screen Recording permission and is not worth it.

---

## 4. Recommended architecture

### 4.1 Processes

```
┌──────────────────────────── Vault.app (Developer ID, hardened runtime, notarized) ────────────────────────────┐
│ Main app (SwiftUI/AppKit)                                                                                    │
│  ├─ VaultEngine        crypto, key slots, item store, search index, auto-lock                                 │
│  ├─ SyncEngine         RemoteStore protocol → GitHubStore | S3Store | FolderStore                            │
│  ├─ QuickAccessPanel   NSPanel, non-activating, global hotkey, copy / auto-type                              │
│  ├─ MenuBarExtra       status, lock, sync                                                                    │
│  └─ XPC listener       serves the two helpers below; verifies caller's code signature (same Team ID)        │
│                                                                                                              │
│ Contents/PlugIns/CredentialProvider.appex   ASCredentialProviderExtension (sandboxed, App Group)   [phase 3] │
│ Contents/MacOS/native-messaging-host         stdio relay for Chrome/Arc/Firefox/Edge extension   [phase 4]  │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
browser-extension/ (separate repo folder, MV3 WebExtension, TypeScript)                            [phase 4]
```

Design pattern names, for the record: **Strategy** (RemoteStore backends), **Repository** (ItemStore over files), **Facade** (VaultEngine is the only thing UI and helpers talk to), **Ports and adapters** (crypto and storage behind protocols so tests use in-memory fakes).

### 4.2 Why Swift-only

- The user asked for native, high-performance, good-looking. SwiftUI/AppKit is the only stack where the menu bar, Touch ID, Secure Enclave, Credential Provider, XPC, and non-activating panels are first-class.
- Tauri/Electron: Ockam tried Tauri for a security tool and rewrote in SwiftUI because the result did not feel native. **(community)** Electron also rules out the Credential Provider extension's sandbox requirements in practice.
- Rust core + UniFFI: 1Password-style shared core makes sense when there are 3+ platforms. For one platform it doubles the type definitions at the FFI boundary. Keep the door open by keeping `VaultEngine` free of UI imports; defer.

### 4.3 Dependencies

| Need | Choice | Why |
|---|---|---|
| Argon2id, XChaCha20-Poly1305, secure memory (`sodium_malloc`, `sodium_mlock`, `sodium_memzero`) | **libsodium** via `swift-sodium` (SPM) | Apple CryptoKit has no Argon2 and no secure-memory helpers. One audited C library covers all three. |
| Secure Enclave, HKDF, SHA-256 | **CryptoKit** (system) | SE access is only possible through Apple frameworks. |
| Touch ID prompt | **LocalAuthentication** (system) | |
| HTTP (GitHub, S3) | **URLSession** (system) | S3 SigV4 signing is ~100 lines; no AWS SDK. |
| Git (generic remotes) | **deferred** | libgit2 Swift bindings are poorly maintained; GitHub covers the stated need via REST. Add libgit2 as an XCFramework only if GitLab/self-hosted git is required. |
| Public Suffix List | bundled data file | Domain matching in the extension. |
| Auto-update | **none** (decision 1: personal build from source) | Sparkle 2 only if the app is ever distributed. |

Total third-party native dependencies: one (libsodium).

---

## 5. Cryptographic design

### 5.1 Keys

```
master password ──Argon2id(salt_pw, m=64MiB, t=3, p=4)──▶ KEK_pw ──wrap──▶ slot[0] = Enc(VK)
Secure Enclave P-256 key (biometry-gated) ──ECDH+HKDF──▶ KEK_se ──wrap──▶ slot[1] = Enc(VK)
recovery key (optional, 256-bit, printed) ──HKDF──▶ KEK_rk ──wrap──▶ slot[2] = Enc(VK)

VK (random 256-bit vault key, never stored in clear)
 ├─ HKDF(VK, "item")      ──▶ K_items    : XChaCha20-Poly1305 per item
 ├─ HKDF(VK, "overview")  ──▶ K_overview : encrypts searchable metadata (title, urls, username, type)
 └─ HKDF(VK, "manifest")  ──▶ K_manifest : MACs the manifest (anti-rollback, anti-deletion)
```

Why this shape (this is the **LUKS / 1Password keyset** pattern):

- Changing the master password rewrites one small slot (wrapped key + nonce + tag, under 100 bytes), not the vault.
- Touch ID is an *additional* unwrap path with equal strength: the Secure Enclave private key never leaves the chip, and its use requires `biometryCurrentSet` (or `userPresence` if we want password-fallback inside the system dialog). Re-enrolling a fingerprint invalidates the key; the app then asks for the password and re-creates slot[1]. This is expected and must be handled, not treated as corruption.
- The recovery key exists because Argon2id + a strong passphrase is unrecoverable by design.
- **Overview vs details split (1Password pattern):** on unlock we decrypt only the overview blobs (a few KB per item) to build the search index and to answer the browser extension's "what matches gmail.com?" question. Passwords, API keys and notes stay encrypted until the user selects an item. Memory exposure is minimized and unlock of 5,000 items stays well under 100 ms after the KDF.

KDF parameters: RFC 9106's second recommendation (64 MiB, t=3, p=4) is the floor; Bitwarden ships 32 MiB / t=6 / p=4 and PBKDF2 600,000 as its minimum. Store the parameters in the vault header so they can be raised later; re-wrapping slot[0] is cheap. **Measured 2026-11-01 on the owner's Mac with libsodium (single lane, so p=1):** 64 MiB/t=3 = 73 ms, 256 MiB/t=3 = 324 ms, 512 MiB/t=3 = 676 ms. **Chosen default: 256 MiB, t=3, p=1**, inside the 300–700 ms target and four times the RFC floor's memory.

### 5.2 Item encryption

Each item is one file: `items/<uuidv7>.vitem`.

```
header   : magic "VIT1", item uuid, version (uint64, monotonic per item), updatedAt, deleted flag
overview : XChaCha20-Poly1305(K_overview, nonce_o, plaintext=json{type,title,urls,username,bundleIds,tags}, aad=header)
details  : XChaCha20-Poly1305(K_items,    nonce_d, plaintext=json{password|apiKey|..., notes, totpSeed, history[]}, aad=header)
```

- AAD binds ciphertext to its own uuid and version, so an attacker who controls the remote cannot swap item A's secret into item B or replay an old version as new.
- `history[]` keeps previous secrets with timestamps (this is "rotate" and also the undo for a bad sync merge). Capped at 10 by default.
- Separate random 24-byte nonces per blob; XChaCha20's 192-bit nonce makes random nonces safe without counters.

### 5.3 Manifest (defeats a malicious remote)

`manifest.vman` = MAC-protected list `{itemId: version}` plus `generation` (monotonic counter) and `deviceId`. On every sync:

- Verify MAC with `K_manifest`. Reject if it fails.
- Reject if the remote `generation` is lower than the last one this device saw (rollback attack).
- Any item present locally with a version the manifest does not know is a merge, not a deletion. Deletions are explicit tombstones (`deleted=true` items kept 90 days).

Without this, a GitHub/S3 provider (or anyone with a leaked token) could silently restore an old password or drop an item, and the client would accept it. This is the single most-overlooked attack on "zero-knowledge" sync.

### 5.4 Header file

`vault.vhdr` (plaintext JSON, integrity-protected by being included in the manifest MAC): format version, KDF params + salt, key slots (type, wrapped VK, nonce, SE key reference for slot[1] is **local-only** and lives in the macOS Keychain, not in the synced header), vault id, created date.

### 5.5 Secrets in memory

Swift has no secure string; `String` copies freely. Rules:

- Secrets are `SecureBytes` (a thin wrapper over `sodium_malloc` buffers: guard pages, `mlock`, zeroed on `deinit`). They never become `String` except at the moment of writing to the pasteboard or an AX field, and that `String` is created and dropped inside one scope.
- VK and derived keys live in `SecureBytes` and are zeroed on lock, on screen lock, on sleep, after idle timeout (default 10 min) and on app termination.
- `mlock` reduces swap exposure but is not a guarantee; FileVault (on by default on Apple silicon) is the real at-rest protection for swap. State this in the security doc rather than pretend.
- Vault windows set `NSWindow.sharingType = .none` so screen sharing and screenshots do not capture them. Quick Access reveals secrets only on explicit "show".

---

## 6. Security analysis

### 6.1 Threat model

| Adversary | Protected? | How |
|---|---|---|
| Thief with the powered-off Mac | Yes | Vault ciphertext + FileVault. Argon2id makes offline guessing cost ~0.5 s and 64 MiB per guess. |
| Someone who gets the vault files from GitHub/S3 (leaked token, provider breach) | Yes | Ciphertext only; no secret key material in the repo. Manifest MAC blocks tampering/rollback. |
| Malicious or compromised storage provider | Yes (detect) | Rollback and deletion detected via manifest `generation` and tombstones. Availability is not guaranteed (they can refuse to serve). |
| Phishing site that looks like gmail.com | Yes | Extension matches eTLD+1 of the top frame only; no fill into other origins; no auto-fill without gesture. |
| Another ordinary app on the Mac while vault is **locked** | Yes | Keys zeroed; files are ciphertext; Keychain item for SE is useless without the chip + biometry. |
| Other app while **unlocked**, running as your user (malware, malicious npm script) | **No** | It can read our memory, post synthetic clicks, read the clipboard. Mitigations only: short auto-lock, concealed-clipboard + auto-clear, Touch ID re-prompt for "sensitive" items, hardened runtime (blocks code injection into *our* process), `PT_DENY_ATTACH` (bypassable by root, still raises the bar). No password manager survives this adversary; say so in the docs. |
| Compromised browser or malicious extension | Partial | Native messaging host only accepts our extension ID; the app verifies the host's code signature over XPC. A fully compromised browser can still request credentials for sites it is on; Touch ID-gating sensitive items limits blast radius. |
| Compromised kernel / Apple | No | Out of scope. |

### 6.2 Mistakes to avoid ("stupid ideas" list)

1. **Inventing crypto or formats.** Use libsodium primitives exactly as documented; no custom modes, no "double encryption".
2. **Deriving the vault key directly from the password.** Then password change = re-encrypt everything, and Touch ID would require storing the password. Key slots fix this.
3. **Storing the master password, or anything derived from it, in Keychain "for Touch ID".** The SE key wraps VK; the password is never stored anywhere.
4. **Keeping metadata in plaintext for search speed.** Titles and usernames leak which services you use. The overview key solves speed without leaking.
5. **Trusting the remote.** No manifest MAC → silent rollback. Covered.
6. **Substring URL matching in the extension** (`url.contains("gmail.com")` matches `gmail.com.evil.io`). Use PSL + exact registrable domain.
7. **Filling into iframes or on load.** Historic password-manager CVEs (LastPass 2016/2017, several Chrome managers) were exactly this.
8. **Auto-submit.** Never.
9. **Secrets in logs, crash reports, analytics, URL query strings, `print()` debugging, SwiftUI previews.** Add a lint rule: no `String` type on any field named `password|secret|key|token`.
10. **Universal `Accessibility` + `Screen Recording` permission grab.** Request Accessibility only when the user enables auto-type; never request Screen Recording.
11. **Shipping with `com.apple.security.cs.disable-library-validation`, `allow-dyld-environment-variables`, or `get-task-allow`.** These let any dylib be injected into the process. Hardened runtime on, all three off. Notarize.
12. **Unsigned or HTTP updates.** Sparkle with EdDSA keys; the public key is in the app, the private key is offline.
13. **Writing secrets to the clipboard without the concealed marker, or never clearing.**
14. **Letting the native messaging host or the appex hold keys.** They are relays; the app process is the only key holder.
15. **Treating Touch ID as the master key.** Biometrics are an unlock *convenience*; re-enrollment must fall back to the password, and backups must never depend on the SE (it is device-bound).
16. **No recovery path.** Offer recovery key + encrypted export (the vault folder itself is the backup; it is already ciphertext).
17. **Mixing licensing with crypto.** If the license check fails the app may limit features, but it must never make the vault unreadable. Users' data is theirs.

### 6.3 Piracy / licensing

**Dropped (decision 1, §11): personal use only, so no licensing code.** If that changes later: offline Ed25519-signed license keys verified with an embedded public key, never tied to the vault's crypto. Perfect DRM in a native binary is not achievable and must never be allowed to make the vault unreadable.

### 6.4 Code-signing boundaries (the part that must be right)

- Main app ↔ appex: App Group container + XPC. Verify the peer's audit token: same Team ID, same bundle-id prefix, hardened-runtime flag set, not a debug build.
- Main app ↔ native messaging host: same check. The host additionally checks that its parent process is a known browser bundle (Chrome, Arc, Firefox, Edge) before relaying.
- Extension ↔ host: `allowed_origins` in the manifest, pinned to the published extension ID per browser store.

---

## 7. Sync design

### 7.1 Layout on the remote (identical for folder, GitHub, S3)

```
<root>/
  vault.vhdr               header (KDF params, key slots except SE)
  manifest.vman            MAC'd {itemId: version}, generation
  items/<uuid>.vitem       one encrypted item per file
```

One file per item is what makes git, S3 and conflict handling simple: a change touches one small object, uploads are incremental, and two devices editing different items never conflict.

### 7.2 Backends

| Backend | Write primitive | Conflict signal | Auth | Notes |
|---|---|---|---|---|
| Local folder / iCloud Drive / Dropbox | atomic rename | file mtime + manifest generation | none | Free, phase 2 first. |
| **GitHub private repo** (Contents API) | `PUT /repos/{o}/{r}/contents/{path}` with `sha` of the blob being replaced | 409/422 on stale `sha` | fine-grained PAT (contents: read/write) stored in Keychain | Operations must be serial (GitHub documents concurrent-write errors). One commit per item write is fine for a vault. No libgit2 needed. |
| **S3-compatible** (AWS, Cloudflare R2, MinIO, Backblaze B2) | `PutObject` with `If-Match: <etag>` (`If-None-Match: *` for create) | 412 Precondition Failed (also 404/409 edge cases) | access key + secret in Keychain; SigV4 signing | Needs `s3:GetObject` + `s3:PutObject`. |
| Generic git (GitLab, self-hosted) | libgit2 push | non-fast-forward | SSH key / token | Deferred until asked. |

Pattern: **optimistic concurrency / compare-and-swap** on every object, plus the manifest as the vault-level commit point.

### 7.3 Algorithm (per sync run)

1. Fetch remote manifest; verify MAC and `generation ≥ lastSeen`.
2. Diff against local manifest → `toPull`, `toPush`, `both` (changed on both sides since common base).
3. Pull: download, verify AAD, store.
4. Resolve `both`: newest `updatedAt` wins; the loser's details blob is appended to the winner's `history[]` and the user sees a "resolved conflict" badge. **Nothing is ever lost.** (KeePassXC's synchronize mode is the precedent: merge history, newest on top.)
5. Push: conditional write per item; on 409/412 go to step 1 (max 3 rounds).
6. Write manifest with `generation + 1`, conditional on the one we read.

Triggers: on every local change (debounced 2 s), on app unlock, every 15 min while unlocked, on network regain. Everything happens on a background actor; the UI never waits.

Why not a CRDT library: items are small documents edited by one person on two or three devices. Per-item last-writer-wins with history is what Bitwarden and KeePass do; a CRDT would add a dependency to solve a conflict that happens a few times a year.

---

### 7.4 Alternative backends (suggestions, not built)

Whatever the backend, the provider only ever holds ciphertext: items are encrypted per file, names are random UUIDs, the manifest is MAC'd and rollback is detected. So the provider choice decides **availability and metadata** (item count, sizes, update times), not confidentiality. Rules that apply to all of them: a private location only (ciphertext in a public place can be attacked offline against the master password); a credential scoped to one folder or bucket, revocable, stored encrypted next to the vault (as the GitHub token is); and a backend must **enforce conditional writes** (`If-Match` / non-fast-forward rejection), because the sync engine relies on them to avoid lost updates. Test that before trusting a server; some WebDAV servers ignore the header.

| Option | Why people use it | Security notes | Cost to add |
|---|---|---|---|
| **Synced folder** (iCloud Drive, Syncthing, Dropbox, Nextcloud client) | Already supported (Folder backend). Syncthing is peer-to-peer with no cloud at all; iCloud needs nothing to set up. | Credentials stay inside the sync client, not Satchel. Cloud clients can create "conflicted copy" files; they are ignored. No conditional writes, so keep one writer at a time. | none |
| **Git over SSH** (GitLab, Codeberg, Gitea, own server) | Developers' default (pass, gopass). | No token to store: the SSH agent holds the key. A read-write deploy key limited to one repository. A non-fast-forward rejection is the compare-and-swap. | medium (use the system `git`) |
| **WebDAV** (Nextcloud, ownCloud, Synology, many hosts) | Self-hostable, supported by KeePass-family apps. | App-specific password over HTTPS. `If-Match` support must be verified per server. | small (one adapter) |
| **S3-compatible** (Cloudflare R2, Backblaze B2, MinIO, AWS S3) | Cheap, durable, no server to run. | Access key restricted to one bucket and prefix. Conditional writes confirmed for AWS S3 and MinIO; **not verified** for R2 and B2. | small (SigV4 signing) |
| **CloudKit private database** | What Apple-native managers use; zero setup for the user. | Apple holds only encrypted records; needs a paid Apple Developer account and the iCloud entitlement. | large + paid account |
| **Self-hosted sync server** (Vaultwarden model) | One place for several people. | You run and patch a server and its authentication. | large |
| **No sync** | Highest assurance. | Encrypted copies by hand (the vault folder is already a complete backup). | none |

Suggested order if one more backend is built: **WebDAV** (covers Nextcloud, Synology and self-hosting with the smallest adapter), then **S3-compatible**, with **Git over SSH** for developers who want zero stored tokens.

## 8. Performance notes

| Concern | Approach | Reason |
|---|---|---|
| Unlock latency | Argon2id tuned to ~500 ms; Touch ID path skips Argon2 entirely (SE unwrap is milliseconds; not measured yet) | KDF cost is the security; biometrics bypass it legitimately |
| Search over thousands of items | In-memory index built from overview blobs at unlock; prefix + fuzzy match on title/username/url host | 5,000 items × ~300 B overview ≈ 1.5 MB; trivial |
| Quick Access appear time | Pre-created `NSPanel`, hidden; hotkey only orders it front | Must feel instant (< 50 ms) |
| Disk | One small file per item; no database | Vault sizes are KBs to a few MB; SQLite adds complexity and a merge problem |
| Sync | Incremental by item version; parallel downloads, serial GitHub writes | GitHub requires serial; S3 allows parallel |
| Memory | Details decrypted on demand, zeroed after use | Security and memory both improve |

---

## 9. UX

### 9.1 Visual direction: Pulse (pulse.egoist.dev)

Observed on 2026-11-01 from the site's screenshots (the app itself was not run):

- **Canvas:** light neutral grey window background; content in **white cards with large corner radius and a hairline border**, no drop shadows. Generous padding; nothing touches an edge.
- **Sidebar:** narrow, grouped by section headers in small grey caps ("Hardware", "System"); each row has a **small rounded-square icon filled with the section's accent color** and a right-aligned secondary value in grey. Bottom of sidebar: device name + small settings gear.
- **Cards:** title row with icon + colored title + chevron; **one very large number with a small unit suffix** (`59 %`, `26.9 GB`); three or four small label/value pairs beneath; a **dot-matrix / LED sparkline** in the card's accent color at the bottom.
- **Color:** one accent per domain (blue, green, red, orange, purple, teal); everything else is black text on white and grey. System font (SF Pro), tight tracking on large numerals, regular weight for labels.
- **Lists:** dense table with icons per row, sortable columns, search field in the toolbar, **inspector pane on the right** with a detail list and small charts.
- **Menu bar:** one compact item per metric with its tiny LED graph; click opens a popover with the same card language.
- **Overall feel:** calm, quiet, Apple-settings-like; information density without visual noise.

Translation to the vault:

| Pulse element | Vault equivalent |
|---|---|
| Sidebar sections with colored icons | "Vault" (All, Favorites, Recent), "Types" (Logins blue, API keys orange, Databases green, Webhooks purple, Notes grey, SSH teal), "Tags" |
| Overview cards with big numbers | Home: item counts per type, weak/reused/old passwords, last sync, sync status |
| Dot-matrix sparkline | Password age / rotation timeline; sync activity in the last minute |
| Process list + inspector | Item list (icon from favicon or app icon, title, username, domain, last used) + detail inspector (fields with reveal/copy, history, linked apps) |
| Menu bar item + popover | Lock state and sync status; popover = Quick Access search |
| One accent per domain | One accent per item type, used only on icons, titles and sparklines |

Implementation: SwiftUI `NavigationSplitView` with a custom sidebar, cards as `GroupBox`-free custom views, `NSPanel` for Quick Access, `MenuBarExtra` for the status item. No third-party UI library.

### 9.2 Screens

- **Main window**: sidebar (All, Favorites, by type, tags, vaults) · list · detail. Reveal / copy / open URL / rotate / history. Edit in place.
- **Quick Access** (⌥Space or custom): floating search panel, shows items matching the frontmost app's bundle id first, Enter copies password, ⌘Enter copies username, ⇧Enter auto-types (phase 5). Closes on escape or focus loss.
- **Menu bar**: lock state, last sync, quick lock, open.
- **Unlock**: Touch ID sheet first, password fallback. Auto-lock timer visible in settings.
- **Settings**: Security (auto-lock, clipboard clear, Touch ID, recovery key), Sync (backend, credentials, status, conflicts), Browsers (install extension, host status), Auto-type (permission, opt-in).

---

## 10. Build order (each phase is usable on its own)

| Phase | Deliverable | Needs | Risk |
|---|---|---|---|
| **1. Core vault** | Swift app: create vault, Argon2id + Touch ID unlock, item CRUD, history/rotate, search, Quick Access with concealed copy + auto-clear, auto-lock, main UI | libsodium | Low |
| **2. Sync** | `RemoteStore` protocol; Folder, GitHub Contents API, S3-compatible; manifest, conflicts, status UI | URLSession, Keychain for tokens | Medium (edge cases of conditional writes) |
| **3. Credential Provider** | appex for Safari + native login fields; metadata suggestions; Touch ID via system; passkeys later | entitlement + provisioning profile | Medium (Apple API quirks, 1Password still reports bugs) |
| **4. Browser extension** | MV3 extension (Chrome/Arc/Edge/Firefox) + native messaging host; PSL matching; fill with events; save new logins | Chrome Web Store + AMO accounts | Medium |
| **5. Auto-type** | Accessibility-based fill for Electron/Java/terminal; AX-set first, keystrokes fallback; Secure Input detection | Accessibility permission | Medium-high (fragile by nature) |
| **6. Install** | Local signing, launch at login, build script | none | Low |

Phase 1 alone already replaces copying secrets from a notes file, which is the real baseline today.

Reordered for the decisions in §11: **1 → 2 (GitHub) → 4 (Dia + Firefox extension) → 3 (Credential Provider, needs paid Apple account) → 5 → 6.** The extension moves ahead of the Credential Provider because Dia and Firefox are the daily browsers.

Testing per phase: unit tests for crypto round-trips and AAD tampering (must fail), property test for merge (no item ever disappears), a fake `RemoteStore` that injects 409/412, and an end-to-end script that creates a vault, syncs to a local folder as a second device, and merges a conflict.

---

## 11. Decisions (recorded 2026-11-01)

| # | Decision | Answer | Consequence |
|---|---|---|---|
| 1 | Distribution | **Personal use on the owner's Mac only. No App Store.** | No licensing code at all (§6.3 is dropped). No Sparkle. Build from source, sign locally. Non-sandboxed main app is fine, so auto-type stays possible. |
| 2 | First remote sync backend | **GitHub private repo** (Contents API) | S3 stays in the `RemoteStore` design but is not built until wanted. |
| 3 | Browsers | **Dia** (Chromium, The Browser Company) **+ Firefox**. Safari via Credential Provider only. | One Chromium MV3 build (also runs in Chrome and Arc) + Firefox manifest. See §11.1 for the personal-install path. |
| 4 | Touch ID policy | Not answered → **default `biometryCurrentSet`** | Fingerprint re-enrollment asks for the master password once. |
| 5 | Import/export | Not answered → **deferred**; manual entry first | KDBX/1PUX import can be added without format changes. |
| 6 | Reference app for look & feel | **Pulse** by egoist (pulse.egoist.dev) | Visual direction captured in §9.1. |
| 7 | Name and bundle id | **Satchel**, `com.bilalesi.satchel` (chosen 2026-11-02; built as "Vault" until then, migrated on first launch) | App Group, socket, native messaging host name derive from it. |

### 11.1 What "personal use, not in the store" changes

- **Apple Developer account.** Phases 1, 2, 4 and 5 work with free local signing. **Phase 3 (Credential Provider appex) needs the `autofill-credential-provider` entitlement in a provisioning profile, which requires a paid Apple Developer membership.** Decide when phase 3 starts; everything else does not wait on it. (Whether Apple requires a request form for this entitlement on macOS: **not checked**.)
- **Secure Enclave key storage.** CryptoKit's `SecureEnclave.P256` key is persisted as an opaque `dataRepresentation` that is useless without this Mac's chip. We store it in the app's own container, so no `keychain-access-groups` entitlement or profile is needed for Touch ID.
- **Dia extension install.** Dia is Chromium-based and installs Chrome Web Store extensions (reported 2026, community). For personal use we load the extension unpacked in developer mode; no store listing. Set a fixed `key` in `manifest.json` so the extension ID is stable, because the native messaging host's `allowed_origins` is pinned to that ID. **Verified on this Mac (2026-11-01):** Dia is installed, has Chrome extensions installed (its profile contains an `Extensions` directory with four extensions, one of them a native-messaging user), and its user-level host manifest directory is `~/Library/Application Support/Dia/User Data/NativeMessagingHosts/` (same layout as Arc; Dia's `ArcCore` framework also references the system-level `/Library/Application Support/Chromium/NativeMessagingHosts`). The app installs one JSON manifest per browser: Chrome, Arc, Dia, Firefox.
- **Firefox extension install.** Release Firefox refuses unsigned extensions permanently. Options: sign it as "unlisted" on addons.mozilla.org (free account, no public listing), or use Firefox Developer Edition with `xpinstall.signatures.required=false`. Unlisted AMO signing is the cleaner path.
- **Arc** is installed but sunsets December 2026; the same Chromium build runs there meanwhile.
- **Updates.** `git pull && build`. No update channel, no appcast.
- **Backups.** The GitHub repo *is* the backup (ciphertext). Keep the recovery key printed, off the Mac.

---

## 11.2 Build status (2026-11-02)

| Phase | State |
|---|---|
| 1 Core vault, Touch ID, Quick Access | built, owner-confirmed |
| 2 Sync (GitHub, folder) | built, owner-confirmed |
| 4 Extension (Dia, Arc, Chrome, Firefox) | built, owner-confirmed in Dia |
| 5 Auto-type | built, owner-confirmed |
| One-time codes (RFC 6238) | built |
| Independent security review | done; 8 findings fixed with tests (synthetic-event fills, header/manifest consistency, withheld remote items, keystroke target re-check, lossless merge, sync.json integrity, GitHub listing cap, generated-password clipboard) |
| 3 Safari credential provider | waiting for a paid Apple Developer account |
| S3 backend, KDBX/1PUX import | not started |
| Product name | Satchel, installed in /Applications on 2026-11-02 |

## 12. Sources

Apple
- [Credential provider extensions — Apple Platform Security](https://support.apple.com/guide/security/credential-provider-extensions-sec6319ac7b9/web)
- [Password AutoFill — Apple Developer](https://developer.apple.com/documentation/security/password-autofill)
- [ASCredentialProviderViewController](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller)
- [ASCredentialProviderExtensionContext](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderextensioncontext)
- [ProvidesTextToInsert (iOS/iPadOS 18 only)](https://developer.apple.com/documentation/bundleresources/information-property-list/providestexttoinsert)
- [Forum: ProvidesTextToInsert macOS support](https://developer.apple.com/forums/thread/769017)
- [TN2150 — Using Secure Event Input Fairly](https://developer.apple.com/library/mac/technotes/tn2150/_index.html)
- [Messaging between the app and JavaScript in a Safari web extension](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)
- [Forum: CryptoKit Secure Enclave + biometric enforcement](https://developer.apple.com/forums/thread/124196)

Browsers
- [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
- [Zen Browser discussion: third-party credential providers not offered](https://github.com/zen-browser/desktop/discussions/12452)
- [Why the iCloud Passwords Chrome extension stopped working (macOS 15.5 host restriction)](https://gist.github.com/0xdevalias/a56496ce7c95d19f83bbc1e60fb4d248)
- [1Password: Chrome passkey dialog shows instead of 1Password](https://1password.community/discussions/1password/chrome-passkey-dialog-shows-up-instead-of-1password-one/103702)
- [Dia browser vs Chrome extensions (2026, community)](https://www.superchargebrowser.com/library/dia-browser-vs-chrome-extensions/)
- [Pulse by egoist — visual reference](https://pulse.egoist.dev/)

Password-manager practice
- [1Password Security Design white paper](https://1password.com/files/1password-white-paper.pdf)
- [1Password: macOS AutoFill is now available to everyone (community thread)](https://www.1password.community/announcements-52/macos-autofill-is-now-available-to-everyone-25254)
- [Bitwarden: Encryption key derivation (KDF defaults)](https://bitwarden.com/help/kdf-algorithms/)
- [Bitwarden discussion: native AutoFill provider for passwords on macOS](https://github.com/orgs/bitwarden/discussions/21537)
- [KeePassXC Merger.cpp (synchronize merge)](https://git.hackliberty.org/Git-Mirrors/keepassxc/src/commit/79ca00604aab9721a741c848940998b3cdf36708/src/core/Merger.cpp)
- [KeePassXC: Auto-Type permissions on macOS (issue 3329)](https://github.com/keepassxreboot/keepassxc/issues/3329)
- [KeePassXC: memory protection / ptrace (issue 10784)](https://github.com/keepassxreboot/keepassxc/issues/10784)
- [nspasteboard.org — Concealed / Transient pasteboard types](https://nspasteboard.org/)
- [1Password forum: memory handling on macOS](https://1password.community/discussion/93836/how-does-1password-ios-macos-app-securely-reset-sensitive-data-i-memory)

Storage
- [Amazon S3 conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)
- [GitHub REST: repository contents](https://docs.github.com/en/rest/repos/contents)

Engineering
- [Swift Forums: proposal for secure memory API](https://forums.swift.org/t/proposal-add-secure-memory-management-api-for-sensitive-data-in-swift/80550)
- [Ockam: how we built a Swift app that uses Rust (Tauri → SwiftUI)](https://www.dev.to/build-trust/how-we-built-a-swift-app-that-uses-rust-102f)
- [Patrick Wardle — Synthetic Reality (synthetic events on macOS)](https://objective-see.org/blog/blog_0x36.html)
