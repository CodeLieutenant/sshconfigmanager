# Building SSH Config Manager

`make help` lists every target. This page explains the ones that need more than
a command.

## What you need

| Target | Requirement |
|--------|-------------|
| macOS app | macOS 15 or newer, Xcode 26.5 or newer |
| Shared core only | a Swift 6.2 toolchain |
| Linux app | Swift 6.2, `libgtk-4-dev`, `libadwaita-1-dev`, `pkg-config` |
| Linux packages | Docker, and `nfpm` for the `.deb` and `.rpm` |

Clone with no extra steps. The vendored packages under `Vendor/` are checked in,
and Swift Package Manager resolves the rest on the first build.

## Build and run on macOS

```sh
make build      # unsigned, type-check only
make test       # the app target and the SSHConfigMacUI package
make install    # build and copy the app into ~/Applications
```

`make build` passes `CODE_SIGNING_ALLOWED=NO`, so it needs no Apple Developer
account. The product it makes does not run, because macOS refuses to launch an
unsigned application. Use it to check that your change compiles.

To get an app you can start, sign it with your own account:

1. Copy the example settings file.

   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

2. Open `Config/Local.xcconfig`. Set `DEVELOPMENT_TEAM` to your 10-character
   Team ID, from Xcode ▸ Settings ▸ Accounts.
3. Set `BUNDLE_ID_PREFIX` to your own reverse-DNS prefix. Bundle IDs are unique
   across all Apple accounts, so use a prefix that you own.
4. Build.

   ```sh
   make build-signed
   ```

`Config/Local.xcconfig` is not tracked by git. The project reads it last, so
your values win over the defaults in `Config/Shared.xcconfig`.

## The sandbox, and how to build without it

The App Store build runs in the macOS App Sandbox. The sandbox denies a
subprocess, and three features need one:

- **`ProxyCommand`.** A host whose `ProxyCommand` is an arbitrary program —
  `cloudflared access ssh`, `aws ssm start-session`, `boundary connect` — cannot
  connect. The tunnel engine runs the three common forms in-process (`ssh -W`
  jump hosts, a SOCKS5 proxy, and an HTTP CONNECT proxy), so those still work.
  Everything else needs a real subprocess.
- **Connect & Launch into Ghostty, kitty or WezTerm.** These terminals take a
  command on their command line and expose no AppleScript dictionary, so the
  sandboxed build copies the command to your clipboard instead of starting them.
- **A future feature that has to run a helper binary.**

`UNSANDBOXED` is the compile-time condition that turns all three on. It sets
`NIOTunnelEngine.subprocessCapable`, which is what
`ProxyConnectStrategyFactory` reads before it accepts a raw `ProxyCommand`.

Build that variant with:

```sh
make build-direct
```

The target changes four settings at once, and all four are needed:

| Setting | Value | Why |
|---------|-------|-----|
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `$(inherited) UNSANDBOXED` | compiles the subprocess paths in |
| `CODE_SIGN_ENTITLEMENTS` | `sshconfigmanager/sshconfigmanager-direct.entitlements` | drops the sandbox entitlement |
| `ENABLE_APP_SANDBOX` | `NO` | stops Xcode adding the entitlement back |
| `ENABLE_USER_SELECTED_FILES` | `none` | the file-access entitlements mean nothing outside a sandbox |

Setting the compile condition alone produces an app that looks correct and
starts correctly, and then falls back to the sandboxed behaviour at runtime,
with no error. Change all four, or none.

An unsandboxed build cannot go to the Mac App Store. It is the build shipped as
the notarized `.dmg`. `make dmg` produces that one, and its lane fails if the
signed product still carries `com.apple.security.app-sandbox`.

## Build on Linux

```sh
make gui        # build the GTK app
make test-gui   # run its tests
```

`make gui` needs GTK 4.16 and libadwaita 1.6 on the machine. The `check-deps`
step reports the versions it finds and stops if either is missing.

A Mac cannot build the GTK app, but it can prove the shared core still compiles
on Linux:

```sh
make linux-check
```

This runs `scripts/linux-build.sh` in the `swift:6.2-noble` container. The
container carries no GTK, which is why `Packages/SSHConfigKit` must never import
one.

## Linux packages

```sh
cd Packages/SSHManagerUI
make release-build     # build in a container, so the floor is a decision
make package-all       # .deb and .rpm for amd64 and arm64
make flatpak           # build and install the Flatpak locally
```

`make release-build` uses `ubuntu:24.10`, the oldest image that carries
libadwaita 1.6. Adwaita for Swift calls `adw_bottom_sheet_*`, which arrived in
that version, so a system below GNOME 47 cannot run the binary whatever its
glibc is. Those users get the Flatpak, which carries its own runtime.

## Before you push

```sh
make check
```

This runs the formatter in check mode, validates `CHANGELOG.md`, compares the
Linux app version against `MARKETING_VERSION`, and runs every macOS test.
