# Third-party notices

Satchel itself is licensed under the PolyForm Noncommercial License 1.0.0 (see `LICENSE`). It includes or links the following, and each keeps its own license.

| Component | Used for | License |
|---|---|---|
| [libsodium](https://github.com/jedisct1/libsodium) (via [swift-sodium](https://github.com/jedisct1/swift-sodium)) | Argon2id, XChaCha20-Poly1305, secure memory | ISC |
| [Codicons](https://github.com/microsoft/vscode-codicons) by Microsoft | Interface icons (font in `Resources/Fonts`) | CC BY 4.0 |
| [Public Suffix List](https://publicsuffix.org) | Deciding which websites count as the same site | Mozilla Public License 2.0 |

## ISC license (libsodium, swift-sodium)

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

Copyright (c) 2013-2024 Frank Denis (libsodium); Copyright (c) 2015-2024 Frank Denis (swift-sodium).

## Codicons (CC BY 4.0)

Icons are © Microsoft Corporation, licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). The license text ships next to the font in `Resources/Fonts/codicon-LICENSE.txt`.

## Public Suffix List (MPL 2.0)

The list is compiled into `Sources/VaultCore/Browser/PublicSuffixData.swift` unmodified except that comment lines are removed. The list and its license are available at https://publicsuffix.org and https://mozilla.org/MPL/2.0/. `scripts/update-psl.sh` regenerates the file.
