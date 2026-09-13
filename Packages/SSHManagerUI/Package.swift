// swift-tools-version: 6.0
import PackageDescription

// sshmanager — the GNOME-native GTK4/libadwaita front end. Kept as its own
// package, separate from SSHConfigKit, because this one depends on system
// libadwaita-1 (which pulls in gtk4) via pkg-config. SSHConfigKit builds in the
// bare swift:6.2-noble container with no GTK anywhere, and scripts/linux-build.sh
// relies on that.
//
// The screens live in SSHManagerUI, a library, and the executable holds only the
// @main entry point. A test target cannot link an executable target reliably on
// Linux, and the macOS side already splits the same way (SSHConfigMacUI).
//
// App id, runtime and command name match packaging/flatpak/app.sshmanager.SSHConfigManager.yml.
//
let package = Package(
    name: "sshmanager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sshmanager", targets: ["sshmanager"]),
        .library(name: "SSHManagerUI", targets: ["SSHManagerUI"]),
    ],
    dependencies: [
        .package(path: "../SSHConfigKit"),
        // Codeberg, not the github.com/AparokshaUI mirror: that mirror stopped at
        // October 2024 and its newest tag (0.2.6, May 2024) predates the fix for
        // GLib 2.74's enum prefix change, so it does not compile against the GLib
        // that Ubuntu 26.04 ships. Pinned by revision because upstream tags stop
        // at 0.1.0 — same rule the other vendored dependencies follow.
        .package(
            url: "https://codeberg.org/aparoksha/adwaita-swift.git",
            revision: "354eba3c836531ea8092201f6c4b298dd200e4b0"
        ),
    ],
    targets: [
        .target(
            name: "SSHManagerUI",
            dependencies: [
                .product(name: "SSHConfigCore", package: "SSHConfigKit"),
                .product(name: "SSHConfigServices", package: "SSHConfigKit"),
                .product(name: "Adwaita", package: "adwaita-swift"),
            ]
        ),
        .executableTarget(name: "sshmanager", dependencies: ["SSHManagerUI"]),
        .testTarget(name: "SSHManagerUITests", dependencies: ["SSHManagerUI"]),
    ],
    swiftLanguageModes: [.v5]
)
