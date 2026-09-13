# swift-bcrypt-pbkdf

A small, self-contained Swift package exposing OpenSSH's **`bcrypt_pbkdf`** key
derivation function — the KDF that protects `-----BEGIN OPENSSH PRIVATE KEY-----`
files when they're passphrase-encrypted.

No platform crypto framework (CryptoKit, CommonCrypto, swift-crypto) ships
`bcrypt_pbkdf`, and it is **not** the same as `bcrypt` password hashing. Rather than
hand-port it, this package wraps the canonical C reference.

## What's inside

- `Sources/CBcryptPBKDF/` — the **verbatim** OpenBSD/OpenSSH reference C:
  - `bcrypt_pbkdf.c`, `blowfish.c`, `blf.h` (copied unmodified from
    [openssh-portable `openbsd-compat/`](https://github.com/openssh/openssh-portable/tree/master/openbsd-compat)).
  - Local shims only: `includes.h` (standard headers + `HAVE_*` macros +
    `explicit_bzero`/`freezero`), `crypto_api.h` + `sha512_shim.c` (provides
    `crypto_hash_sha512` via Apple's CommonCrypto, so no SHA-512 needs vendoring),
    and the public `include/bcrypt_pbkdf.h`.
- `Sources/BcryptPBKDF/` — a thin Swift wrapper: `BcryptPBKDF.derive(passphrase:salt:rounds:keyLength:)`.

## Usage

```swift
import BcryptPBKDF

let key = BcryptPBKDF.derive(
    passphrase: Array("hunter2".utf8),
    salt: saltBytes,
    rounds: 16,
    keyLength: 48)   // -> [UInt8]? (key || IV for the cipher)
```

## Tests

`swift test` runs a known-answer vector from the OpenBSD reference implementation
(`password`/`salt`/12 rounds/32 bytes →
`1ae42c05d487bc02f64921a4ebe4ea93bcacfe135fda99974c06b7b01fae149a`).

## Updating the vendored C

Re-copy `bcrypt_pbkdf.c`, `blowfish.c`, `blf.h` from openssh-portable's
`openbsd-compat/`. Do not edit them; all platform glue lives in the shim files.
macOS only (the SHA-512 shim uses CommonCrypto).
