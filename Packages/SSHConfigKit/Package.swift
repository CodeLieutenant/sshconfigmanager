// swift-tools-version: 6.0
import PackageDescription

// SSHConfigKit — the shared, platform-agnostic core for SSH Config Manager,
// carved out so the Linux port can reuse it. Targets:
//   - SSHConfigCore        : pure logic/model/parsing, Foundation-only.
//   - SSHConfigCrypto      : OpenSSH key handling (swift-crypto + bcrypt).
//   - SSHConfigIntelliSense: keyword/value completion for the raw editor (pure).
//   - SSHConfigServices    : file-format services over Core+Crypto (known_hosts,
//                            key discovery/generation, grouping, edit vocabulary).
//   - SSHConfigEngine      : in-process tunnel engine (swift-nio-ssh).
//
// Swift 5 language mode matches the app target, but — unlike the app — this
// package does NOT set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so the pure
// logic is properly `nonisolated` and usable from NIO callbacks without warnings.
//
// EVERY target here builds on Linux, and must keep doing so — this package is the
// Linux port. `scripts/linux-build.sh` checks it locally and the
// `linux-core` CI job checks it on every push. No CryptoKit, no AppKit, no os.Logger,
// no Security/IOKit/StoreKit/Network: where the engine needs the host program (a
// password prompt, an ssh-agent), it declares a protocol and the front end supplies
// it — see Sources/SSHConfigEngine/AuthSeams.swift.
let package = Package(
    name: "SSHConfigKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SSHConfigCore", targets: ["SSHConfigCore"]),
        .library(name: "SSHConfigCrypto", targets: ["SSHConfigCrypto"]),
        .library(name: "SSHConfigIntelliSense", targets: ["SSHConfigIntelliSense"]),
        .library(name: "SSHConfigServices", targets: ["SSHConfigServices"]),
        .library(name: "SSHConfigEngine", targets: ["SSHConfigEngine"]),
        .library(name: "SSHConfigSync", targets: ["SSHConfigSync"]),
    ],
    dependencies: [
        // Matches the range the vendored swift-nio-ssh uses, so SwiftPM resolves a
        // single shared swift-crypto.
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
        .package(path: "../../Vendor/swift-bcrypt-pbkdf"),
        .package(path: "../../Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        // Poly1305 only, for chacha20-poly1305@openssh.com. swift-crypto exports the
        // ChaCha20 keystream (`Insecure.ChaCha20CTR`) but not Poly1305 on its own, and
        // OpenSSH's construction is not the RFC 8439 AEAD, so `ChaChaPoly` cannot be used.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.9.0"),
        // ML-KEM-768 (FIPS 203) for Apple systems below macOS 26, whose CryptoKit has
        // none. Apple-only on purpose: SwiftKyber's BigInt dependency draws randomness
        // from Security.framework's SecRandomCopyBytes, so it does not build on Linux.
        // Nothing is lost there — NIOSSH's availability check passes on non-Apple
        // platforms, so it uses swift-crypto's BoringSSL-backed MLKEM768 directly.
        .package(url: "https://github.com/leif-ibsen/SwiftKyber.git", from: "3.5.0"),
    ],
    targets: [
        .target(name: "SSHConfigCore"),
        .target(
            name: "SSHConfigCrypto",
            dependencies: [
                "SSHConfigCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BcryptPBKDF", package: "swift-bcrypt-pbkdf"),
            ]
        ),
        .target(
            name: "SSHConfigIntelliSense",
            dependencies: ["SSHConfigCore"]
        ),
        .target(
            name: "SSHConfigServices",
            dependencies: [
                "SSHConfigCore",
                "SSHConfigCrypto",
                "SSHConfigIntelliSense",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "SSHConfigEngine",
            dependencies: [
                "SSHConfigCore",
                "SSHConfigCrypto",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOSSHRSA", package: "swift-nio-ssh"),
                // _CryptoExtras (AES-CTR, ChaCha20 keystream) re-exports Crypto.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(
                    name: "SwiftKyber", package: "SwiftKyber",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "SSHConfigSync",
            dependencies: [
                "SSHConfigCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "SSHConfigIntelliSenseTests",
            dependencies: ["SSHConfigIntelliSense", "SSHConfigCore"]
        ),
        .testTarget(
            name: "SSHConfigServicesTests",
            dependencies: ["SSHConfigServices", "SSHConfigCore"]
        ),
        .testTarget(
            name: "SSHConfigSyncTests",
            dependencies: ["SSHConfigSync"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
