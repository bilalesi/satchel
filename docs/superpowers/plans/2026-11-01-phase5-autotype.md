# Phase 5 — Auto-type Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From Quick Access, ⇧↩ types the selected item's secret into the text field that was focused in the app in front (Discord, Teams, DBeaver, Terminal); ⌥↩ types the username. Nothing touches the clipboard.

**Architecture:** `AutoType` (app target) first tries the Accessibility API: read the system-wide focused element, require a text role, set `AXValue`, verify. If the app ignores that (Electron, some Java), it falls back to synthesized Unicode keystrokes via `CGEvent`. Quick Access captures the frontmost application before the panel appears, hides, re-activates that app and types. Pattern: Strategy with ordered fallbacks; refuse when the target cannot be confirmed as a text field (never type a secret into an unknown place).

**Tech Stack:** ApplicationServices (AXUIElement), CoreGraphics (CGEvent), Carbon (`IsSecureEventInputEnabled`).

**Spec:** `docs/INVESTIGATION.md` §3.3, §6.2 point 10.

**Why not the credential provider now:** `security find-identity` shows no signing identity on this Mac; the `autofill-credential-provider` entitlement needs a provisioning profile from a paid Apple Developer account. Phase 3 (credential provider) waits for that.

## Global Constraints

- Accessibility permission requested only when the user enables auto-type in Settings, never at launch.
- Typing targets only the application captured when Quick Access opened; if it is no longer frontmost after re-activation, abort with a message.
- The focused element must have a text role (`AXTextField`, `AXTextArea`, `AXSecureTextField`, `AXComboBox`, `AXSearchField`) or be editable (`AXEditableText`/settable `AXValue`); otherwise abort with "Click into a text field first".
- Secure Input on (`IsSecureEventInputEnabled`) and the AX path failed → abort with the name of the app holding secure input when it can be read; never post keystrokes blindly.
- Keystrokes: `keyboardSetUnicodeString` in chunks of 16 characters, 4 ms apart, key-down and key-up each, posted to `.cghidEventTap`; layout-independent so symbols survive.
- The secret `String` lives only inside the typing call.
- After a rebuild the ad-hoc app may lose its Accessibility grant; Settings shows the live status with a button to System Settings.

## Review Focus

1. Password field in a web page inside Electron (Discord login): AX set may "succeed" without the framework noticing → verification fails → keystroke fallback types it. (Manual.)
2. Terminal with Secure Keyboard Entry on: abort with a clear message, no keystrokes. (Manual.)
3. Focus on a chat message box instead of a password field: it is a text area, so typing goes there; this is the user's choice, the hint row says where it will type. (By design; the panel shows the target app name.)
4. Permission revoked after rebuild: first ⇧↩ shows "Accessibility permission needed" with the System Settings button. (Manual.)
5. Quick Access opened from our own window (no other app in front): ⇧↩ is disabled. (Code.)

---

### Task 1: AutoType engine

**Files:** Create `Sources/Vault/AutoType/AutoType.swift`.

**Interfaces:**
- `enum AutoTypeError: LocalizedError { case notTrusted, noTargetApp, targetNotFrontmost(String), noTextField(String), secureInput(String?), failed(String) }`
- `@MainActor enum AutoType { static var isTrusted: Bool; static func requestPermission(); static func openSystemSettings(); enum Method { case accessibility, keystrokes }; static func type(_ text: String, into app: NSRunningApplication) async throws -> Method }`

- [ ] Implement per constraints. Commit `feat(autotype): Accessibility + keystroke typing engine`.

### Task 2: Quick Access and Settings

**Files:** Modify `QuickAccessPanel.swift` (capture `frontmostApp: NSRunningApplication?`), `QuickAccessView.swift` (⇧↩ type secret, ⌥↩ type username, hint row, result/error line), `VaultSession.swift` (`typeField(_:of:into:) async -> String?` returning an error message or nil), `SettingsView.swift` (Auto-type toggle, permission status, "Open System Settings"), `AppSettings.swift` (`autoTypeEnabledKey`).

- [ ] Build, relaunch, commit `feat(app): auto-type from Quick Access`.

### Task 3: Docs

- [ ] README "Auto-type" section; investigation §10 status. Commit.
