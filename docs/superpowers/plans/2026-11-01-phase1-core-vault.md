# Phase 1 — Core Vault Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app that creates an encrypted vault, unlocks with master password or Touch ID, stores typed secrets with history, searches them, and copies them safely from a main window or a global Quick Access panel.

**Architecture:** One SwiftPM package. `VaultCore` (library, no UI imports) owns crypto, key slots, item format, manifest and the on-disk repository. `Vault` (executable) is the SwiftUI/AppKit app on top of a `VaultSession` observable. A shell script wraps the executable into `Vault.app` with Info.plist and entitlements and ad-hoc signs it. Patterns: Facade (`VaultSession`), Repository (`VaultStore`), Strategy-ready `KeySlot` enum, ports-and-adapters (crypto behind small structs, tests use temp dirs).

**Tech Stack:** Swift 6.3, SwiftUI + AppKit, CryptoKit (Secure Enclave, HKDF), LocalAuthentication, libsodium via `swift-sodium` 0.11.0 (Argon2id, XChaCha20-Poly1305, secure memory), XCTest.

**Spec:** `docs/INVESTIGATION.md` §4–§6, §9, §10 phase 1, §11.

## Global Constraints

- macOS 15 minimum (`platforms: [.macOS(.v15)]`), Apple silicon.
- Exactly one third-party dependency: `https://github.com/jedisct1/swift-sodium` from `0.11.0`.
- Working name `Vault`, bundle id `com.bilalesi.vault`; both live only in `AppIdentity.swift`.
- Secrets never exist as `String` outside a single expression; secret buffers are `SecureBytes`.
- KDF: Argon2id, memory 256 MiB, iterations 3, parallelism 1 (libsodium has one lane; measured 324 ms on the owner's Mac), 16-byte salt; parameters stored in the header.
- Item/overview/manifest keys are HKDF-SHA256 of the vault key with info strings `"item"`, `"overview"`, `"manifest"`.
- AEAD everywhere: XChaCha20-Poly1305-IETF, 24-byte random nonce, AAD = item header bytes.
- No logging of secrets; no `print` in `VaultCore`.
- Every write to the vault directory is atomic (write temp file, `rename`).
- Touch ID: `SecAccessControl` flags `.privateKeyUsage` + `.biometryCurrentSet`.
- Clipboard: declare `org.nspasteboard.ConcealedType`; clear after 30 s only if change count unchanged.
- Auto-lock: 10 min idle default, also on screen lock, sleep, and app termination.
- Vault windows: `NSWindow.sharingType = .none`.

## Review Focus

1. Wrong master password must fail cleanly with `VaultError.authenticationFailed`, never with a decode crash. (Task 3 test.)
2. A truncated or zero-length `.vitem` file must be reported as `VaultError.corruptItem(id)` and skipped, not abort unlock. (Task 6 test.)
3. Killing the app mid-write must leave either the old or the new item file, never a partial one. (Task 6 atomic write test via temp-file presence.)
4. Fingerprint re-enrollment makes the Secure Enclave slot fail with `VaultError.biometryChanged`; the UI falls back to password and offers re-enable. (Task 7 maps `LAError`/`errSecAuthFailed`; Task 9 shows the fallback.)
5. Clipboard auto-clear must not erase something the user copied afterwards. (Task 8 change-count test.)

---

### Task 1: Package scaffold and app bundle script

**Files:**
- Create: `Package.swift`, `Sources/VaultCore/AppIdentity.swift`, `Sources/Vault/VaultApp.swift`, `Tests/VaultCoreTests/SmokeTests.swift`, `scripts/bundle.sh`, `Resources/Info.plist`, `Resources/Vault.entitlements`, `.gitignore`

**Interfaces:**
- Produces: `public enum AppIdentity { static let name = "Vault"; static let bundleID = "com.bilalesi.vault"; static let defaultVaultURL: URL }` where `defaultVaultURL` = `~/Library/Application Support/Vault/default.vault/`.

- [ ] Step 1: Write `Package.swift` with targets `VaultCore` (depends on `Sodium`), `Vault` (depends on `VaultCore`), `VaultCoreTests`.
- [ ] Step 2: Write `SmokeTests.testIdentity` asserting `AppIdentity.bundleID == "com.bilalesi.vault"`.
- [ ] Step 3: Run `swift test` → PASS. Run `swift build -c release` → binary at `.build/release/Vault`.
- [ ] Step 4: `scripts/bundle.sh` builds release, assembles `build/Vault.app/Contents/{MacOS/Vault,Info.plist,Resources}`, runs `codesign --force --sign - --entitlements Resources/Vault.entitlements --options runtime`. Entitlements: none except hardened runtime (no sandbox: auto-type later). Info.plist: `LSUIElement` false, `NSSupportsAutomaticTermination` false.
- [ ] Step 5: Commit `chore: scaffold package and bundle script`.

### Task 2: SecureBytes

**Files:**
- Create: `Sources/VaultCore/Crypto/SecureBytes.swift`, `Tests/VaultCoreTests/SecureBytesTests.swift`

**Interfaces:**
- Produces: `public final class SecureBytes: @unchecked Sendable { init(count: Int); init(copying: some Collection<UInt8>); var count: Int; func withUnsafeBytes<R>(_: (UnsafeRawBufferPointer) throws -> R) rethrows -> R; func withUnsafeMutableBytes<R>(_: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R; func wipe() }`. Backed by `sodium_malloc` (guard pages + `mlock`), `sodium_memzero` + `sodium_free` in `deinit`. Equality is constant-time via `sodium_memcmp`.

- [ ] Step 1: Tests: `testRoundTrip` (copy in, read out equal), `testWipeZeroes` (after `wipe()` all bytes are 0), `testConstantTimeEquality`.
- [ ] Step 2: Run → FAIL (type missing).
- [ ] Step 3: Implement. `// reason: sodium_malloc gives guard pages and mlock so key material does not reach swap; cheaper than a custom allocator.`
- [ ] Step 4: Run → PASS. Commit `feat(core): SecureBytes`.

### Task 3: Password key slot and vault header

**Files:**
- Create: `Sources/VaultCore/Crypto/AEAD.swift`, `Sources/VaultCore/Crypto/KDF.swift`, `Sources/VaultCore/Model/VaultHeader.swift`, `Sources/VaultCore/Crypto/KeySlot.swift`, `Sources/VaultCore/VaultError.swift`, `Tests/VaultCoreTests/KeySlotTests.swift`

**Interfaces:**
- Produces:
  - `enum AEAD { static func seal(_ plaintext: SecureBytes, key: SecureBytes, aad: Data) throws -> Data /* nonce‖ct‖tag */; static func open(_ box: Data, key: SecureBytes, aad: Data) throws -> SecureBytes }`
  - `struct KDFParams: Codable, Equatable { var memoryKiB: UInt32 = 65536; var iterations: UInt32 = 3; var parallelism: UInt32 = 4; var salt: Data }`; `enum KDF { static func deriveKEK(password: SecureBytes, params: KDFParams) throws -> SecureBytes /* 32 bytes */ }`
  - `enum KeySlot: Codable { case password(params: KDFParams, wrappedKey: Data); case secureEnclave(keyData: Data, wrappedKey: Data) }`
  - `struct VaultHeader: Codable { var formatVersion = 1; var vaultID: UUID; var createdAt: Date; var slots: [KeySlot] }`
  - `enum VaultKey { static func generate() -> SecureBytes /* 32 random */; static func subkey(_ vk: SecureBytes, info: String) -> SecureBytes /* HKDF-SHA256, 32 bytes */ }`
  - `enum VaultError: Error, Equatable { case authenticationFailed, corruptHeader, corruptItem(UUID), corruptManifest, rollbackDetected(local: UInt64, remote: UInt64), biometryUnavailable, biometryChanged, io(String) }`
  - `extension KeySlot { static func makePassword(_ pw: SecureBytes, vaultKey: SecureBytes) throws -> KeySlot; func unwrap(password: SecureBytes) throws -> SecureBytes }`

- [ ] Step 1: Tests: `testPasswordSlotRoundTrip`, `testWrongPasswordThrowsAuthenticationFailed`, `testKDFParamsPersistedInSlot` (memoryKiB 65536, iterations 3, parallelism 4, salt 16 bytes), `testAEADRejectsTamperedAAD`, `testSubkeysDiffer` (`"item"` ≠ `"overview"`).
- [ ] Step 2: Run → FAIL.
- [ ] Step 3: Implement. Argon2id via `Sodium().pwHash.hash(outputLength:passwd:salt:opsLimit:memLimit:alg:)` — note libsodium's `memLimit` is bytes. AEAD via `Sodium().aead.xchacha20poly1305ietf` using the raw `crypto_aead_xchacha20poly1305_ietf_encrypt` to pass AAD. HKDF via CryptoKit `HKDF<SHA256>`.
- [ ] Step 4: Run → PASS (expect ~0.5 s per Argon2 call; keep to two calls per test file). Commit `feat(core): password key slot, AEAD, header`.

### Task 4: Item model and item file format

**Files:**
- Create: `Sources/VaultCore/Model/Item.swift`, `Sources/VaultCore/Model/ItemFile.swift`, `Tests/VaultCoreTests/ItemFileTests.swift`

**Interfaces:**
- Produces:
  - `enum ItemType: String, Codable, CaseIterable { case login, apiKey, dbCredential, webhook, secureNote, sshKey }`
  - `struct ItemOverview: Codable, Equatable, Identifiable { let id: UUID; var type: ItemType; var title: String; var username: String?; var urls: [String]; var bundleIDs: [String]; var tags: [String]; var favorite: Bool; var createdAt: Date; var updatedAt: Date }`
  - `struct SecretRevision: Codable { var value: String; var changedAt: Date }` (lives only inside `ItemDetails`, which is decoded into memory on demand)
  - `struct ItemDetails: Codable { var fields: [String: String] /* "password","apiKey","host","port","database","notes","totpSeed","privateKey" */; var history: [SecretRevision] /* cap 10 */ }`
  - `struct ItemFileHeader { let magic = "VIT1"; let id: UUID; let version: UInt64; let updatedAt: Date; let deleted: Bool }`, encoded as fixed 41 bytes (4 magic, 16 uuid, 8 version BE, 8 updatedAt ms BE, 1 flag, 4 reserved).
  - `enum ItemFile { static func encode(overview: ItemOverview, details: ItemDetails?, version: UInt64, deleted: Bool, keys: VaultKeys) throws -> Data; static func decodeHeader(_: Data) throws -> ItemFileHeader; static func decodeOverview(_: Data, keys: VaultKeys) throws -> ItemOverview; static func decodeDetails(_: Data, keys: VaultKeys) throws -> ItemDetails }`
  - `struct VaultKeys { let item: SecureBytes; let overview: SecureBytes; let manifest: SecureBytes; init(vaultKey: SecureBytes) }`
  - Layout: header ‖ u32 overviewLen ‖ overviewBox ‖ u32 detailsLen ‖ detailsBox. AAD for both boxes = the 41 header bytes.

- [ ] Step 1: Tests: `testRoundTrip`, `testSwappedIDFailsToDecrypt` (rewrite uuid bytes in header → `open` throws), `testTombstoneHasNoDetails`, `testDetailsNotNeededForOverview` (decodeOverview never touches details bytes — assert by truncating file after overview box).
- [ ] Step 2: Run → FAIL. Step 3: Implement. Step 4: PASS. Commit `feat(core): item format`.

### Task 5: Manifest

**Files:**
- Create: `Sources/VaultCore/Model/Manifest.swift`, `Tests/VaultCoreTests/ManifestTests.swift`

**Interfaces:**
- Produces: `struct Manifest: Codable, Equatable { var generation: UInt64; var deviceID: UUID; var versions: [UUID: UInt64] }`; `enum ManifestFile { static func encode(_: Manifest, key: SecureBytes) throws -> Data /* json ‖ 32-byte HMAC-SHA256 */; static func decode(_: Data, key: SecureBytes) throws -> Manifest /* throws corruptManifest on bad MAC */ }`; `extension Manifest { func checkNotRolledBack(against lastSeen: UInt64) throws /* rollbackDetected */ }`.

- [ ] Step 1: Tests: `testMACRoundTrip`, `testTamperedJSONRejected`, `testRollbackDetected`.
- [ ] Steps 2–4 as usual. Commit `feat(core): manifest`.

### Task 6: VaultStore (file repository)

**Files:**
- Create: `Sources/VaultCore/Store/VaultStore.swift`, `Sources/VaultCore/Store/AtomicFile.swift`, `Tests/VaultCoreTests/VaultStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum AtomicFile { static func write(_ data: Data, to url: URL) throws /* temp in same dir + rename; sets 0600 */ }`
  - `public final class VaultStore { let url: URL; private(set) var header: VaultHeader; private(set) var manifest: Manifest; private var keys: VaultKeys?`
    - `static func create(at url: URL, password: SecureBytes) throws -> VaultStore` (writes `vault.vhdr`, empty `manifest.vman`, `items/`)
    - `static func open(at url: URL) throws -> VaultStore` (reads header only, locked)
    - `func unlock(password: SecureBytes) throws` / `func unlock(vaultKey: SecureBytes) throws` / `func lock()`; `var isUnlocked: Bool`
    - `func loadOverviews() throws -> (items: [ItemOverview], corrupt: [UUID])` (skips tombstones; `// reason: reads only the overview box of each file, ~300 B, so unlock is O(items) small reads`)
    - `func details(for id: UUID) throws -> ItemDetails`
    - `func save(overview: ItemOverview, details: ItemDetails) throws` (version = manifest.versions[id]+1; if a secret field changed, prepend old value to `history` capped at 10; writes item then manifest with generation+1)
    - `func delete(id: UUID) throws` (tombstone)
    - `func addSecureEnclaveSlot(_ slot: KeySlot) throws` / `func removeSecureEnclaveSlots() throws` / `var hasSecureEnclaveSlot: Bool`
    - `func changePassword(old: SecureBytes, new: SecureBytes) throws` (rewrites the password slot only)

- [ ] Step 1: Tests in a temp dir: `testCreateUnlockRoundTrip`, `testWrongPasswordLocked`, `testSaveBumpsVersionAndGeneration`, `testHistoryCapturesPreviousSecret`, `testDeleteWritesTombstone`, `testCorruptItemIsSkippedAndReported` (write 10 random bytes as an item file), `testAtomicWriteLeavesNoTempFile`, `testChangePasswordKeepsItems`.
- [ ] Steps 2–4. Commit `feat(core): VaultStore`.

### Task 7: Secure Enclave slot

**Files:**
- Create: `Sources/VaultCore/Crypto/SecureEnclaveSlot.swift`, `Tests/VaultCoreTests/SecureEnclaveSlotTests.swift`

**Interfaces:**
- Produces: `enum SecureEnclaveSlot { static var isAvailable: Bool; static func make(vaultKey: SecureBytes, context: LAContext) throws -> KeySlot /* creates SE P256 KeyAgreement key with accessControl .privateKeyUsage|.biometryCurrentSet; ephemeral P256 ECDH → HKDF("se-wrap") → AEAD.seal(vaultKey); stores ephemeral pub ‖ box as wrappedKey and SE key dataRepresentation as keyData */; static func unwrap(_ slot: KeySlot, context: LAContext) throws -> SecureBytes /* maps LAError.biometryNotEnrolled / userCancel / key invalid → VaultError.biometryUnavailable / authenticationFailed / biometryChanged */ }`.

- [ ] Step 1: Test `testRoundTripIfAvailable` guarded by `try XCTSkipUnless(SecureEnclaveSlot.isAvailable)` using an `LAContext` with `interactionNotAllowed = false`. (Will prompt Touch ID when run locally; CI-safe via skip.)
- [ ] Steps 2–4. Commit `feat(core): Secure Enclave key slot`.

### Task 8: VaultSession, search, clipboard, auto-lock

**Files:**
- Create: `Sources/Vault/Session/VaultSession.swift`, `Sources/Vault/Session/SearchIndex.swift`, `Sources/Vault/Session/Clipboard.swift`, `Sources/Vault/Session/AutoLock.swift`, `Tests/VaultCoreTests/SearchIndexTests.swift` (SearchIndex lives in `VaultCore/Search/SearchIndex.swift` so it is testable)

**Interfaces:**
- Produces:
  - `public struct SearchIndex { init(_ items: [ItemOverview]); func query(_ text: String, frontmostBundleID: String?, limit: Int = 50) -> [ItemOverview] }` — scoring: exact bundle-id link +100, title prefix +50, host prefix +40, username prefix +30, subsequence match +10, favorite +5, recency tiebreak. `// reason: in-memory linear scan over ≤10k overviews is < 1 ms; an inverted index is not worth the code.`
  - `@MainActor final class VaultSession: ObservableObject { @Published private(set) var state: State /* .noVault, .locked, .unlocked */; @Published private(set) var items: [ItemOverview]; @Published var corruptIDs: [UUID]; func createVault(password:) ; func unlock(password:); func unlockWithBiometrics() async; func lock(); func enableTouchID(password:) async throws; func disableTouchID(); func details(_ id: UUID) throws -> ItemDetails; func save(_: ItemOverview, _: ItemDetails) throws; func delete(_ id: UUID) throws; func search(_ text: String) -> [ItemOverview]; func copy(_ field: String, of id: UUID) throws; var touchIDEnabled: Bool }`
  - `enum Clipboard { static func copyConcealed(_ value: String, clearAfter: TimeInterval = 30) }` — stores `changeCount` after write; timer clears only if `NSPasteboard.general.changeCount` unchanged.
  - `final class AutoLock { init(idle: TimeInterval = 600, onLock: @escaping () -> Void) }` — observes `NSWorkspace.screensDidSleepNotification`, `willSleepNotification`, `DistributedNotificationCenter "com.apple.screenIsLocked"`, `NSApplication.willTerminateNotification`, and an idle timer reset by `NSEvent.addLocalMonitorForEvents`.

- [ ] Step 1: Tests: `testBundleIDMatchRanksFirst`, `testPrefixBeatsSubsequence`, `testEmptyQueryReturnsRecentFavoritesFirst`. Clipboard change-count behavior is tested manually (AppKit pasteboard in tests is flaky) and noted in the task.
- [ ] Steps 2–4. Commit `feat(app): session, search, clipboard, auto-lock`.

### Task 9: Main window UI (Pulse style)

**Files:**
- Create: `Sources/Vault/UI/Theme.swift`, `Sources/Vault/UI/UnlockView.swift`, `Sources/Vault/UI/CreateVaultView.swift`, `Sources/Vault/UI/MainWindow.swift`, `Sources/Vault/UI/Sidebar.swift`, `Sources/Vault/UI/ItemList.swift`, `Sources/Vault/UI/ItemDetailView.swift`, `Sources/Vault/UI/ItemEditor.swift`, `Sources/Vault/UI/OverviewCards.swift`, `Sources/Vault/UI/SettingsView.swift`
- Modify: `Sources/Vault/VaultApp.swift`

**Interfaces:**
- `Theme`: `canvas` (light grey), `card` (white), `hairline`, corner radius 14, accent per `ItemType` (login blue, apiKey orange, dbCredential green, webhook purple, secureNote grey, sshKey teal), numeral font `.system(size: 34, weight: .semibold, design: .rounded)` with tight tracking.
- `MainWindow`: `NavigationSplitView` sidebar (All, Favorites, Recent; Types; Tags) → `ItemList` (icon tile, title, username, host, updated) → `ItemDetailView` (field rows with reveal/copy, history list, linked apps/urls) in a card. Home selection shows `OverviewCards` (count per type, items older than 180 days, Touch ID state, vault path).
- `ItemEditor` sheet: type picker drives field set; "Generate" for password/apiKey (libsodium random, 24 chars default); "Rotate" in detail view = open editor with a new generated value.
- `SettingsView`: Security (auto-lock minutes, clipboard seconds, Touch ID toggle, change password), Vault (path, reveal in Finder).
- Window: `sharingType = .none` set in `onAppear` via `NSApp.windows`.

- [ ] Step 1: Build, launch `build/Vault.app`, screenshot: create vault → add a login → see it in list → reveal/copy → lock → unlock with Touch ID.
- [ ] Step 2: Commit `feat(app): main window`.

### Task 10: Quick Access panel, hotkey, menu bar

**Files:**
- Create: `Sources/Vault/QuickAccess/QuickAccessPanel.swift` (NSPanel subclass: `.nonactivatingPanel`, `.titled` off, floating, `hidesOnDeactivate`, `becomesKeyOnlyIfNeeded`), `Sources/Vault/QuickAccess/QuickAccessView.swift`, `Sources/Vault/QuickAccess/HotKey.swift` (Carbon `RegisterEventHotKey`, default ⌥Space), `Sources/Vault/UI/MenuBar.swift` (`MenuBarExtra`: lock state, Quick Access, Lock Now, Open Vault)

**Interfaces:**
- `QuickAccessController.shared.toggle()`; on show: capture `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` *before* showing the panel, pass to `SearchIndex.query`. Enter copies password/primary secret, ⌘Enter copies username, Esc hides. If locked, panel shows the unlock view (Touch ID first).
- `// reason: the panel is created once at launch and only ordered front on hotkey, so it appears in < 50 ms.`

- [ ] Step 1: Build, launch, press ⌥Space over Discord → panel lists Discord-linked items first → Enter copies → clipboard clears after 30 s → verify by screenshot and `pbpaste`.
- [ ] Step 2: Commit `feat(app): quick access and menu bar`.

### Task 11: Install

**Files:**
- Create: `README.md` (build, install to `/Applications`, first run, Touch ID note, where the vault lives), `scripts/install.sh` (bundle + copy to `/Applications` + optional login item via `SMAppService`)

- [ ] Step 1: Run `scripts/install.sh`; app in `/Applications`; launch; verify Touch ID works from the installed copy (ad-hoc signature stays identical across rebuilds only if the designated requirement is stable — document that re-enabling Touch ID after a rebuild may be needed; test and record the actual behavior).
- [ ] Step 2: Commit `docs: README and install script`.
