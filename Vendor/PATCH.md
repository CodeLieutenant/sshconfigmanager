# Vendored swift-nio-ssh (patched)

`Vendor/swift-nio-ssh` is a local copy of **apple/swift-nio-ssh @ 0.13.0** with a
small additive patch that lets the in-process tunnel engine authenticate via the
ssh-agent (which never exports the private key, so the upstream
`Offer.privateKey(NIOSSHPrivateKey)` — where NIOSSH signs with in-memory key
material — can't be used). The project references this folder as a local Swift
package (`XCLocalSwiftPackageReference` in `sshconfigmanager.xcodeproj`).

## Why a fork
swift-nio-ssh 0.13.0 has no delegated-signing hook: `NIOSSHPrivateKey` is a closed
enum over CryptoKit keys and signs the user-auth payload internally. The patch adds
an **external-signer** public-key offer so signing can be delegated to an
ssh-agent, with NIOSSH still building the exact signable bytes.

## Patch 1 — External-signer public-key auth (ssh-agent delegation)

1. **`Sources/NIOSSH/User Authentication/UserAuthenticationMethod.swift`**
   - New `NIOSSHUserAuthenticationOffer.Offer.externalKey(ExternalKey)` case.
   - New `ExternalKey` struct: `publicKey: NIOSSHPublicKey` + an async signer
     `sign: @Sendable (ByteBuffer) async throws -> NIOSSHSignature`.
   - The synchronous `SSHMessage.UserAuthRequestMessage.init(request:sessionID:)`
     gains a `case .externalKey:` that `preconditionFailure`s — it's only ever
     built through the async path below.

2. **`Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift`**
   - `requestNextAuthRequest(...)` already mapped the delegate's offer into a
     request *inside a future* with the captured `sessionID`. Changed
     `flatMapThrowing` → `flatMap` and added an `.externalKey` branch: it builds the
     internal `UserAuthSignablePayload` (so the signed bytes are always correct),
     bridges the async signer via `loop.makeFutureWithTask { try await sign(bytes) }`,
     and emits `.publicKey(.known(key:signature:))`. All other offers keep the
     original synchronous construction.

3. **`Sources/NIOSSH/Keys And Signatures/NIOSSHSignature.swift`**
   - New `public init(sshWire blob: [UInt8]) throws` wrapping the internal
     `ByteBuffer.readSSHSignature()`, so app code can turn an ssh-agent
     `SSH2_AGENT_SIGN_RESPONSE` signature blob into a `NIOSSHSignature`.

No upstream behavior changes; everything is additive. `NIOSSHPublicKey(openSSHPublicKey:)`
is already public, so building the offered public key from an agent identity needs
no patch.

---

## Patch 2 — `NIOSSHAvailableUserAuthenticationMethods.keyboardInteractive` flag

- **`Sources/NIOSSH/User Authentication/UserAuthenticationMethod.swift`**  
  Added `.keyboardInteractive` (rawValue: 1 << 3) to the OptionSet, `"keyboard-interactive"`
  string recognised in `init(_ message:)` and emitted in `strings`. App code can now
  detect when a server advertises keyboard-interactive without the client offering it.

---

## Patch 3 — Full keyboard-interactive (RFC 4256) support

Adds end-to-end support for SSH keyboard-interactive authentication (PAM / TOTP).
Nine files modified, all additive. See `docs/pam-auth.md` for background.

### `Sources/NIOSSH/SSHMessages.swift`

- New `SSHMessage.userAuth60Raw(ByteBuffer)` case: the inbound parser captures raw
  bytes for wire ID 60 instead of eagerly parsing as `UserAuthPKOKMessage`.
  Context-based decoding in the state machine resolves the ID-60 ambiguity.
- New `SSHMessage.userAuthInfoResponse(UserAuthInfoResponseMessage)` case for
  outbound ID 61.
- New structs `UserAuthInfoRequestMessage` (ID 60, client-inbound) and
  `UserAuthInfoResponseMessage` (ID 61, client-outbound) with RFC 4256 §3.3 wire
  encoding helpers.
- New `"keyboard-interactive"` case in `UserAuthRequestMessage.Method` and its
  parser/serialiser.
- `writeSSHMessage()` updated to handle the two new outbound cases.

### `Sources/NIOSSH/User Authentication/UserAuthenticationMethod.swift`

- `NIOSSHUserAuthenticationOffer.Offer.keyboardInteractive` case added.
- `SSHMessage.UserAuthRequestMessage.init(request:sessionID:)` handles
  `.keyboardInteractive` (empty language-tag and submethods per RFC 4256 §3.1).

### `Sources/NIOSSH/User Authentication/ClientUserAuthenticationDelegate.swift`

- New `NIOSSHKeyboardInteractiveDelegate` protocol. Called once per
  `SSH_MSG_USERAUTH_INFO_REQUEST`.

### `Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift`

- `lastSentAuthMethod` tracking (`.none`, `.publicKey`, `.keyboardInteractive`).
- `keyboardInteractiveDelegate` property.
- `receiveUserAuth60Raw(_:)`: decodes ID 60 bytes as INFO_REQUEST or PK_OK based on
  `lastSentAuthMethod`, calls the delegate, returns a future of INFO_RESPONSE.
- `sendUserAuthInfoResponse(_:)` no-op to satisfy the state machine's send path.

### `Sources/NIOSSH/Connection State Machine/Operations/AcceptsUserAuthMessages.swift`

- `receiveUserAuth60Raw(_:)` delegates to the state machine and routes the returned
  future through `.possibleFutureMessage`.

### `Sources/NIOSSH/Connection State Machine/Operations/SendsUserAuthMessages.swift`

- `writeUserAuthInfoResponse(_:into:)` added for outbound ID 61.

### `Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift`

- Inbound `.userAuthentication` switch: `case .userAuth60Raw` replaces
  `case .userAuthPKOK`.
- Outbound `.userAuthentication` switch: `case .userAuthInfoResponse` added.

### `Sources/NIOSSH/SSHClientConfiguration.swift`

- `keyboardInteractiveDelegate: (any NIOSSHKeyboardInteractiveDelegate)?` property
  (default `nil`).

### `Sources/NIOSSH/Connection State Machine/States/SentNewKeysState.swift` and `ReceivedNewKeysState.swift`

- Both `UserAuthenticationStateMachine` initialisers inject
  `config.keyboardInteractiveDelegate` from the client configuration.

---

## Patch 4 — CustomKeys extension API + RFC 8332 groundwork

Adds a public extension point so app code can plug in key/signature types NIOSSH
doesn't ship (used by the `NIOSSHRSA` target below). Ported from the Citadel
`citadel2` fork (which is based on apple 0.4.0 — these are re-applied by hand onto
0.13.0, not merged), with the RFC 8332 hooks folded in from
`Wellz26/swift-nio-ssh` **PR #3** ("Allow keys to declare a distinct user-auth
algorithm name"). Scoped to public-key auth only — the fork's custom key-exchange
and transport-protection registration is intentionally **not** ported.

- **New `Sources/NIOSSH/Keys And Signatures/CustomKeys.swift`** — the
  `NIOSSHSignatureProtocol` / `NIOSSHPublicKeyProtocol` / `NIOSSHPrivateKeyProtocol`
  protocols (all `: Sendable`, since the backing enums are `Sendable`), the
  `NIOSSHAlgorithms.register(publicKey:signature:)` API, and the process-wide
  registry (`NIOLock`-guarded). RFC 8332 additions: `acceptedSignaturePrefixes` and
  `publicKeyAuthAlgorithmName` with default implementations.
- **`NIOSSHPublicKey.swift`** — `.custom(NIOSSHPublicKeyProtocol)` backing case +
  dispatch in the three `isValidSignature` overloads, `keyPrefix`,
  `Equatable`/`Hashable`, and the host-key `write`/`read` paths; plus
  `userAuthAlgorithmName` and the custom-aware `knownAlgorithms` (PR #3).
- **`NIOSSHPrivateKey.swift`** — `.custom` backing case, `init(custom:)`,
  `hostKeyAlgorithms`, `sign`, and `publicKey` dispatch.
- **`NIOSSHSignature.swift`** — `.custom(NIOSSHSignatureProtocol)` backing case +
  `Equatable`/`Hashable`/`write`, and a custom lookup in `readSSHSignature` that
  matches any `acceptedSignaturePrefixes` (PR #3).
- **`NIOSSHCertifiedPublicKey.swift`** — `.custom` arm in `keyPrefix` (custom keys
  are not supported as certificate base keys; `preconditionFailure`).
- **`SSHMessages.swift`** + **`UserAuthSignablePayload.swift`** — the two userauth
  consistency checks accept `keyPrefix` *or* `userAuthAlgorithmName`, and the
  publickey request / signable payload are written with `userAuthAlgorithmName`
  (PR #3). This is what lets an `ssh-rsa` key blob authenticate as `rsa-sha2-256`.

### New target: `NIOSSHRSA`

`Sources/NIOSSHRSA/RSA.swift` + a second library product in `Package.swift`.
Implements `Insecure.RSA.PublicKey/PrivateKey/Signature` on top of swift-crypto's
`_CryptoExtras._RSA.Signing` (RSASSA-PKCS1-v1_5 over SHA-256). **No BigInt and no
`CCryptoBoringSSL` SPI** — deliberately not a verbatim port of Citadel's
BoringSSL-based RSA. Call `Insecure.RSA.register()` once at startup. The SSH wire
string/mpint helpers are reimplemented locally on public NIOCore API because
NIOSSH's own helpers are `internal`.

## Patch 5 — Don't crash on window adjust for a closed child channel

`Wellz26/swift-nio-ssh` **PR #2**. `ChildChannelStateMachine.sendChannelWindowAdjust`
throws `NIOSSHError.protocolViolation` instead of `preconditionFailure` for the
`closedLocally` / `closedRemotely` / `closed` states (reachable when a buffered read
is serviced after the child channel closed). `requestedLocally`/`requestedRemotely`
keep the precondition.

## Patch 6 — Public hook to send an opaque named global request (client keepalive)

**`Sources/NIOSSH/NIOSSHHandler.swift`** — new `public func sendGlobalRequest(named:promise:)`,
a thin public wrapper around the existing (internal) `sendGlobalRequestMessage`.
Needed so the app can send an OpenSSH-style `keepalive@openssh.com` global request
to implement `ServerAliveInterval`: upstream has no public API for an arbitrary
named global request (only `sendTCPForwardingRequest`), and `SSHMessage` /
`GlobalRequestMessage` are `internal` to the module, so the app has no other way
to construct one itself. Purely additive — no existing behavior changed.

## Patch 7 — `KexAlgorithms`/`HostKeyAlgorithms` override support

Lets the app enforce `ssh_config`'s `KexAlgorithms`/`HostKeyAlgorithms` directives,
which upstream hardcodes as static, non-configurable lists on the client role.

- **`Sources/NIOSSH/SSHClientConfiguration.swift`**
  - Two new `var` properties, `keyExchangeAlgorithmsOverride: [String]?` and
    `hostKeyAlgorithmsOverride: [String]?`, both defaulting to `nil` (Optional
    properties with no inline initializer default to `nil` automatically — no init
    signature change needed, same technique as `keyboardInteractiveDelegate` in
    Patch 3). `nil` reproduces today's behavior exactly.
  - Two new `public static` computed properties, `supportedKeyExchangeAlgorithms`
    and `supportedHostKeyAlgorithms` (`[String]`), re-exposing
    `SSHKeyExchangeStateMachine`'s existing internal static lists of the same name.
    `SSHKeyExchangeStateMachine` itself has no access modifier (module-internal), so
    its members are unreachable from the app regardless of their own visibility —
    these re-exports are the only way for app code to validate a configured
    `KexAlgorithms`/`HostKeyAlgorithms` value shares at least one algorithm with what
    this fork actually supports *before* connecting, rather than discovering an
    empty/no-op override mid-handshake.
- **`Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift`**
  - `createKeyExchangeMessage()`'s `keyExchangeAlgorithms:` field now reads a new
    private computed property, `offeredKeyExchangeAlgorithms`, instead of the static
    `Self.supportedKeyExchangeAlgorithms` directly. On the `.client` role, this
    intersects `configuration.keyExchangeAlgorithmsOverride` (when set) against
    `Self.supportedKeyExchangeAlgorithms`, **preserving the override's order** —
    real preference order, not alphabetical/hardcoded. `nil` override (the default)
    returns `Self.supportedKeyExchangeAlgorithms` unchanged.
  - `supportedHostKeyAlgorithms`'s `.client` case (previously an unconditional
    return of `Self.supportedServerHostKeyAlgorithms`) gained the same
    override-intersection logic reading `configuration.hostKeyAlgorithmsOverride`.
    The `.server` case is untouched.
  - `expectingIncorrectGuess(_:)` — the SSH "optimistic guessed KEXINIT" check —
    previously compared the peer's message against the **static**
    `Self.supportedKeyExchangeAlgorithms.first`. Updated to compare against
    `self.offeredKeyExchangeAlgorithms.first` (what this instance *actually*
    offered), since an override can change the first-preference algorithm; leaving
    the static comparison in place would have made this check silently wrong
    whenever an override reordered the client's first preference, misclassifying a
    correct guess as incorrect (or vice versa) for any override-restricted
    connection. Caught by `testOverrideRestrictsAndReordersKeyExchangeAlgorithms`
    during development — the first attempt (only adding the two computed
    properties, not updating this comparison or actually swapping in
    `offeredKeyExchangeAlgorithms` at the call site) built cleanly but the override
    silently had zero effect; see the dedicated test suite below for the regression
    guard.
- No changes to `SentKexInitWhenActiveState.swift`/`KeyExchangeState.swift`/
  `ReceivedKexInitWhenActiveState.swift` — the override is read from `self.role`
  (already threaded through unchanged), not a new constructor parameter, so all
  three `SSHKeyExchangeStateMachine.init` call sites are untouched.
- **`PubkeyAcceptedAlgorithms` is *not* implemented by this patch.** The app parses
  and threads it through (`TunnelHop.pubkeyAcceptedAlgorithms` /
  `ConnectionHop.pubkeyAcceptedAlgorithms`), but nothing filters on it yet: this
  fork exposes no public API to read a loaded key's algorithm name (`NIOSSHPublicKey`
  has zero public members beyond its initializers), so enforcing this directive
  needs its own follow-up patch to expose one. **`RekeyLimit` is also out of scope**
  — it needs a public trigger for the internal `_rekey()` plus new byte/time-based
  accounting in the app, which is closer in size to a new feature than a flag.
- **New test suite**: `Tests/NIOSSHTests/SSHKeyExchangeStateMachineTests.swift` →
  `KeyExchangeAlgorithmOverrideTests` — unset override reproduces the default
  algorithm lists exactly; a set override restricts *and reorders* both the KEX and
  host-key lists to match the override (not the default preference order); an
  override naming an algorithm this fork doesn't implement drops it rather than
  crashing or silently keeping it. Verified these are genuinely new coverage, not
  just re-testing existing behavior, by confirming the *first* version of this patch
  (before the `offeredKeyExchangeAlgorithms` field was actually wired into
  `createKeyExchangeMessage()`) failed 3 of 4 of these tests.
- No upstream behavior changes for any existing caller — every one of the ~330
  pre-existing vendored NIOSSH tests that passed before this patch still passes
  identically after it (confirmed via `git stash` isolating just this patch's files
  and re-running the full suite both with and without them: same 513 pre-existing
  failures either way, unrelated to this patch — see the note below).

**Pre-existing test baseline note**: this vendored fork's own test suite
(`swift test` from `Vendor/swift-nio-ssh/`) already had 513 failing assertions
*before* Patch 7, entirely from `UserAuthenticationStateMachineTests` fixtures
written against upstream's 3-method auth list (`password`/`publickey`/`hostbased`)
that don't expect the 4th, `keyboard-interactive`, added by Patch 2/3. This is a
known, already-accepted gap between this fork's own test fixtures and its patched
behavior — it is **not** a regression from Patch 7, and is out of scope to fix here
(re-writing patched vendored test fixtures is a separate, deliberate piece of work).
The app-level re-apply checklist below (`TunnelStoreTests`/`OpenSSHKeyTests`) is the
actual regression gate; the vendored fork's own suite is consulted per-patch for
newly-added coverage, not as an all-green gate.

## PR #1 (keyboard-interactive) — evaluated, **not** adopted

`Wellz26/swift-nio-ssh` PR #1 is an alternative keyboard-interactive implementation.
It was compared against our existing Patch 3 and intentionally **not** merged: PR #1's
delegate is *synchronous* (`respondToKeyboardInteractiveChallenge(...) -> [String]`),
which would block the event loop, whereas Patch 3's delegate is *asynchronous*
(`handleChallenge(..., responsePromise:)`) — required for this GUI app, which prompts
the user for a TOTP/PAM code at connect time. Patch 3 also already solves the
SSH message-ID-60 (PK_OK vs INFO_REQUEST) ambiguity via `lastSentAuthMethod`. Keeping
one mechanism (Patch 3) avoids duplicate, conflicting code paths.

---

## Re-applying on an upstream bump
1. Replace `Vendor/swift-nio-ssh` with the new upstream tag (keep `Package.swift`,
   including the `NIOSSHRSA` product/target, and the whole `Sources/NIOSSHRSA`
   directory and `Sources/NIOSSH/Keys And Signatures/CustomKeys.swift`).
2. Search for `NIOSSH patch (sshconfigmanager)` across
   `Vendor/swift-nio-ssh/Sources/NIOSSH` to locate every modified line.
3. Re-apply patches 1–6 as described above.
4. Build (`CODE_SIGNING_ALLOWED=NO`) and run `sshconfigmanagerTests/TunnelStoreTests`
   and `sshconfigmanagerTests/OpenSSHKeyTests`.

---

## swift-bcrypt-pbkdf: cross-platform SHA-512 (Linux groundwork)

`Sources/CBcryptPBKDF/sha512_shim.c` provided `crypto_hash_sha512` via Apple's
CommonCrypto only — the one Darwin-only dependency in the crypto stack. It's now
guarded:
- **Apple:** CommonCrypto `CC_SHA512` (unchanged).
- **non-Apple:** OpenSSL libcrypto `SHA512` (`#include <openssl/sha.h>`), with
  `-lcrypto` linked on Linux/Android/Windows via `CBcryptPBKDF`'s `linkerSettings`
  in `Package.swift`.

The non-Apple path is portability groundwork and has **not** been exercised on
Linux from this repo yet. macOS behavior is unchanged (CommonCrypto). If a future
Linux build can't find `<openssl/sha.h>` / `-lcrypto`, install the OpenSSL dev
package (e.g. `libssl-dev`).

## Patch 8 — AEAD ciphers must skip MAC negotiation

Upstream fails the whole key exchange against any server whose MAC list shares no
name with ours, even when the negotiated cipher is AES-GCM and the MAC lists are
therefore meaningless.

- **`Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift`**
  - `negotiatedTransportProtection(...)` returns `Self.implicitMACName` instead of
    intersecting the MAC lists, when the chosen cipher belongs to a protection
    scheme with `macName == nil` (the AEAD schemes: AES-GCM in OpenSSH mode).
  - New `static let implicitMACName: Substring = "<implicit>"`. It never goes on
    the wire. It only has to compare equal for both directions in
    `negotiatedAlgorithms`'s symmetry check, and to match an AEAD scheme's
    `macName == nil` in the scheme lookup right after it.

### Why
`supportedMacAlgorithms` fabricates a single `hmac-sha2-256` entry when every
protection scheme is AEAD, with an upstream comment that says the peer might
actually want it. OpenSSH never does: `kex_choose_conf` calls `choose_mac` only
when the chosen cipher has no `authlen`, and reports the MAC as `<implicit>`.

An OpenSSH 9.x server hardened to ETM-only MACs (`hmac-sha2-512-etm@openssh.com,
hmac-sha2-256-etm@openssh.com`, a common distribution default) shares no name with
`hmac-sha2-256`, so every connection failed at the MAC step — after the cipher had
already agreed on `aes256-gcm@openssh.com`. Worse, `NIOSSHHandler` reports the
failure with `fireErrorCaught` and leaves the channel open, so the client fell
silent and the user saw a tunnel that hung for ~23 s and then reported nothing
useful. (The app closes the channel on that error now; see
`SSHHopChainConnector.UserAuthWaitHandler.errorCaught`.)

Test: `testAEADCipherIgnoresAnETMOnlyMACList` in
`Tests/NIOSSHTests/SSHKeyExchangeStateMachineTests.swift`.

## Patch 9 — RFC 4253 § 7.2 key derivation, shared across key exchange methods

Upstream derives each of the six session keys as `.prefix(n)` of a single hash, which caps
key material at the key exchange's digest length. `hmac-sha2-512` wants a 64-byte integrity
key, and `curve25519-sha256` can only give 32.

- **New `Sources/NIOSSH/Key Exchange/SSHKeyDerivation.swift`**
  - `SSHKeyDerivation.sessionKeys(baseHasher:sessionID:ourRole:expectedKeySizes:)` derives
    all six keys from a hasher already updated with `K || H`, applying the extension step
    (`K2 = HASH(K || H || K1)`, …) whenever more bytes are wanted than one hash produces.
- **`Sources/NIOSSH/Key Exchange/EllipticCurveKeyExchange.swift`**
  - The six per-key generators and `generateSpecificHash` are gone; `generateKeys` folds `K`
    in as an mpint and delegates. `update(byte:)`/`update(bufferPointer:)` widened to internal.

Each method keeps ownership of how `K` is encoded, which is the one thing that differs
between ECDH (mpint) and the post-quantum hybrid (string).

## Patch 10 — AES-CTR ciphers with HMAC-SHA2 integrity

Upstream bundles only AES-GCM. A server with GCM disabled — common in FIPS-oriented and
hardened builds — shares no cipher and the connection cannot be made at all.

- **New `Sources/NIOSSH/TransportProtection/AESCTR.swift`**
  - `aes128-ctr`, `aes192-ctr`, `aes256-ctr`, each paired with `hmac-sha2-256`,
    `hmac-sha2-512` and their `-etm@openssh.com` variants: twelve schemes, the full cross
    product. SSH negotiates the cipher and the MAC independently, so whichever pair
    negotiation lands on must have a scheme that implements it.
  - Encrypt-and-MAC (RFC 4253) and encrypt-then-MAC (`-etm@openssh.com`) framings, a
    128-bit big-endian CTR counter that runs continuously across packets per RFC 4344 § 4,
    and a constant-time tag comparison.
  - `AES._CTR` comes from `_CryptoExtras`, `HMAC` from `Crypto`. The NIOSSH target now
    depends on `_CryptoExtras` (which re-exports `Crypto`) instead of `Crypto` directly,
    following the workaround documented on NIOSSHRSA.
- **`Sources/NIOSSH/Constants.swift`** — the twelve schemes registered after the AEAD ones.
- **`Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift`** — the advertised cipher
  and MAC lists are de-duplicated, since one cipher name now appears in several schemes.
- **`Sources/NIOSSH/TransportProtection/AESGCM.swift`** — `prependData` and
  `removePaddingBytes` widened to internal so both schemes share them.

Test: `Tests/NIOSSHTests/AESCTRTests.swift`.

## Patch 11 — `decryptFirstBlock` receives the packet sequence number

`chacha20-poly1305@openssh.com` encrypts the length field under a second key whose nonce is
the packet sequence number. Upstream passes the sequence number only to
`decryptAndVerifyRemainingPacket`, so that scheme could not be implemented without shadowing
the parser's counter — and the counter runs for the life of the connection, so a scheme
installed at a rekey has no way to learn where it currently is.

- **`Sources/NIOSSH/TransportProtection/SSHTransportProtection.swift`** — the protocol
  requirement becomes `decryptFirstBlock(_:sequenceNumber:)`.
- **`Sources/NIOSSH/SSHPacketParser.swift`** — passes `self.sequenceNumber`, the same value
  the matching `decryptAndVerifyRemainingPacket` call gets.
- The AES-GCM and AES-CTR schemes ignore it.

The scheme that needs this lives in the app
(`SSHConfigMacUI/Services/ChaCha20Poly1305Protection.swift`) rather than here, because
Poly1305 needs a third-party library and this fork is kept dependency-light so it stays
rebasable. `NIOSSHTransportProtection` is public, so the app registers it through
`SSHClientConfiguration.transportProtectionSchemes`.

## Patch 12 — `mlkem768x25519-sha256` post-quantum hybrid key exchange

The key exchange method OpenSSH 9.9 offers first, and the only one some hardened servers
accept. Upstream's key exchange abstraction is hardcoded to an ECDH shape.

- **New `Sources/NIOSSH/Key Exchange/MLKEMX25519KeyExchange.swift`**
  - `MLKEM768X25519KeyExchange` conforms to `EllipticCurveKeyExchangeProtocol` and reuses the
    ECDH message pair, whose payload is one opaque SSH string either way. `C_INIT` is the
    1184-byte ML-KEM-768 encapsulation key followed by a 32-byte X25519 public key;
    `S_REPLY` is the 1088-byte ciphertext followed by the server's X25519 public key.
  - `K = SHA256(K_ML-KEM ‖ K_X25519)`, fed into the exchange hash and the key derivation as
    an SSH **string** rather than an mpint — the one encoding difference from every ECDH
    method, and the one that silently breaks the handshake if it is wrong.
  - Client and server sides are both implemented.
- **`Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift`** —
  `supportedKeyExchangeImplementations` becomes a computed list that includes the hybrid
  first, and only where ML-KEM exists.

- **New `Sources/NIOSSH/Key Exchange/MLKEM768Backend.swift`**
  - `NIOSSHMLKEM768Backend` / `NIOSSHMLKEM768PrivateKey`: a public seam for the ML-KEM
    implementation, plus `NIOSSHMLKEM.registerBackend(_:)` to install one (nil clears it).
  - A built-in `CryptoKitMLKEM768Backend`, used automatically where the system has ML-KEM.

`MLKEM768` comes from swift-crypto, which forwards to CryptoKit on Apple platforms, where it
requires macOS 26 / iOS 26. Rather than drop the method below that, an application registers
a portable implementation through the seam — SSH Config Manager registers a SwiftKyber-backed
one in `SSHConfigMacUI/Services/PortableMLKEMBackend.swift`, so the method is available on
every system it supports. The third-party dependency stays an application concern; this fork
still depends only on swift-nio, swift-crypto and swift-atomics.

With neither a registered backend nor CryptoKit's, the method is not offered and negotiation
falls back to `curve25519-sha256`, which every server offering the hybrid also offers.
`supportedKeyExchangeImplementations` and `supportedKeyExchangeAlgorithms` became computed
properties so registration order cannot leave a stale offer behind.

Tests: `testPrefersTheMLKEMHybridWhenTheServerOffersIt` and
`testFallsBackToECDHWhenTheServerHasNoPQMethod` in
`Tests/NIOSSHTests/SSHKeyExchangeStateMachineTests.swift`.

## Patch 13 — Report the negotiated algorithms

Upstream keeps the negotiation result entirely private, so an application cannot tell whether
a connection is running over `aes256-gcm@openssh.com` or something broken. SSH Config Manager
shows it in the tunnel console and flags weak choices.

- **New `Sources/NIOSSH/Key Exchange/NIOSSHNegotiatedAlgorithms.swift`** — a public
  `Hashable`/`Sendable` value holding the negotiated key exchange, host key algorithm,
  cipher and MAC (`<implicit>` when an AEAD cipher negotiated none).
- **`Sources/NIOSSH/Key Exchange/SSHKeyExchangeStateMachine.swift`** — records the result
  each time one is computed, so it survives past the point the state machine's own
  `negotiated` value goes out of scope.
- **`.../Operations/AcceptsKeyExchangeMessages.swift`** — `receiveNewKeysMessage()` returns it.
- **`.../SSHConnectionStateMachine.swift`** — the three NEWKEYS sites turn it into
  `.event(...)`, which `NIOSSHHandler` already fires as a user inbound event. Also fires
  after a rekey, deliberately: the algorithms can change.

Nothing reads this to make a decision inside NIOSSH — it is purely informational.

The alternative was to re-derive the negotiation app-side from both KEXINIT messages, which
needs no fork change but duplicates RFC 4253's selection rules. A copy that silently
disagreed would report the wrong cipher in a security UI, which is worse than not reporting.

## Notes for the offered-algorithm capture (no fork change)

`SSHConfigMacUI/Services/KexInitCapture.swift` reads a peer's `SSH_MSG_KEXINIT` directly off
the wire from a handler placed ahead of `NIOSSHHandler`. It needs no patch here because that
packet precedes any key exchange and is therefore plaintext.

It exists because the negotiated report cannot answer "is this server configured sensibly":
this engine implements nothing weak, so it would never agree to `3des-cbc` or `hmac-sha1` no
matter what the peer offers — a server that happily accepts them for other clients looks
clean from the connection's point of view.

## Dependency notes

Three of these patches move cryptography onto pure-Swift libraries. The tradeoffs,
in one place, because the source comments each only see their own half:

| Primitive | Library | Where it runs | Why not swift-crypto |
|-----------|---------|---------------|----------------------|
| Poly1305 | CryptoSwift | Every `chacha20-poly1305@openssh.com` packet | swift-crypto exports the ChaCha20 keystream (`Insecure.ChaCha20CTR`) but not Poly1305 alone, and OpenSSH's construction is not the RFC 8439 AEAD, so `ChaChaPoly` cannot produce these tags. |
| ML-KEM-768 | SwiftKyber | Key exchange only, and only below macOS 26 | CryptoKit gained `MLKEM768` in the 26 releases. Above that line the system implementation wins and SwiftKyber is never called. |

What this costs:

- **Throughput.** CryptoSwift's Poly1305 is pure Swift, against BoringSSL for
  AES-GCM. `chacha20-poly1305@openssh.com` therefore sits *behind* both AES-GCM
  schemes in `SSHHopChainConnector.allTransportProtectionSchemes`, so it is only
  reached by a server that offers nothing else. On such a server it carries bulk
  tunnel traffic, and it will be slower than AES-GCM would have been.
- **Audit status.** CryptoSwift ships an explicit "not audited, use at your own
  risk" notice. It authenticates packets, so a defect there is an integrity
  defect. The scheme is offered for reach, not because it is the preferred one.
- **Supply chain.** SwiftKyber pulls in BigInt, ASN1 and Digest. Four packages
  enter the shipping app for two primitives.

ML-KEM's exposure is smaller than it looks: `PortableMLKEMBackendTests` runs
encapsulation and decapsulation across the SwiftKyber and CryptoKit
implementations in both directions, so the portable path is checked against
Apple's rather than only against itself.

## Patch 14 — Bound the peer's packet_length

`packet_length` is read before anything authenticates it: in the clear for AES-GCM and the
encrypt-then-MAC schemes, and merely decrypted for `chacha20-poly1305@openssh.com` and
AES-CTR encrypt-and-MAC. Upstream believes whatever the peer writes there.

- **`Sources/NIOSSH/Constants.swift`** — new `maximumPacketLength`, `(1 << 24) + 1024`.
- **`Sources/NIOSSH/SSHPacketParser.swift`** — both length paths reject a longer packet.
  `decryptLength` checks *before* it adds `macBytes`, and the cleartext path checks in
  `nextPacket`.

### Why

Two failures, both reachable from the first packet of a connection:

1. **Remote crash.** `decryptLength` returned `length + UInt32(protection.macBytes)`. Swift
   traps on unsigned overflow, so a `packet_length` within `macBytes` of `UInt32.max` killed
   the process with SIGTRAP — no error, no reconnect. The window is as wide as the largest
   MAC negotiated, which these patches raised from 16 bytes to 64.
2. **Unbounded buffering.** A length below the overflow point was simply waited on. Four
   gigabytes of buffering, held open by one packet.

The bound is not RFC 4253 § 6.1's 35000. It is tied to the `maximumPacketSize` this fork
advertises when it opens a child channel (`1 << 24`, `SSHChildChannel`): a peer that takes
us at our word may send a channel data message that large, so a smaller cap would refuse
traffic we invited. Raise both together or neither.

Tests: `Tests/NIOSSHTests/PacketLengthBoundTests.swift` — the overflow window across every
MAC width, an absurd non-overflowing length, the cleartext path, and both sides of the
boundary.

## Interoperability testing

Every patch above changes what goes on the wire, and a fork's own test suite cannot
check that: this client talking to this client agrees with itself no matter how
wrong it is. `Packages/SSHConfigMacUI/Tests/SSHConfigMacUITests/OpenSSHInteropTests.swift`
answers the question a second implementation has to answer.

Each test starts a private `sshd` on loopback, restricted to one algorithm, with a
generated host key and one authorised key in a temporary directory. It then opens a
real tunnel through it and moves bytes. Nothing reads or writes the user's ssh
configuration, no system service starts, and the directory is deleted afterwards.
A test skips itself when the host has no `sshd`, or an `sshd` too old for the
algorithm it needs.

Covered: `mlkem768x25519-sha256` (forced, and chosen unprompted), ECDH fallback,
AES-GCM, AES-CTR under both encrypt-then-MAC and encrypt-and-MAC, `hmac-sha2-512`'s
oversized key through the § 7.2 extension step, `chacha20-poly1305@openssh.com`, and
the hybrid combined with AES-CTR.

Two properties keep the suite diagnostic:

1. `ecdhStillInteroperates` is a control. If the hybrid test goes red while this one
   stays green, the fault is in `mlkem768x25519-sha256` and not in the harness or the
   machine.
2. Cipher tests pin the key exchange to `curve25519-sha256`. The hybrid is offered
   first, so without that pin one key-exchange defect turns every cipher test red and
   the suite stops naming the broken layer.

Verified load-bearing: removing the SSH string length prefix from `K` in
`MLKEMX25519KeyExchange.finalize` fails `mlkemHybridInteroperatesWithOpenSSH` with
`NIOSSHError.invalidExchangeHashSignature` while both ECDH tests still pass.
