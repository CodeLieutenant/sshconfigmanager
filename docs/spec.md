# Specification

This document turns [intent.md](intent.md) into requirements. Each section names the files it changes and the check that proves it.

## 1. Repository

| Path | Contents |
|---|---|
| `sshconfigmanager/` | macOS app target |
| `Packages/SSHConfigKit` | Platform-neutral core. Builds on macOS and Linux |
| `Packages/SSHConfigMacUI` | SwiftUI features, stores and SwiftData persistence |
| `Packages/SSHManagerUI` | GTK4 / libadwaita app and its packaging |
| `Vendor/` | Patched upstream packages. Never reformatted |
| `website/` | Static SvelteKit site for `www.sshmanager.app` |
| `fastlane/`, `scripts/` | Build, release and asset tooling |
| `.github/workflows/` | `ci.yml`, `release.yml`, `website.yml` |

The public history starts with one commit. The private repository keeps the old history.

## 2. Removed product surface

These things do not exist anywhere in the tree:

- Purchase, trial, licence, entitlement and registration code and views.
- Install identity, diagnostics upload and feedback upload.
- StoreKit configuration files and in-app purchase artwork.
- "Pro" badges and tags in store frames and screenshots.
- Imprint page and business registration data on the website.

`BuildEnvironment` keeps `AppTransaction`. It tells an App Store build from a TestFlight build.

## 3. Identity and configuration

No personal or account identifier is a literal in tracked files.

| Value | Source |
|---|---|
| `DEVELOPMENT_TEAM` | `Config/Local.xcconfig` (gitignored) or CI secret `APPLE_TEAM_ID` |
| `BUNDLE_ID_PREFIX` | `Config/Shared.xcconfig` default, override in `Local.xcconfig` |
| `GITHUB_GIST_CLIENT_ID` | `Local.xcconfig` or CI secret. `Info.plist` reads `$(GITHUB_GIST_CLIENT_ID)` |
| `EXPORT_COMPLIANCE_CODE` | `Local.xcconfig` or CI secret. `Info.plist` reads `$(EXPORT_COMPLIANCE_CODE)` |
| Keychain service, log subsystem, login item identifier | Derived from `Bundle.main.bundleIdentifier` |
| fastlane team, app identifier, match URL | `ENV["APPLE_TEAM_ID"]`, `ENV["APP_IDENTIFIER"]`, `ENV["MATCH_GIT_URL"]` |

Test fixtures use documentation addresses (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) and generic host names.

## 4. Persistence (macOS)

### 4.1 Stack

- SwiftData, deployment target macOS 15.0.
- One store file: `Application Support/<bundle id>/SSHConfigManager.store`.
- `AppDatabase` is an actor that conforms to `ModelActor`. It owns the only `ModelContext`, with autosave off. It saves once per operation.
- Stores call async methods on `AppDatabase` and get value types back. No model object leaves the actor.
- Tests use a store file in a temporary directory, or `AppDatabase.inMemory()`.
- `SchemaV1: VersionedSchema` lists every model. `PersistenceMigrationPlan: SchemaMigrationPlan` starts with `SchemaV1` only.
- The `sqlite-nio` dependency is removed.

### 4.2 Models

| Model | Fields | Constraints | Maps to |
|---|---|---|---|
| `SettingModel` | `key`, `value` | `#Unique([\.key])` | `AppSettings` values, history HEAD |
| `TunnelModel` | `tunnelID: UUID`, `position`, `name`, `hostAlias`, `mode`, `autostart`, `mappings` | `#Unique([\.tunnelID])`, cascade delete | `TunnelPreset` |
| `PortMappingModel` | `mappingID: UUID`, `position`, `bindAddress`, `listenPort`, `targetHost`, `targetPort`, `hasWebUI`, `tunnel` | none | `PortMapping` |
| `HostGroupModel` | `groupID: UUID`, `name`, `filePath`, `sortIndex` | `#Unique([\.groupID])` | `PersistedGroup` |
| `HostMetadataModel` | `alias`, `isFavorite`, `tags: [String]` | `#Unique([\.alias])` | favorites and tags |
| `HostKeyCheckModel` | `groupID`, `hostTitle`, `displayName`, `hostToken`, `keyType`, `fingerprint`, `serverOpenSSH`, `outcome`, `checkedAt` | `#Index([\.checkedAt], [\.groupID])` | `AppDatabase.HostKeyCheckRecord` |
| `ConfigBlobModel` | `blobHash`, `data` (external storage, zlib), `size` | `#Unique([\.blobHash])` | blob payload |
| `ConfigVersionModel` | `versionID`, `parentID`, `createdAt`, `name`, `source`, `addedLines`, `removedLines`, `filesChanged`, `files` | `#Unique([\.versionID])`, `#Index([\.createdAt], [\.parentID])`, files cascade | `ConfigVersion` |
| `ConfigVersionFileModel` | `relativePath`, `blobHash`, `version` | none | manifest entry |

Settings stay key/value rows. A typed row would need a schema version for every new preference.

`SSHConfigKit` value types do not change. `Persistence/ModelMapping.swift` holds every conversion.

### 4.3 Store rules

- Stores stay `@MainActor @Observable`. Their public API does not change.
- `HostKeyMonitor` keeps at most 5,000 `HostKeyCheckModel` rows. `AppDatabase` deletes the oldest rows after each write.
- Favorites and tags move from `UserDefaults` to `HostMetadataModel`. Grouping mode, collapsed groups and security-scoped bookmarks stay in `UserDefaults`.
- Passphrases and the Gist token stay in the Keychain.

### 4.4 Legacy import

`AppDatabase` runs the import once, before its first operation. It runs only for the shared store and only when the store is empty.

1. If `sshconfigmanager.sqlite3` exists, open it read-only with the system `SQLite3` module.
2. Copy `settings`, `tunnels`, `port_mappings`, `config_blobs`, `config_versions`, `config_version_files`, `host_groups` and `host_key_checks` into records.
3. Copy favorites and tags from `UserDefaults`, then remove those keys.
4. `TunnelStore` still imports a legacy `tunnels.json` when the store has no tunnels.
5. Save once. On success, rename the database and its WAL files with the suffix `.imported`.
6. On failure, roll back, log the error, keep the old files and continue with empty data.

`LegacyImportTests` builds a fixture database in a temporary directory and checks every table, the `UserDefaults` import and the skip rule.

## 5. Code structure

- No Swift file in `SSHConfigMacUI` is longer than 800 lines. Split by feature into `Type+Feature.swift` extensions or subview files.
- `ConfigStore` splits into core, editing, groups, favorites and tags, validation, file watching and includes.
- `KnownHostsView`, `TunnelStore` and `SettingsPanes` split the same way.
- Views read stores with `@Environment(Store.self)` and bind with `@Bindable`.
- Async view work uses `.task` or `.task(id:)`.
- Sidebar selection is a `Hashable` route enum.
- Every top-level screen has a `#Preview` backed by the in-memory container.
- Empty states use `ContentUnavailableView`.
- Packages use `swiftLanguageModes: [.v6]`. The app target uses `SWIFT_VERSION = 6.0`. `Vendor/` stays in Swift 5 mode.
- Existing doc comments stay. New code has no comments. Stale comments about removed features are deleted.
- `./scripts/lint.sh` reports zero findings.

## 6. Website

### 6.1 Stack

SvelteKit 2, Svelte 5 runes, Tailwind 4, `adapter-static`, Paraglide with `en`, `de`, `nl` and `el`. The site has no server code, analytics, forms or third-party requests.

### 6.2 Routes

| Route | Content |
|---|---|
| `/` | Hero, features, tunnels, security, downloads for macOS (App Store, GitHub) and Linux (`.deb`, `.rpm`, Flatpak), support options |
| `/roadmap` | Now, next, later and shipped columns |
| `/privacy` | The app collects no data. Gist sync sends data only to GitHub with the user's own token. The site has no analytics. GitHub Pages keeps access logs |
| `/terms` | Apache License 2.0, no warranty. App Store terms apply to the App Store build |
| `/robots.txt`, `/sitemap.xml` | Generated from `PUBLIC_ROUTES` |

### 6.3 Content rules

- The licence is Apache 2.0 everywhere. `LICENSE_URL` points to `LICENSE.md`.
- The only contact is the project email and GitHub issues.
- Screenshots come from the rendered store frames. No image shows an email, a real host or a "Pro" badge.
- The App Store price is one constant in `src/lib/links.ts`.
- `static/CNAME` matches `SITE.url`.

## 7. Continuous integration

### 7.1 `ci.yml`

Triggers: `pull_request` (opened, synchronize, reopened, labeled), `push` to `main`, `workflow_dispatch`. Concurrency groups per ref, with cancel-in-progress. A label event has its own group, so it does not cancel a code run. A `changes` job on Ubuntu decides which Linux jobs run.

| Job | Runner | Starts when these paths change | Steps |
|---|---|---|---|
| `lint` | `ubuntu-latest`, container `swift:6.2-noble` | `**/*.swift`, `.swift-format`, `scripts/lint.sh` | `scripts/lint.sh` |
| `leaks` | `ubuntu-latest` | always | gitleaks on the pushed commits |
| `checks` | `ubuntu-latest` | `CHANGELOG.md`, `*.xcodeproj/**`, `scripts/**` | `make changelog-check version-check` |
| `linux-core` | `ubuntu-latest`, container `swift:6.2-noble` | `Packages/SSHConfigKit/**`, `Vendor/swift-bcrypt-pbkdf/**` | `swift test` for both, `.build` cache |
| `linux-gui` | `ubuntu-latest` | `Packages/SSHManagerUI/**`, `Packages/SSHConfigKit/**` | build and test the GTK app |
| `macos` | `macos-26` | the pull request has the `macos-tests` label, or a manual run | one job: resolve, build for testing, unit tests, `SSHConfigMacUI` tests. Cache SPM and DerivedData |

- UI tests do not run in CI.
- No coverage upload.
- `macos` has `timeout-minutes: 30`. Linux jobs have `timeout-minutes: 15`.
- Checkout uses `fetch-depth: 1`, except `leaks`.

### 7.2 Minute budget

| Pull request touches | Expected cost |
|---|---|
| Documentation only | 1 to 2 Linux minutes |
| Linux code only | 5 to 8 Linux minutes |
| macOS code, with the `macos-tests` label | 12 to 18 macOS minutes with a warm cache |

### 7.3 `website.yml`

Triggers: `website/**` or the workflow file, on `pull_request` and `push` to `main`. Ubuntu, pnpm cache. Steps: lint, check, unit tests, build. Deploy to GitHub Pages on `main` only. Browser tests run only on `workflow_dispatch`.

## 8. Release

`release.yml` starts on a `v*` tag or on `workflow_dispatch`. Inputs: `testflight_only` (default false) and `developer_id` (default false). `macos-26` is the only hosted image with Xcode 26.5 or later.

1. `app-store` on `macos-26`: match in read-only mode, then `fastlane mac release`. The lane builds once, uploads with `pilot`, then runs `deliver` with metadata and screenshots. It submits for review unless `testflight_only` is true.
2. `developer-id` on `macos-26`: runs on every tag, and on a manual run when `developer_id` is true. Builds, notarizes and attaches the `.dmg`.
3. `linux-packages` on `ubuntu-latest`: container release build, then `nfpm` for `.deb` and `.rpm` on amd64 and arm64.
4. `flatpak` on `ubuntu-latest`: packs the amd64 binary into `sshconfigmanager.flatpak` with the GNOME 47 runtime.
5. `github-release` on `ubuntu-latest`: creates the release with notes from `scripts/changelog.py` and attaches the `.dmg`, Linux packages and Flatpak.

Secrets: `APPLE_TEAM_ID`, `APP_IDENTIFIER`, `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_GIT_SSH_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_API_KEY_BASE64`, `KEYCHAIN_PASSWORD`, `GITHUB_GIST_CLIENT_ID`, `EXPORT_COMPLIANCE_CODE`.

`docs/releasing.md` lists each secret and how to make it.

## 9. Leak gate

- `gitleaks` runs in CI on every push and pull request.
- `scripts/leak-check.sh` reads a denylist from the path in `SSHMANAGER_LEAK_DENYLIST`. The denylist is never committed.
- The script checks tracked files, all commits and text inside `.png`, `.mp4` and `.svg` metadata.
- Before the first public push, a person opens every image and video in `fastlane/screenshots`, `store-assets` and `website/static`.

## 10. Verification

| Area | Command |
|---|---|
| Lint | `make lint` |
| Shared core on Linux | `./scripts/linux-build.sh --test` |
| GTK app | `cd Packages/SSHManagerUI && make test` |
| macOS | `make test`, then `make build-signed` |
| Legacy import | Run the signed build on a copy of a 1.2.0 `Application Support` folder |
| Website | `cd website && pnpm lint && pnpm check && pnpm test && pnpm build` |
| Release | `workflow_dispatch` with `testflight_only: true` before the first tag |
| Leaks | `scripts/leak-check.sh` and `gitleaks detect` on the orphan commit |
