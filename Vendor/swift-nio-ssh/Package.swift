// swift-tools-version:6.1
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let strictConcurrencyDevelopment = false

var swiftSettings: [SwiftSetting] = []

if strictConcurrencyDevelopment {
    // -warnings-as-errors here is a workaround so that IDE-based development can
    // get tripped up on -require-explicit-sendable.
    swiftSettings.append(.unsafeFlags(["-Xfrontend", "-require-explicit-sendable", "-warnings-as-errors"]))
}

let package = Package(
    name: "swift-nio-ssh",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"]),
        // NIOSSH patch (sshconfigmanager): RSA public-key auth on top of CustomKeys.
        .library(name: "NIOSSHRSA", targets: ["NIOSSHRSA"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                // AES-CTR and raw ChaCha20 live in _CryptoExtras, which re-exports Crypto.
                // Depending on Crypto directly *as well* trips the same Xcode/SwiftPM
                // dynamic-PackageProduct build-ordering bug documented on NIOSSHRSA below.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: swiftSettings
        ),
        // NIOSSH patch (sshconfigmanager): RSA public-key auth backed by swift-crypto's
        // _CryptoExtras (_RSA.Signing). No BigInt / BoringSSL. See Sources/NIOSSHRSA.
        .target(
            name: "NIOSSHRSA",
            dependencies: [
                "NIOSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                // _CryptoExtras (for _RSA.Signing) brings Crypto transitively. Depending on
                // Crypto directly *as well* trips an Xcode/SwiftPM dynamic-PackageProduct
                // build-ordering bug (missing Crypto_<hash>_PackageProduct.framework at link).
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOSSHClient",
            dependencies: [
                "NIOSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOSSHServer",
            dependencies: [
                "NIOSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOSSHPerformanceTester",
            dependencies: [
                "NIOSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOSSHTests",
            dependencies: [
                "NIOSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        // NIOSSH patch (sshconfigmanager): RSA custom-key tests. Run with
        // `swift test --filter NIOSSHRSATests`.
        .testTarget(
            name: "NIOSSHRSATests",
            dependencies: [
                "NIOSSH",
                "NIOSSHRSA",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
