# Third-party notices

SSH Config Manager is licensed under the Apache License, Version 2.0. See
[LICENSE.md](LICENSE.md).

The application links the components below. Each keeps its own licence and its
own copyright. This file exists to acknowledge them.

## Vendored — a copy lives in this repository

### swift-nio-ssh

`Vendor/swift-nio-ssh` is a copy of [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh)
at version 0.13.0 with an additive patch that lets the tunnel engine delegate
signing to an ssh-agent. [Vendor/PATCH.md](Vendor/PATCH.md) describes the patch.

- Licence: Apache License 2.0 — [Vendor/swift-nio-ssh/LICENSE.txt](Vendor/swift-nio-ssh/LICENSE.txt)
- Copyright: the SwiftNIO SSH project authors

### swift-bcrypt-pbkdf

`Vendor/swift-bcrypt-pbkdf` exposes OpenSSH's `bcrypt_pbkdf` key derivation
function, which decrypts passphrase-protected OpenSSH private keys. The Swift
wrapper and `sha512.c` are original work under this project's licence. The two
C files below come from OpenBSD and keep their upstream licences.

- `Sources/CBcryptPBKDF/bcrypt_pbkdf.c` — ISC licence, Copyright (c) 2013 Ted Unangst
- `Sources/CBcryptPBKDF/blowfish.c` — 3-clause BSD licence, Copyright 1997 Niels Provos

The full notice of each file is at the top of that file. Do not strip it.

## Swift packages the build resolves

| Package | Licence | Copyright |
|---------|---------|-----------|
| [apple/swift-crypto](https://github.com/apple/swift-crypto) | Apache 2.0 | The SwiftCrypto project authors |
| [apple/swift-nio](https://github.com/apple/swift-nio) | Apache 2.0 | The SwiftNIO project authors |
| [apple/swift-asn1](https://github.com/apple/swift-asn1) | Apache 2.0 | The SwiftASN1 project authors |
| [apple/swift-atomics](https://github.com/apple/swift-atomics) | Apache 2.0 | The Swift project authors |
| [apple/swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 | The Swift project authors |
| [apple/swift-system](https://github.com/apple/swift-system) | Apache 2.0 | The Swift project authors |
| [apple/swift-log](https://github.com/apple/swift-log) | Apache 2.0 | The Swift Log project authors |
| [vapor/sqlite-nio](https://github.com/vapor/sqlite-nio) | MIT | Copyright (c) 2020 Qutheory, LLC |
| [krzyzanowskim/CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) | Zlib-style attribution licence | Copyright (C) 2014 Marcin Krzyżanowski |
| [leif-ibsen/SwiftKyber](https://github.com/leif-ibsen/SwiftKyber) | MIT | Copyright (c) 2023 Leif Ibsen |
| [leif-ibsen/BigInt](https://github.com/leif-ibsen/BigInt) | MIT | Copyright (c) 2021 Leif Ibsen |
| [leif-ibsen/ASN1](https://github.com/leif-ibsen/ASN1) | MIT | Copyright (c) 2021 Leif Ibsen |
| [leif-ibsen/Digest](https://github.com/leif-ibsen/Digest) | MIT | Copyright (c) 2023 Leif Ibsen |

`CryptoSwift` requires an acknowledgment in the product documentation, and
requires every redistribution to carry this line:

> This product includes software developed by the "Marcin Krzyzanowski"
> (http://krzyzanowskim.com/).

Keep it in this file, and in any package or archive that ships the binary.

## Linux only

| Package | Licence | Copyright |
|---------|---------|-----------|
| [aparoksha/adwaita-swift](https://codeberg.org/aparoksha/adwaita-swift) | MIT | Copyright (c) 2024 david-swift |

GTK 4 and libadwaita stay dynamic. The Linux packages depend on the system
copies, so the build ships neither library.

## Fonts and icons

The application icon and the store artwork in `store-assets/` are original work
under this project's licence. The user interface uses the system font and SF
Symbols from macOS, which Apple licenses to the operating system, not to this
project. Neither is redistributed here.
