# Vault

Native macOS secret vault for one person: logins, API keys, database credentials, webhooks, notes, SSH keys. Encrypted on disk, unlocked with a master password or Touch ID, searched from a global Quick Access panel.

Design and security analysis: [docs/INVESTIGATION.md](docs/INVESTIGATION.md). Phase 1 plan: [docs/superpowers/plans/2026-11-01-phase1-core-vault.md](docs/superpowers/plans/2026-11-01-phase1-core-vault.md).

## Build and install

Requires Xcode 26 (Swift 6.3) on Apple silicon, macOS 15 or newer.

```bash
scripts/install.sh
```

This builds a release binary, assembles `build/Vault.app`, signs it ad-hoc with the hardened runtime, and copies it to `/Applications`. Re-run it after pulling changes.

Tests:

```bash
swift test
```

## First run

1. Launch Vault. Create a master passphrase (8 characters minimum; use a long one, it cannot be recovered).
2. Settings → Touch ID → enter the passphrase once → Enable. From then on the vault unlocks with Touch ID; the passphrase still works.
3. Press ⌥ Space anywhere for Quick Access. Items linked to the app in front are listed first. Enter copies the secret, ⌘ Enter the username. The clipboard clears after 30 seconds unless you copied something else.
4. Lock with ⇧⌘L, from the menu bar icon, or let it auto-lock (10 minutes idle, screen lock, sleep).

The vault lives in `~/Library/Application Support/Vault/default.vault/`. The whole directory is ciphertext; copying it is a backup.

## What is encrypted and how (short version)

- A random 256-bit vault key encrypts every item. The vault key is wrapped by your passphrase through Argon2id (256 MiB, 3 passes, about 0.3 s on an M-series Mac) and, optionally, by a Secure Enclave key bound to your current fingerprints.
- Each item is one file: a plaintext 41-byte header (id, version, timestamp) that authenticates two XChaCha20-Poly1305 boxes, one for searchable metadata and one for the secrets. Secrets are decrypted only when you open or copy an item.
- `manifest.vman` lists every item version with a monotonic generation and is MAC'd with a key only the unlocked vault has. A file restored to an older version, a missing file, or an edited header is reported instead of trusted.
- Writes are atomic (temp file + rename). A crash between an item write and the manifest write is repaired on the next unlock.

## Sync

Settings → Sync. Two backends:

- **GitHub private repository.** Create an empty private repo. Create a fine-grained personal access token (github.com → Settings → Developer settings → Fine-grained tokens) limited to that repository with **Contents: Read and write**. Enter owner, repository, branch and the token, click **Test connection**, then **Save**. The token is stored encrypted under the vault key in `github-token.local` next to the vault, never synced and never in the login Keychain (which would prompt on every rebuild of an ad-hoc-signed app).
- **Folder.** Any synced directory (iCloud Drive, Dropbox, a network share).

What happens: after every change (2 s debounce), on unlock, every 15 minutes and when the network comes back, the vault directory is mirrored to the remote. Each item is one encrypted file; only files whose git blob id differs are transferred. The manifest is written last with a compare-and-swap, so two Macs editing at the same time never overwrite each other: the second one retries, merges per item, and if both edited the same item the newer value wins and the other value lands in that item's history with a `conflict` tag.

What is uploaded: `vault.vhdr` (KDF parameters, password-wrapped key), `manifest.vman`, `items/*.vitem`. All ciphertext. What is **not** uploaded: `touchid.slot` (Secure Enclave key, useless off this Mac) and `sync.json`.

**Second Mac:** install the app, and on the first screen choose **Connect an existing vault from GitHub or a folder…**, enter the same remote and the master password. The vault is downloaded, verified against its manifest, and unlocked. Enable Touch ID again on that Mac.

If the remote ever serves an older manifest than this Mac last saw (a restored backup, a malicious host), sync stops with a rollback error instead of silently reverting items.

## Browser extension (Dia, Arc, Chrome, Firefox)

Three parts: the extension in the browser, a tiny relay `vault-host` inside the app bundle that the browser spawns, and the app, which listens on a private socket and makes every decision (which items match a page, whether the page may receive an item, unlocking).

Setup, once per browser:

1. Vault → Settings → Browsers → **Install** next to the browser. This writes the native messaging manifest into the browser's profile so it may spawn `vault-host`. Re-run it if you move the app.
2. Load the extension. The files are inside the app: click **Reveal** in the same pane.
   - Dia, Arc, Chrome: Extensions page → Developer mode → Load unpacked → the `chromium` folder. The extension id is fixed by the key in its manifest, so reloading keeps it working.
   - Firefox: `about:debugging` → This Firefox → Load Temporary Add-on → `firefox/manifest.json`. Temporary add-ons disappear on restart; for a permanent install, sign it as "unlisted" on addons.mozilla.org (free) and install the signed file.

Use: focus a login field and the matching logins appear under it; click one to fill username and password. ⌘⇧L fills the best match. The toolbar popup lists matches, unlocks the vault with Touch ID, saves the login typed on the page, and copies a generated password. Nothing is filled without a click or the shortcut, and the extension never submits forms.

Matching: items match a page when their site has the same registrable domain under the Public Suffix List (`accounts.google.com` and `mail.google.com` are one site; `accounts.google.com.evil.io` is not). `http://` pages match only loopback hosts or items saved with an explicit `http://` URL. Frames never receive credentials; only the top page does.

## Auto-type into other apps (Discord, Teams, DBeaver, terminals)

Settings → Security → **Auto-type**. Enabling it asks for the Accessibility permission (System Settings → Privacy & Security → Accessibility → Vault). Then: click into the field in the target app, press ⌥Space, pick the item, press **⇧↩** to type the secret or **⌥↩** to type the username. Quick Access lists items linked to the app in front first.

How it types: the field that is focused in the target app is read through Accessibility; it must be a text field, otherwise nothing is typed. The value is set through Accessibility and read back; if the app ignores that (Electron apps do), the text is sent as Unicode keystrokes, which work in any keyboard layout. Terminal's Secure Keyboard Entry blocks keystrokes; the panel says so instead of typing blindly. After rebuilding the app, macOS may require the permission to be granted again.

## Not yet built

The Safari credential provider (needs a paid Apple Developer account for the entitlement), S3 backend. See the investigation document.

## Touch ID and rebuilds

The Secure Enclave key is tied to this app's code-signing identity. The ad-hoc signature uses a fixed identifier (`com.bilalesi.vault`), which keeps the designated requirement stable across rebuilds. If Touch ID stops working after a rebuild or a fingerprint change, unlock with the passphrase and enable Touch ID again in Settings.
