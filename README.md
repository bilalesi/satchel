# Satchel

A native macOS vault for logins, API keys, database credentials, webhooks, notes and SSH keys. Everything is encrypted on your Mac. You unlock it with a master password or Touch ID, search it from a global Quick Access panel, and fill logins in your browser. It can sync through a place you control: a folder, GitHub, any git host, WebDAV or S3-compatible storage. There is no Satchel server and no account.

Requires macOS 15 or newer, Apple silicon or Intel.

## Install

1. Download Satchel from [satchel.echospace.dev](https://satchel.echospace.dev), open the disk image and drag **Satchel** onto **Applications**. Eject the disk image and open Satchel from Applications.
2. Try it free for 7 days, or buy a licence straight away. The link in your purchase email (`satchel://activate?key=…`) opens Satchel and activates the key; you can also paste the key into **Settings → Licence**.

Releases are signed with Apple's Developer ID and notarized, so macOS opens them without a warning. (Until the Apple signing is set up, a build is signed ad hoc: then open **System Settings → Privacy & Security** and click **Open Anyway** on the first launch.)

Satchel then offers new versions itself: a blue circle appears in the window when one is out. It downloads the update from satchel.echospace.dev, checks its size, checksum and signature against a key built into your copy, and restarts into it. Turn this off in **Settings → General**. Your vault is never touched by an update.

## First run

1. Create a master password (at least 8 characters; use a long passphrase). **It cannot be recovered.** Without it and without a synced copy, the data is gone.
2. **Settings → Security → Touch ID** to unlock with your fingerprint.
3. Press **⌥ Space** anywhere for Quick Access. Pick another shortcut in **Settings → General** if another app uses it.
4. Lock with **⇧⌘L**, from the menu bar icon, or let it auto-lock after idle time, screen lock or sleep.

## Organise

- **Types.** Login, API key, database, webhook, secure note, SSH key.
- **Categories.** Create your own (name, icon, colour) from the sidebar or **New → Category**, and file items into them.
- **Workspaces.** A workspace is a separate vault with its own master password, categories, Touch ID and sync. Use one for work and one for home. Switch from the pill at the top of the sidebar or on the lock screen; manage them in **Settings → Vault**.

## Sync

**Settings → Sync.** Pick a method, fill in the fields, **Test**, **Save**. Each workspace has its own method.

| Method | You need | Notes |
|---|---|---|
| Synced folder | iCloud Drive, Dropbox or a network share | The simplest. |
| GitHub | A private repository and a fine-grained token with Contents: Read and write | One commit per change. |
| Git (SSH) | Any git repository your SSH key can push to | Uses the git and SSH keys on your Mac. One commit and push per sync. Add key passphrases to the agent: `ssh-add --apple-use-keychain`. |
| WebDAV | Nextcloud, ownCloud, Synology or a NAS, over https, with an app password | The server must support ETags and conditional requests. |
| S3-compatible | A bucket and an access key: AWS S3, Cloudflare R2, MinIO, Backblaze B2 | Conditional writes are required. |

For WebDAV and S3 Satchel tests that the server really refuses a write when another device changed the file in the meantime. A server that doesn't would let two Macs overwrite each other, so Satchel refuses to use it.

Only ciphertext leaves your Mac: the vault header (password-wrapped key), a signed manifest and one encrypted file per item. Credentials for the sync target are stored encrypted inside the vault, never synced. Two Macs editing at once are merged item by item. If both changed the same item, the newer value wins and the other lands in the item's history.

**Choose what syncs.** Per category or per item: turn a category off in **Settings → Sync → What to sync on this Mac**, or set **Sync** in the item editor to *Keep on this Mac*. This is a choice of each Mac, kept inside the vault. Items already uploaded stay on the remote.

**Second Mac.** On the first screen choose **Connect an existing vault**, enter the same sync method and the master password.

If a remote ever serves an older vault than your Mac last saw (a restored backup, a malicious host), sync stops with an error instead of silently reverting items.

## Browser extension (Dia, Arc, Chrome, Firefox)

Once per browser: **Settings → Browsers → Install**, then load the extension (**Reveal** opens the folder).

- Chromium browsers: Extensions page → Developer mode → **Load unpacked** → the `chromium` folder.
- Firefox: `about:debugging` → This Firefox → Load Temporary Add-on → `firefox/manifest.json` (temporary add-ons are removed when Firefox restarts).

Focus a login field, click a suggested login to fill it, or press **⌘⇧L** for the best match. Nothing is filled without a click or the shortcut, and forms are never submitted. A page only sees logins saved for its own site, matched by registrable domain (`accounts.google.com.evil.io` does not match `google.com`).

## Auto-type into other apps

**Settings → General → Auto-type** asks for the Accessibility permission. Click into a field in another app, press the Quick Access shortcut, pick an item, then **⇧↩** types the secret or **⌥↩** the username. macOS asks for the permission again after an app update, because ad-hoc signed apps change identity with each build.

## How it protects your data

- A random 256-bit vault key encrypts every item. Your password unlocks it through Argon2id (256 MiB, 3 passes). Touch ID adds a Secure Enclave key that exists only on that Mac.
- Each item is a file with a small authenticated header and two XChaCha20-Poly1305 boxes: searchable metadata and secrets. Secrets are decrypted only when you open or copy an item.
- A MAC'd manifest with a growing generation counter detects a removed, edited or rolled-back file.
- Windows are hidden from screenshots and screen sharing unless you allow them. The clipboard is cleared after a delay. The vault locks on idle, sleep and screen lock.
- Details and threat model: [docs/INVESTIGATION.md](docs/INVESTIGATION.md).

What Satchel cannot protect against: malware running as you on an unlocked Mac, a weak master password, or losing the password.

## Troubleshooting

- **"Satchel can't be opened"**: see Install step 2.
- **Touch ID stops working after an update**: unlock with the password and enable Touch ID again.
- **Browser says the native host is missing**: Settings → Browsers → Install again, then restart the browser.
- **Sync says the server does not protect against overwriting**: choose another server or method; see Sync.
- **Quick Access shortcut does nothing**: another app owns it; pick another in Settings → General.

## Build from source

Needs Xcode 26 (Swift 6.3).

```bash
swift test               # run the tests
scripts/install.sh       # build, sign ad hoc, copy to /Applications
UNIVERSAL=1 VERSION=0.1.0 scripts/make-dmg.sh   # build/Satchel-0.1.0.dmg
```

## Releasing (maintainers)

`.github/workflows/release.yml` tests and builds a universal DMG (version `0.1.<commit count>`) on every push to `main` that changes the app, then uploads it to the private Cloudflare R2 bucket `satchel-releases`: `releases/Satchel-<version>.dmg`, its `.sig`, and last `latest.json`, which the website turns into the download link and the update feed (`https://satchel.echospace.dev/api/update`). Nothing is published on GitHub. Secrets, all in the GitHub environment `release` (limit it to the `main` branch in the repository settings so no other branch's workflow can read them):

1. `UPDATE_SIGNING_KEY` (required): create a key pair once with `swift scripts/update-key.swift generate`, commit the **public** key as `Resources/update-public-key.txt`, keep the private key in a password manager. Losing it means existing installs can no longer update automatically.
2. `CLOUDFLARE_R2_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` (required): an API token limited to R2 writes.
3. `APPLE_TEAM_ID`, `APPLE_DEVELOPER_ID_P12` (base64), `APPLE_DEVELOPER_ID_P12_PASSWORD`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8` (optional): with all six the app is signed with Developer ID and hardened runtime, notarized and stapled; without them it is signed ad hoc.

Licence keys are signed with a separate key pair (`swift scripts/license-key.swift`); its public half is `Resources/license-public-key.txt`. A build without that file enforces no licence.

Never put your own vault into this repository. Use a separate private repository for sync.

## Contributing

Contributions are welcome through forks and pull requests. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Every change needs the maintainer's approval and a passing check before it merges. Report security problems privately, as described in [SECURITY.md](SECURITY.md).

## License

Satchel is paid software with public source. Try every feature free for 7 days, then buy it once for €20 plus checkout fees, with tax added at checkout, at [satchel.echospace.dev/pricing](https://satchel.echospace.dev/pricing). One plan, for one person on their own Macs.

Each licence includes a year of updates, and you keep the last version from that year for good. Renewing is optional. There is no subscription and no account: the licence is a key checked on your Mac.

The code is public so you can audit it; the terms are in [LICENSE](LICENSE). No licence state ever makes your vault unreadable: after the trial, without a licence, Satchel stops working except for two things. You can still unlock it, enter a licence key, and export all your items to a file. The third-party components keep their own licenses (see below).

## Credits

Cryptography by [libsodium](https://libsodium.org). Icons: [Codicons](https://github.com/microsoft/vscode-codicons) by Microsoft (CC BY 4.0). Site matching uses the [Public Suffix List](https://publicsuffix.org). Full notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
