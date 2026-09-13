// swift-tools-version: 6.2
import PackageDescription

// SSHConfigMacUI — the macOS SwiftUI/AppKit UI layer (views, design components,
// observable stores, and the macOS-coupled services incl. the in-process NIO
// tunnel engine), extracted so the app target is a thin @main shell and the
// module graph is hardened ahead of a future Linux (Adwaita) port. The SwiftUI
// views are NOT reused on Linux — this is purely a clean boundary.
let package = Package(
    name: "SSHConfigMacUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SSHConfigMacUI", targets: ["SSHConfigMacUI"]),
    ],
    dependencies: [
        .package(path: "../SSHConfigKit"),
        .package(path: "../../Vendor/swift-nio-ssh"),
        .package(path: "../../Vendor/swift-bcrypt-pbkdf"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        // Poly1305 only, for chacha20-poly1305@openssh.com. swift-crypto exports the
        // ChaCha20 keystream (`Insecure.ChaCha20CTR`) but not Poly1305 on its own, and
        // OpenSSH's construction is not the RFC 8439 AEAD, so `ChaChaPoly` cannot be used.
        // Pure Swift, so it survives the planned Linux port and adds no binary artifact.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.9.0"),
        // ML-KEM-768 (FIPS 203) for macOS 14 and 15, where CryptoKit has none. Used only
        // below macOS 26; above it the system implementation wins. See
        // Services/PortableMLKEMBackend.swift.
        .package(url: "https://github.com/leif-ibsen/SwiftKyber.git", from: "3.5.0"),
    ],
    targets: [
        .target(
            name: "SSHConfigMacUI",
            dependencies: [
                .product(name: "SSHConfigCore", package: "SSHConfigKit"),
                .product(name: "SSHConfigCrypto", package: "SSHConfigKit"),
                .product(name: "SSHConfigIntelliSense", package: "SSHConfigKit"),
                .product(name: "SSHConfigServices", package: "SSHConfigKit"),
                .product(name: "SSHConfigEngine", package: "SSHConfigKit"),
                .product(name: "SSHConfigSync", package: "SSHConfigKit"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOSSHRSA", package: "swift-nio-ssh"),
                .product(name: "BcryptPBKDF", package: "swift-bcrypt-pbkdf"),
                // _CryptoExtras (AES-CTR, ChaCha20 keystream) re-exports Crypto. Depending
                // on Crypto directly *as well* trips the Xcode/SwiftPM build-ordering bug
                // documented in Vendor/swift-nio-ssh/Package.swift.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(name: "SwiftKyber", package: "SwiftKyber"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "SSHConfigMacUITests",
            dependencies: [
                "SSHConfigMacUI",
                .product(name: "SSHConfigCore", package: "SSHConfigKit"),
                .product(name: "SSHConfigSync", package: "SSHConfigKit"),
                .product(name: "SSHConfigCrypto", package: "SSHConfigKit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftKyber", package: "SwiftKyber"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
