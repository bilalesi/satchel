# Satchel

A native macOS vault for logins, API keys, database credentials, webhooks, notes and SSH keys. Everything is encrypted on your Mac. You unlock it with a master password or Touch ID, search it from a global Quick Access panel, and fill logins in your browser. It can sync through a place you control: a folder, GitHub, any git host, WebDAV or S3-compatible storage. There is no Satchel server and no account.

Requires macOS 15 or newer, Apple silicon or Intel.

## Install

1. Download `Satchel-<version>.dmg` from the **Releases** page, open it and drag **Satchel** onto **Applications**. Eject the disk image and open Satchel from Applications.
2. The first launch is blocked by macOS, because Satchel is signed ad hoc and not notarized (notarization needs a paid Apple Developer account). Open **System Settings → Privacy & Security**, scroll down to the message about Satchel and click **Open Anyway**. Or run once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Satchel.app
   ```
3. Optional: check the download with `shasum -a 256 -c Satchel-<version>.dmg.sha256`.

Satchel then offers new versions itself: a blue circle appears in the window when one is out. It downloads the update, checks its signature against a key built into your copy, and restarts into it. Turn this off in **Settings → General**. Your vault is never touched by an update.

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

`.github/workflows/release.yml` tests, builds a universal DMG and publishes it as release `v0.1.<commit count>` on every push to `main` that changes the app. In-app updates need releases to be signed:

1. Create a key pair once: `swift scripts/update-key.swift generate`. Put the **public** key in `Resources/update-public-key.txt` and commit it. Keep the private key in a password manager.
2. Store the private key as the secret `UPDATE_SIGNING_KEY` of a GitHub environment named `release` (`gh secret set UPDATE_SIGNING_KEY --env release`), and in the repository settings limit that environment to the `main` branch so no other branch's workflow can read it.
3. If the repository is not `bilalesi/satchel`, set `SatchelUpdateRepository` in `Resources/Info.plist`.

Without the secret the release is published unsigned and installed apps ignore it. Losing the private key means existing installs can no longer update automatically; they need a manual install of a build with a new public key.

Never put your own vault into this repository. Use a separate private repository for sync.

## Contributing

Contributions are welcome through forks and pull requests. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Every change needs the maintainer's approval and a passing check before it merges. Report security problems privately, as described in [SECURITY.md](SECURITY.md).

## License

Satchel is paid software with public source. Try every feature free for 14 days, then buy it once:

- **Satchel, $29:** one person, on their own Macs.
- **Family, $49:** one household, up to 5 Macs.

Each licence includes a year of updates, and you keep the last version from that year for good. Renewing is optional. There is no subscription and no account: the licence is a key you paste into Settings → Licence, checked on your Mac. Licences are not on sale yet; until the buy page exists, ask through the GitHub profile.

The code is public so you can audit it; the terms are in [LICENSE](LICENSE). Security is never behind the paywall, and no licence state ever makes your vault unreadable: after the trial you can still unlock Satchel and open and copy every item. The third-party components keep their own licenses (see below).

## Credits

Cryptography by [libsodium](https://libsodium.org). Icons: [Codicons](https://github.com/microsoft/vscode-codicons) by Microsoft (CC BY 4.0). Site matching uses the [Public Suffix List](https://publicsuffix.org). Full notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
