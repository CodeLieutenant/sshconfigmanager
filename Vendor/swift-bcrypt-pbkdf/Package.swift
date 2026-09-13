// swift-tools-version:5.9
import PackageDescription

// A small, self-contained package exposing OpenSSH's bcrypt_pbkdf KDF (used to
// decrypt passphrase-protected OpenSSH private keys). The crypto is the verbatim
// OpenBSD/OpenSSH reference C, plus an in-tree SHA-512 (sha512.c). Nothing here
// links a platform crypto library, so the package builds and links identically
// on macOS, Linux (glibc or musl), and Windows.
let package = Package(
    name: "swift-bcrypt-pbkdf",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BcryptPBKDF", targets: ["BcryptPBKDF"]),
    ],
    targets: [
        .target(
            name: "CBcryptPBKDF",
            // The .c files include their private headers (blf.h, crypto_api.h,
            // includes.h) via <> and "", which live in the target root.
            cSettings: [.headerSearchPath(".")]
        ),
        .target(name: "BcryptPBKDF", dependencies: ["CBcryptPBKDF"]),
        .testTarget(name: "BcryptPBKDFTests", dependencies: ["BcryptPBKDF"]),
    ]
)
