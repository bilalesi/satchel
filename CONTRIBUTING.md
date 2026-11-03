# Contributing

Thanks for helping. Anyone can contribute with a fork and a pull request. Only the maintainer merges.

## Process

1. Open an issue first for anything bigger than a small fix, so the idea is agreed before the work is done.
2. Fork the repository, make a branch, and keep the change focused: one thing per pull request.
3. Run `swift test` (Xcode 26, macOS 15 or newer) and add tests for what you changed.
4. Open a pull request against `main` and fill in the template. The `Test` check must pass, and a code owner must approve. The maintainer merges; there are no other merge rights.

The first run of the check on a new contributor's pull request waits for the maintainer to approve it. That is a safety measure, not a judgement.

## Rules of the house

- **Follow the existing patterns.** One pattern per problem; look at the neighbouring code first.
- **Security-sensitive code gets extra care:** cryptography, the sync engine, updates, the browser bridge and auto-type. Explain the risk in the pull request and cover the failure paths with tests.
- **No new dependencies** without an issue and agreement. libsodium is the only native dependency on purpose.
- **UI changes** need screenshots, use the spacing and type tokens in `Theme.swift`, and must not shift layout when state changes.
- **Never commit** secrets, vault files, signing keys or personal data. Secret scanning blocks known token formats on push.

## License of contributions

Satchel is under the [PolyForm Noncommercial License 1.0.0](LICENSE) for noncommercial use, and the maintainer sells a [work license](COMMERCIAL.md) for commercial use. So that one codebase can be shipped under both, by submitting a contribution you confirm that you wrote it or have the right to submit it, and you grant the maintainer a perpetual, worldwide, non-exclusive, royalty-free license to use, change, distribute and sublicense it under any license, including the commercial work license. You keep your copyright. Add `Signed-off-by: Your Name <email>` to each commit (`git commit -s`) to record this.

## Security problems

Do not file them as issues or pull requests. Follow [SECURITY.md](SECURITY.md).
