# Intent

SSH Config Manager is my first open-source product. It must look like a finished product on the first public day. That means a clean repository, a working website, an App Store build and Linux packages.

## Outcomes

1. **Complete port.** Every feature of the macOS app and the Linux app from the private repository is present here. The only removed code is the paid tier, licensing and telemetry.
2. **No paid tier.** Every feature is available to every user. The code has no purchase, trial, licence, account or entitlement logic.
3. **No leaks.** The public repository holds no private data in files, in history or in binary assets. Private data includes team identifiers, backend addresses, personal contact details, employer host names and third-party identities.
4. **Website on day one.** The site at `www.sshmanager.app` ships with the first release. It lives in this repository and deploys from it.
5. **Clean code.** The code reads like careful human work. Files are small and have one job. Names explain intent.
6. **Current Swift patterns.** The app uses Swift 6 language mode, `@Observable` stores, structured concurrency and value types at the core.
7. **Better SwiftUI.** Views are small, previewable and driven by typed navigation state. Empty and error states use system components.
8. **SwiftData.** The macOS app stores its data with SwiftData. Existing users keep their tunnels, history, groups and host-key log after the update.
9. **Automated App Store release.** A version tag builds the app once, uploads it to TestFlight and submits it to the App Store.
10. **Low CI cost.** Work that does not need Xcode runs on Linux runners. A macOS runner starts only when macOS code changes.

## Non-goals

- A backend, a storefront or an operator dashboard.
- Accounts, telemetry, crash reporting or analytics, in the app or on the website.
- A command-line tool on Linux. The Linux product is the GTK app.
- SwiftData on Linux. The shared core stays platform-neutral.

## Success criteria

- A single initial commit. A leak scan of that commit finds zero matches.
- `make check` and `./scripts/linux-build.sh --test` pass.
- A 1.2.0 user who updates sees the same tunnels, versions, groups, favorites and tags.
- The website builds, deploys and shows correct licence, privacy and download text in four languages.
- A documentation-only pull request uses about one Linux runner minute.
- A `v*` tag produces a TestFlight build, an App Store submission, and `.deb` and `.rpm` files on the GitHub release.
