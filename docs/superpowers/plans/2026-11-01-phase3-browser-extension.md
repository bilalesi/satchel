# Phase 3 — Browser Extension (Dia, Firefox) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a login page in Dia (or Chrome, Arc) and Firefox, the extension offers the vault's matching logins and fills username and password on a click; it can save a new login and generate a password. The secrets never leave the app process except for the one fill the user asked for.

**Architecture:**
```
page ─content.js─▶ background.js ─connectNative─▶ vault-host (stdio↔unix socket relay) ─▶ Vault.app BridgeServer ─▶ BridgeHandler (MainActor, VaultSession)
```
The host is a 100-line relay with no keys. The app owns matching (Public Suffix List, exact registrable domain), the origin allowlist, unlock prompts and item access. Patterns: Facade (`BridgeHandler`), Mediator (background script between page, popup and host), allowlist at every trust boundary.

**Tech Stack:** Swift (host + server, BSD unix socket, Network not needed), WebExtension MV3 vanilla JS (no build tooling, no npm), Public Suffix List bundled as a SwiftPM resource.

**Spec:** `docs/INVESTIGATION.md` §3.2, §6.2 points 6–8, 14; §11.1 install path.

## Global Constraints

- Match on the **registrable domain of the top frame** (PSL, ICANN + private sections). Exact host match ranks above same-site match.
- `http:` pages get matches only for `localhost`/`127.0.0.1` or items saved with an explicit `http://` URL for that host.
- No fill into iframes (`frameId != 0` refused in background and by the app, which only ever sees top-frame URLs).
- No auto-fill on load and never auto-submit: every fill follows a click or the keyboard command.
- The app re-validates origin ↔ item on `fill`; the extension cannot request an item that does not match the page.
- Origin allowlist: `chrome-extension://<ID>/` (ID derived from the key in `extension/src/.chromium-key`) and the Firefox id `vault@bilalesi`.
- Host ↔ app: unix socket `~/Library/Application Support/Vault/bridge.sock`, mode 0600; the app accepts a peer only if its executable lives inside the app's own bundle (`proc_pidpath`). Documented limit: same-user malware is outside the threat model (§6.1).
- Framing on both legs: native messaging's `u32 little-endian length ‖ UTF-8 JSON`, max 1 MiB.
- Vanilla JS, two manifests (Chromium service worker, Firefox background scripts) assembled by `extension/build.sh` into `extension/dist/{chromium,firefox}`; the bundle script copies `dist/` into `Vault.app/Contents/Resources/extension/`.
- Fill sets the value through the native setter and dispatches `input` and `change` so React/Vue forms accept it.

## Review Focus

1. Page `https://accounts.google.com.evil.io/`: zero matches (PSL registrable domain is `evil.io`). (Task 1 test.)
2. Login form inside a third-party iframe: content script in the frame gets no matches because background refuses `frameId != 0`. (Task 4, manual.)
3. App not running when the user clicks the extension: host launches the app, retries 5 s, then answers `app_not_running` instead of hanging. (Task 3, manual round trip.)
4. Vault locked: `match` returns `locked: true` with no items; popup shows Unlock, which triggers Touch ID in the app without stealing focus. (Task 2 handler test for the locked path.)
5. Two logins for the same site: both listed, exact host first, user picks; nothing filled until the pick. (Task 1 ranking test.)

---

### Task 1: DomainMatcher + BrowserMatch (VaultCore)

**Files:** Create `Sources/VaultCore/Browser/DomainMatcher.swift`, `Sources/VaultCore/Browser/BrowserMatch.swift`, `Sources/VaultCore/Resources/public_suffix_list.dat` (downloaded 2026-11-01), `Tests/VaultCoreTests/DomainMatcherTests.swift`; modify `Package.swift` (`resources: [.copy("Resources")]`).

**Interfaces:**
- `public struct DomainMatcher: Sendable { public static let shared: DomainMatcher /* bundled list */; public init(rules: String); public func publicSuffix(of host: String) -> String?; public func registrableDomain(of host: String) -> String?; public func sameSite(_ a: String, _ b: String) -> Bool }` — PSL algorithm: longest matching rule wins, exception beats wildcard, default rule `*`; IPs and single labels return themselves.
- `public enum BrowserMatch { public static func pageHost(_ url: URL) -> String?; public static func allowed(_ url: URL, for item: ItemOverview) -> Bool /* scheme rule */; public static func rank(_ items: [ItemOverview], for url: URL, matcher: DomainMatcher = .shared) -> [ItemOverview] /* exact host 2, same-site 1, favorites tiebreak, updatedAt */ }`

- [ ] Tests: `testRegistrableDomains` (`mail.google.com`→`google.com`, `a.b.co.uk`→`b.co.uk`, `www.ck`→`www.ck` via exception, `foo.bar.ck`→`bar.ck` wildcard, `user.github.io`→`user.github.io` private rule, `localhost`→`localhost`, `192.168.0.1`→itself), `testPhishingLookalikeDoesNotMatch`, `testRankingExactHostFirst`, `testHttpRules`.
- [ ] Commit `feat(core): PSL domain matcher and browser match rules`.

### Task 2: Bridge protocol, framing, server, handler (app) + host executable

**Files:** Create `Sources/VaultCore/Browser/NativeMessageFraming.swift`, `Sources/Vault/Bridge/BridgeProtocol.swift`, `Sources/Vault/Bridge/BridgeServer.swift`, `Sources/Vault/Bridge/BridgeHandler.swift`, `Sources/Vault/Bridge/BrowserIntegration.swift` (ids, paths), `Sources/VaultHost/main.swift`; modify `Package.swift` (executable target `vault-host` depending on `VaultCore`), `VaultApp.swift` (start server at launch), `scripts/bundle.sh` (copy host binary and extension dist).
- `Tests/VaultCoreTests/FramingTests.swift`.

**Interfaces:**
- `public enum NativeMessageFraming { public static let maxLength = 1 << 20; public static func frame(_ json: Data) -> Data; public struct Decoder { public mutating func append(_ data: Data); public mutating func next() throws -> Data? } }`
- `struct BridgeRequest: Decodable { id: Int; type: String; origin: String?; url: String?; itemID: UUID?; username: String?; password: String?; title: String? }`
- `struct BridgeResponse: Encodable { id, ok, error?, locked?, items: [BridgeItem]?, credential: BridgeCredential?, password?, version? }`; `BridgeItem { id, title, username, host, type }`; `BridgeCredential { username, password }`.
- `BridgeServer` (final class, BSD socket + DispatchSource accept, per-connection read source, `handle: @MainActor (BridgeRequest) async -> BridgeResponse`), peer check via `LOCAL_PEERPID` + `proc_pidpath` inside `Bundle.main.bundlePath`.
- `BridgeHandler` (MainActor): `hello`/`status` → `{locked}`; `unlock` → `session.unlockWithBiometrics()` then `{locked}`; `match` → ranked `BridgeItem`s or `locked`; `fill` → re-check `BrowserMatch.allowed` + same-site, return credential; `save` → new `.login` item with `urls: [scheme://host]`, tag `browser`; `generate`. Rejects unknown origin with `error: "origin_not_allowed"`.
- `vault-host`: parse origin from argv (`chrome-extension://…` or Firefox id), connect to socket, on failure `NSWorkspace.shared.openApplication` on the enclosing `.app` and retry for 5 s; loop stdin frame → add `origin` → socket → stdout; EOF exits. Errors are answered as `{id, ok:false, error}`.

- [ ] Tests: `FramingTests` (round trip, split chunks, oversize rejected). Host round trip checked by script in Task 6.
- [ ] Commit `feat(bridge): native messaging host and app-side bridge`.

### Task 3: Extension

**Files:** Create `extension/src/manifest.chromium.json`, `extension/src/manifest.firefox.json`, `extension/src/background.js`, `extension/src/content.js`, `extension/src/popup.html`, `extension/src/popup.js`, `extension/src/popup.css`, `extension/src/icons/{16,48,128}.png`, `extension/build.sh`, `extension/README.md`.

**Behaviour:**
- `background.js`: lazily `connectNative("com.bilalesi.vault")`; request ids; `onMessage` from content/popup: `{type:"match"}` uses `sender.tab.url` (never a URL the page supplies) and refuses `sender.frameId !== 0`; `{type:"fill", itemID}` same; `{type:"unlock"}`, `{type:"save", username, password}`, `{type:"generate"}`, `{type:"status"}`. Port disconnect → clears cache, next request reconnects. Command `fill-first` (⌘⇧L) sends `fill` for the best match to the active tab's top frame.
- `content.js` (top frame only: `if (window.top !== window) stop`): finds password fields; on focus of a password or its username field, asks background for matches and shows a shadow-DOM dropdown under the field (title, username, host); click → background `fill` → sets both fields with native setter + events; Esc/blur closes. Also handles `{type:"fill-credential"}` messages from background for the keyboard command and `{type:"read-form"}` from the popup (returns current username/password values for Save).
- `popup.js`: status (locked / app not running), list of matches for the active tab, Unlock button, Fill buttons, "Save login on this page", "Generate password" (copies via `navigator.clipboard`), link to open the app.
- Manifests: permissions `nativeMessaging`, `activeTab`, `tabs`, `clipboardWrite`; `content_scripts` on `<all_urls>` at `document_idle`, `all_frames: false`; Chromium manifest has `key`; Firefox manifest has `browser_specific_settings.gecko.id = "vault@bilalesi"` and `background.scripts`.

- [ ] `node --check` each JS file; `extension/build.sh` produces both dists. Commit `feat(extension): Dia/Chromium and Firefox extension`.

### Task 4: Installer + Settings → Browsers

**Files:** Create `Sources/Vault/Bridge/NativeMessagingInstaller.swift`, `Sources/Vault/UI/BrowserSettings.swift`; modify `SettingsView.swift`, `VaultApp.swift`.

- `NativeMessagingInstaller.Browser` cases dia, arc, chrome, firefox with `manifestDirectory`, `appBundleID`, `isInstalled` (app present), `hostManifestPresent`; `install(_:)` writes `com.bilalesi.vault.json` with the current host path; `remove(_:)`; `refreshStalePaths()` at launch rewrites manifests that point at another copy of the app.
- Settings → Browsers: one row per detected browser with Install/Remove, the extension folder path with "Reveal" (Chromium: load unpacked from `…/Resources/extension/chromium`; Firefox: temporary add-on from `…/firefox`, or sign unlisted on AMO), and a live "Bridge: listening / not running" line.

- [ ] Commit `feat(app): browser manifest installer and settings`.

### Task 5: Verify and document

- [ ] Script `scripts/bridge-smoke.sh`: with the app running, pipe a framed `{"id":1,"type":"hello"}` into `vault-host` with the Dia origin as argv[1] and assert the reply contains `"ok":true`.
- [ ] README: browser setup for Dia and Firefox. Commit.
