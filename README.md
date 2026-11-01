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

- **GitHub private repository.** Create an empty private repo. Create a fine-grained personal access token (github.com → Settings → Developer settings → Fine-grained tokens) limited to that repository with **Contents: Read and write**. Enter owner, repository, branch and the token, click **Test connection**, then **Save**. The token is stored in the login Keychain, never in a file.
- **Folder.** Any synced directory (iCloud Drive, Dropbox, a network share).

What happens: after every change (2 s debounce), on unlock, every 15 minutes and when the network comes back, the vault directory is mirrored to the remote. Each item is one encrypted file; only files whose git blob id differs are transferred. The manifest is written last with a compare-and-swap, so two Macs editing at the same time never overwrite each other: the second one retries, merges per item, and if both edited the same item the newer value wins and the other value lands in that item's history with a `conflict` tag.

What is uploaded: `vault.vhdr` (KDF parameters, password-wrapped key), `manifest.vman`, `items/*.vitem`. All ciphertext. What is **not** uploaded: `touchid.slot` (Secure Enclave key, useless off this Mac) and `sync.json`.

**Second Mac:** install the app, and on the first screen choose **Connect an existing vault from GitHub or a folder…**, enter the same remote and the master password. The vault is downloaded, verified against its manifest, and unlocked. Enable Touch ID again on that Mac.

If the remote ever serves an older manifest than this Mac last saw (a restored backup, a malicious host), sync stops with a rollback error instead of silently reverting items.

## Not yet built

The browser extension (Dia, Firefox), the Safari credential provider, auto-type into other apps, S3 backend. See phases 3–5 in the investigation document.

## Touch ID and rebuilds

The Secure Enclave key is tied to this app's code-signing identity. The ad-hoc signature uses a fixed identifier (`com.bilalesi.vault`), which keeps the designated requirement stable across rebuilds. If Touch ID stops working after a rebuild or a fingerprint change, unlock with the passphrase and enable Touch ID again in Settings.
