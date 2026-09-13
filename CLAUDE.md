# SSH Config Manager — agent guide

A sandboxed SwiftUI macOS app and a GTK4 Linux app for viewing and editing
`~/.ssh/config`, managing keys/known_hosts, and running SSH **tunnels
in-process**. Both build on `Packages/SSHConfigKit`. Keep this file accurate when
behaviour changes.

## Layout

```
sshconfigmanager/          macOS app source (Views/, State/, Services/, …)
sshconfigmanager.xcodeproj Xcode project (file-system-synchronized groups)
sshconfigmanagerTests/     macOS unit tests (Swift Testing)
sshconfigmanagerUITests/   macOS UI tests (XCUITest)
Packages/
  SSHConfigKit/            Platform-neutral core — builds on macOS AND Linux
  SSHConfigMacUI/          SwiftUI features, stores, SwiftData persistence + tests
  SSHManagerUI/            Linux GTK4 / libadwaita app + its .deb/.rpm/flatpak definitions
Vendor/
  swift-nio-ssh/           Vendored + patched (external-signer, RSA CustomKeys)
  swift-bcrypt-pbkdf/      Vendored (bcrypt_pbkdf KDF for OpenSSH key decryption)
fastlane/                  App Store / TestFlight automation
store-assets/              Raw captures + frames.json — see store-assets/README.md
Tools/StoreFrames/         Screenshot frame renderer (CoreGraphics, no deps)
scripts/                   Build, release, install and changelog scripts
docs/                      Contributor documentation, intent.md, spec.md, releasing.md
website/                   Static SvelteKit site for www.sshmanager.app (GitHub Pages)
Gemfile / Gemfile.lock     Ruby gems for fastlane
icon-master.svg / *-light  Source icons
```

**Xcode project uses file-system-synchronized groups** — new files under
`sshconfigmanager/` and `sshconfigmanagerTests/` are picked up automatically.
Do **not** edit `project.pbxproj` to add source files; only edit it for build
settings or SPM package references.

## Lint & format

`swift-format` (the one inside the Xcode toolchain — nothing to install) is the
linter and the formatter. Config: `.swift-format`. It runs in CI as its own
fast job in `ci.yml`, ahead of the build.

```sh
./scripts/lint.sh          # lint; non-zero exit on any finding (what CI runs)
./scripts/lint.sh --fix    # rewrite in place, then lint what's left
```

The script hands swift-format an explicit list of first-party source trees.
**Do not change it to a bare `.`** — `Vendor/` holds ~3400 Swift files from
forked upstream packages (swift-nio-ssh, swift-bcrypt-pbkdf), and reformatting
those would wreck every future rebase against upstream.

Where the formatter is wrong, silence it at the site with
`// swift-format-ignore: <RuleName>` and say why. There is exactly one today:
`ConfigFileWatcher.drain()` must spell `Array<kevent>` the long way, because
`kevent` is both a C type and a C function and `[kevent]` parses as a
one-element array literal of the function value.

## Build & test

`make` fronts every task below; `make help` lists them. The raw commands:

```sh
# Fast type-check build (no signing required — safe for CI or quick checks)
xcodebuild -project sshconfigmanager.xcodeproj -scheme sshconfigmanager \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS'

# Signed build (required for entitlements: keychain-access-groups, sandbox, etc.)
# -allowProvisioningUpdates auto-generates provisioning profiles from Apple.
# Needs Config/Local.xcconfig (gitignored) to supply DEVELOPMENT_TEAM and
# BUNDLE_ID_PREFIX — the project itself hardcodes neither. See README.md.
xcodebuild -project sshconfigmanager.xcodeproj -scheme sshconfigmanager \
  -configuration Debug build -destination 'platform=macOS' -allowProvisioningUpdates

# Run a specific unit test suite (unsigned)
xcodebuild test -project sshconfigmanager.xcodeproj -scheme sshconfigmanager \
  -destination 'platform=macOS' -only-testing:sshconfigmanagerTests/TunnelStoreTests \
  CODE_SIGNING_ALLOWED=NO

# Run the SSHConfigMacUI package tests directly
cd Packages/SSHConfigMacUI && swift test --no-parallel
```

Deployment target: **macOS 15.0**. Built with **Xcode 26.5+**.

### Linux

`Packages/SSHConfigKit` and `Vendor/swift-bcrypt-pbkdf` must keep building on Linux —
they are the whole Linux port. Check that from a Mac with the Swift container:

```sh
./scripts/linux-build.sh              # build both packages
./scripts/linux-build.sh --test       # build, then run their test suites
./scripts/linux-build.sh --test kit   # one package (kit|bcrypt)
```

Needs a running Docker (or OrbStack). CI runs the same two suites natively in the
`linux-core` job, so an Apple-only API added to those packages fails the build
even though every other CI job is macOS.

**What breaks the Linux build**, in the order it has actually bitten:

1. `import CryptoKit` — use `Crypto` (swift-crypto) instead. It is the same API.
2. `import AppKit`, `import os`, `Security`, `IOKit`, `Network` —
   none exist. Take a protocol seam and put the macOS half in `SSHConfigMacUI`.
3. A dependency that is itself Apple-only. SwiftKyber is the live example: its
   BigInt draws randomness from Security.framework, so it is attached to the
   target with `condition: .when(platforms:)` and its file sits behind
   `#if canImport(SwiftKyber)`.

Anything AppKit-facing belongs in `SSHConfigMacUI`, which is macOS-only by design.

The Linux app is `Packages/SSHManagerUI`, the GNOME-native GTK4 / libadwaita
front end, with its `.deb`, `.rpm` and Flatpak definitions. Every screen the
macOS build has is present in it. What is not wired up yet says so on screen
rather than pretending: the tunnel engine, reachability testing, host key
verification, opening a terminal, and desktop notifications.

```sh
cd Packages/SSHManagerUI && make run           # build and start the GTK app
cd Packages/SSHManagerUI && make test
cd Packages/SSHManagerUI && make release-build # container build for distribution
cd Packages/SSHManagerUI && make package       # .deb + .rpm from that build
```

The GUI needs `libgtk-4-dev` and `libadwaita-1-dev`. `make check-deps` reports
what is missing before the compiler does.

## Constraints that are not negotiable

- **Verify on Linux, not on macOS.** `swift build` passing on a Mac proves
  nothing about this project. `scripts/linux-build.sh` builds the shared
  packages in the official Swift container. Run it before any change to a
  `Package.swift` is called done.
- **Adwaita comes from Codeberg, not GitHub.** `github.com/AparokshaUI/Adwaita`
  is a mirror that stopped in October 2024, and its newest tag predates the fix
  for the GLib 2.74 enum prefix change, so it does not compile against a current
  GLib. The live repository is `codeberg.org/aparoksha/adwaita-swift`, pinned by
  revision because its tags stop at 0.1.0.
- **The GUI is a second package on purpose.** It links system libadwaita through
  pkg-config. `SSHConfigKit` must keep building in the bare `swift:6.2-noble`
  container, which has no GTK, so the two cannot share one `Package.swift`.
- **libadwaita 1.6 is the floor, not glibc.** Adwaita for Swift calls
  `adw_bottom_sheet_*`, which arrived in libadwaita 1.6 (GNOME 47). A distribution
  older than that cannot run the binary whatever its glibc version is. So the
  container build targets the oldest base that still carries 1.6, and everything
  older is served by the Flatpak, which brings its own GNOME runtime. Do not
  "fix" the glibc floor by lowering the base image below libadwaita 1.6.
- **Escape what libadwaita parses.** Several widgets read their text as Pango
  markup, and the app feeds them names out of the user's files. One ampersand in
  a host name empties the label. The table below is measured against libadwaita
  1.9.1, not guessed — the probe is `swift test` in `MarkupTests.swift`.

  | Text reaches | Markup | Mnemonic (`_`) | What to do |
  |---|---|---|---|
  | `PreferencesGroup` title, `.description` | yes | no | `.markupEscaped`, no opt-out exists |
  | `StatusPage` description | yes | no | `.markupEscaped`, no opt-out exists |
  | `ActionRow`, `EntryRow`, `SwitchRow`, `ComboRow`, `SpinRow`, `ExpanderRow` title and subtitle | yes | no | `.useMarkup(false)` |
  | toast (`.toast`) | yes | no | escaped once in `RootView.show` |
  | `.tooltip` | yes | no | `.markupEscaped` — the binding calls `set_tooltip_markup` |
  | `Menu`, `MenuButton`, `Submenu` label | no | **yes** | `.mnemonicEscaped` |
  | `StatusPage` title, `WindowTitle`, `Banner`, `AlertDialog` heading and body, `Button`, `DropDown` item, `Text` | no | no | nothing |

- **One alert dialog per view.** `AlertDialog` and `AboutDialog` return the
  child's storage rather than their own, and key the presented dialog by a fixed
  name. Two `alertDialog` modifiers on one view therefore share a slot, and the
  second closes the first the moment it appears. Drive several confirmations
  from one modifier and a `Prompt` enum, the way `RootView` does. For the same
  reason every `dialog` in a view that also carries `aboutDialog` needs an
  explicit `id:` — `AboutDialog` uses the same key a plain dialog does.

- **`navigationTitle` goes on the value, not inside the view.** A type with
  `@State` gets a fresh storage, and `topToolbar` and every dialog modifier wrap
  the view in a new one. A title set inside a view's body never reaches the
  `NavigationSplitView` that reads it, and the page then warns at runtime. Put
  it at the point of use (`RootView.detail`), and make a branching sub-view
  return one view instead of a `Body`.

- **Do not give `@State` an identifier.** `@State("some-id")` binds the property
  to a slot shared across the application, and the view opens on whatever wrote
  that slot last instead of on its own default.

- **A text field must not write on every keystroke.** `AdwEntryRow` reports each
  one. Writing there rewrites `ssh_config` and adds a version to the history per
  character, so every text field holds a draft and commits on apply
  (`.onSubmit`). Switches and lists are discrete and write at once.
- **Never key UI state on `HostBlock.ID`.** Every parse mints fresh UUIDs and the
  app re-parses after each save, so a UUID key loses the selection on every edit.
  Use `HostBlock.sidebarKey`, the primary alias.
- **App-only data never enters ssh_config.** Favorites, tags and groups live in
  `~/.config/sshmanager/hosts.json`. The parser is lossless, and a stray key in
  the file ssh reads is a bug.
- **`SSHConfigEngine` is not linked.** It pulls in the vendored `swift-nio-ssh`,
  whose five patches have only ever run on macOS (`Vendor/PATCH.md`). Verify them
  in the container before adding tunnel subcommands.
- **`-static-stdlib` stays.** No distro ships a Swift runtime package, so the
  binary carries its own standard library. `nfpm.yaml` declares only the four
  system libraries `ldd` actually reports. Drop the flag and the dependency list
  becomes a lie, and the package installs and then fails to run.
- **Version lives in `MARKETING_VERSION`.** The Xcode project holds the product
  version for every platform. `BuildInfo.swift` and `AppVersion.swift` follow it,
  and `make version-check` reads it out of the project file to enforce the match.
  Bump one place.
- **`getpwuid`, never `NSHomeDirectory`.** `$HOME` lies under `sudo` and inside a
  service manager, and this tool's entire subject is a path under the real home
  directory. Same rule the macOS app follows.

## Scripts

All build and release scripts live in `scripts/`:

| Script               | Purpose                                             |
|----------------------|-----------------------------------------------------|
| `release.sh`         | Bump version + build + upload to TestFlight/App Store|
| `install-local.sh`   | Build + install to `~/Applications` (dev-signed)    |
| `lint.sh`            | swift-format lint (`--fix` rewrites)                |
| `linux-build.sh`     | Build and test the shared packages in a Swift container |
| `changelog.py`       | Validate `CHANGELOG.md`, print release notes        |
| `leak-check.sh`      | Scan tree, history and media for denylisted strings |
| `screenshots.sh`     | Capture RAW app windows into `store-assets/raw/en-US/` |
| `store-frames.sh`    | Compose captioned App Store frames from those captures |

```sh
./scripts/release.sh testflight           # bump build + upload to TestFlight
./scripts/release.sh release              # advance patch + App Store
./scripts/release.sh release --dry-run    # preview version bump only
./scripts/install-local.sh               # install to ~/Applications
./scripts/screenshots.sh                  # capture raw windows (GUI + signed build)
./scripts/store-frames.sh --open          # build the App Store frames
```

App Store screenshots are **generated**, never edited by hand. The copy, layout and
crop of every frame live in `store-assets/frames.json`; `store-frames.sh` renders
them into `fastlane/screenshots/en-US/` and deletes anything there the spec did not
produce. To change a caption, edit that file and re-run. Details in
[`store-assets/README.md`](store-assets/README.md).

Scripts resolve their own location and compute `ROOT_DIR` as the repository root.
They do **not** need to be run from any specific working directory.

Credentials for App Store Connect are sourced from `.release` (gitignored)
or from the env vars `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_API_KEY` that fastlane reads.
Team ID, app identifier and the match repository come from `APPLE_TEAM_ID`,
`APP_IDENTIFIER` and `MATCH_GIT_URL`. Every secret is listed in
[`docs/releasing.md`](docs/releasing.md). No account identifier is a literal in a
tracked file: the Gist client ID and export compliance code are xcconfig
variables, and `Config/Local.xcconfig` (gitignored) holds the real values.

## CI

GitHub Actions minutes on macOS runners cost ten times Linux minutes, so:

- `ci.yml` starts with a `changes` job and runs each job only when its paths change.
  Lint, the leak scan, changelog/version checks, the shared core and the GTK app
  all run on Ubuntu. The single `macos` job runs only on a pull request that
  carries the `macos-tests` label, or on a manual run. Push to `main` never
  starts it. Run `make test` locally before you add the label.
- UI tests never run in CI.
- `release.yml` runs on a `v*` tag: one App Store build (TestFlight + App Store
  submission), a notarized `.dmg`, `.deb`/`.rpm` for amd64 and arm64, and a Flatpak.
- `website.yml` builds and deploys `website/` to GitHub Pages. Browser tests run
  only on manual dispatch.

## Website

`website/` is the public site. It is static (`adapter-static`), has no server code,
analytics or forms, and ships in four locales (en, de, nl, el). See
[`website/CLAUDE.md`](website/CLAUDE.md). The licence is Apache 2.0 everywhere,
and the only contact points are the project email and GitHub issues.

```sh
cd website && pnpm install && pnpm dev
cd website && pnpm lint && pnpm check && pnpm test:unit && pnpm build
```

## Changelog

`CHANGELOG.md` in this directory is the **product** changelog. It is the source
for the App Store "What's New" text, so every
user-visible change gets a bullet under `## [Unreleased]` in the same commit as
the change. Write the effect for a customer — no symbol names, no file paths.
Validate with `make changelog-check` from the repository root.

`fastlane/metadata/en-US/release_notes.txt` is **generated from that file** —
`fastlane release` rewrites it before it builds, and `fastlane beta` sends the
same text as the TestFlight "What to Test". Never edit it by hand; edit
`CHANGELOG.md` and let the lane regenerate it (`fastlane mac release_notes`
does only that).

## Signing & releasing

**Never commit:**
- `.p8` App Store Connect API key files
- Certificate `.cer` or `.p12` files
- Provisioning profiles (`.mobileprovision`)
- `.release` (gitignored ASC credentials)
- Any private key or secret

Fastlane `match` manages certificates/profiles — they live in the private certs
repo, encrypted. The passphrase is in `MATCH_PASSWORD` (CI secret).

## Architecture

- **Sandboxed** (`com.apple.security.app-sandbox`). `~/.ssh` access via
  user-granted security-scoped bookmark (`SSHFileAccess`).
- **State stores** (`State/`): `ConfigStore`, `ConfigHistoryStore`, `TunnelStore`,
  `AppSettings` — all `@MainActor @Observable`, injected via `.environment(…)`.
- **Tunnels** run **in-process** over the vendored `swift-nio-ssh` (no Terminal,
  no `ssh` subprocess). Supports `-L`/`-R`/`-D`, ProxyJump multi-hop, ssh-agent,
  known_hosts TOFU, live throughput. RSA auth added via `NIOSSHRSA` target.
- **Persistence**: SwiftData store at `Application Support/<bundleid>/SSHConfigManager.store`.
  `AppDatabase` is an actor that conforms to `ModelActor` and owns the only
  `ModelContext`. Stores call its async methods and never see a model object.
  Models live in `Persistence/SchemaV1.swift`. `Persistence/ModelMapping.swift`
  converts them to and from the `SSHConfigKit` value types, which stay
  platform-neutral.
- **Settings** are key/value rows (`SettingModel`) via `AppSettings`. A new setting
  needs no schema change.
- **Legacy import**: on first use, `AppDatabase` copies a 1.x
  `sshconfigmanager.sqlite3` (read with the system `SQLite3` module) and the old
  `UserDefaults` favorites and tags into the store, then renames the old files
  with `.imported`.

## Conventions

- Keep existing doc comments. Add no new comments — hooks reject them. Delete a
  comment that describes removed behaviour instead of rewording it.
- Keep the ssh_config parser **lossless** — app-only data never goes into ssh_config.
- New persisted data → a new `VersionedSchema` (`SchemaV2`) plus a stage in
  `PersistenceMigrationPlan`. Never edit a shipped schema in place.
- Verify changes with **signed** builds (unsigned reads a different empty store).

## Skills — which to load

Load a skill only when the task touches that area:

- **Writing/reviewing SwiftUI views, `@Observable` flows** → `swiftui-patterns`, `swiftui-expert-skill`, `swiftui-pro`
- **Async/actors/`@MainActor`/`Sendable`/Swift 6** → `swift-concurrency`
- **Animations, SF Symbol effects** → `swiftui-animation`
- **Slow rendering, Instruments work** → `swiftui-performance`
- **Menu bar, toolbars, HIG questions** → `macos-design-guidelines`
- **AppKit bridging, Tahoe APIs, code review** → `macos-development`
- **Liquid Glass (macOS 26)** → `swiftui-liquid-glass` *(gate on macOS 26 — min target is 15)*
- **New UI aesthetics, typography** → `frontend-design`
- **Figma ↔ SwiftUI** → `figma:figma-swiftui`, `figma:figma-use`

`AGENTS.md` is a symlink to this file.
