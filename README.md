# SSH Config Manager

A native app for editing your `~/.ssh/config` losslessly — a structured editor for
hosts and directives, SSH key management, a known-hosts manager, connection
testing, linting, and a menu bar extra. SwiftUI and fully sandboxed on macOS,
GTK4 and libadwaita on Linux, both built on the same core.

Every feature is free. The app has no backend, no account, no telemetry and no
purchases. The only network traffic is the SSH connections you start and the
optional GitHub Gist sync.

## Features

- **Lossless config editing** — comments, blank lines, and formatting in `~/.ssh/config` are preserved; the app only rewrites what you change.
- **Structured host editor** — edit `Host` blocks and directives with a keyword catalog, autocomplete, and per-block raw editing.
- **SSH keys** — browse and manage identity keys in `~/.ssh`.
- **Known hosts** — view/manage `known_hosts` with a backup history.
- **Power tools** — effective config resolver, config linter, connection tester, tags, command palette, and host templates.
- **In-process tunnels** — `-L`/`-R`/`-D`, ProxyJump multi-hop, ssh-agent auth.
- **Menu bar extra** — quick access without opening the main window.

## Requirements

| Tool | Version |
|------|---------|
| macOS | 15 (Sequoia) or later — to run |
| Xcode | 26.5 or later — to build |

## Building

```sh
make help     # every task in this repository
make build    # unsigned type-check build of the Mac app
make test     # every macOS test suite
make lint     # format check; make format rewrites in place
make check    # what CI gates on
make gui      # the GTK app on Linux
```

Or open `sshconfigmanager.xcodeproj`, select the **`sshconfigmanager`** scheme
and **My Mac**, and press ⌘R.

A fresh clone builds unsigned with no Apple Developer account, and an unsigned
build cannot start. [docs/building.md](docs/building.md) covers signing it with
your own account, building the Linux app and its packages, and the unsandboxed
build that runs an arbitrary `ProxyCommand`.

## Project layout

```
sshconfigmanager.xcodeproj      Xcode project (file-system-synchronized groups)
sshconfigmanager/               macOS app source
sshconfigmanagerTests/          macOS unit tests (Swift Testing)
sshconfigmanagerUITests/        macOS UI tests (XCUITest)
Packages/
  SSHConfigKit/                 Core SSH config library — macOS and Linux
  SSHConfigMacUI/               SwiftUI components (own test target)
  SSHManagerUI/                 Linux GTK4 / libadwaita app, and its deb/rpm/flatpak specs
Vendor/
  swift-nio-ssh/                Vendored + patched
  swift-bcrypt-pbkdf/           Vendored
fastlane/                       App Store automation
scripts/                        Build, release, and install scripts
docs/                           Contributor documentation
```

## Linux

The GTK app shares `Packages/SSHConfigKit` with the Mac app.

```bash
make gui        # build it (needs libgtk-4-dev and libadwaita-1-dev)
make test-gui   # run its tests
make linux-check   # from a Mac: build the shared core in the Swift container
```

## Changelog

[`CHANGELOG.md`](CHANGELOG.md) records every user-visible change on both
platforms. [docs/changelog.md](docs/changelog.md) explains what needs an entry
and how a version is cut.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers the build, the changelog rule and how
to report a bug.

## License

Released under the [Apache License 2.0](LICENSE.md). The third-party components
this app links, and their licences, are listed in [NOTICE.md](NOTICE.md).
