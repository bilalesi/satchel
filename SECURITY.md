# Security policy

Satchel stores secrets, so security reports are taken seriously.

## Report a vulnerability

Use a **private security advisory**: https://github.com/ekhodev/satchel/security/advisories/new

Please do not open a public issue or pull request for a vulnerability, and do not post details anywhere public before a fix is released. Include what you found, the steps or a proof of concept, the version, and what an attacker gains.

This is a one-person project, so replies are best effort. You will get an answer as soon as possible, and a credit in the release notes if you want one.

## In scope

- The vault format and cryptography (key slots, item encryption, manifest, rollback detection)
- The sync engine and all backends (folder, GitHub, Git, WebDAV, S3)
- In-app updates (signature check, download and install)
- The browser extension, the native messaging bridge and which site may receive which login
- Auto-type, Quick Access, the clipboard and screen-capture protection

## Out of scope

- An attacker who already runs code as you on an unlocked Mac
- A weak or lost master password
- Findings that need a modified build or a modified `Info.plist`

## Supported versions

Only the latest release receives fixes. Satchel offers updates inside the app.
