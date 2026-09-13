# Contributing

Thank you for looking. This page tells you how to get a build running, what the
project expects from a change, and where the rules live.

By contributing you agree that your work is licensed under the
[Apache License 2.0](LICENSE.md), the licence of this project.

## Start here

```sh
git clone https://github.com/CodeLieutenant/sshconfigmanager.git
cd sshmanager
make help      # every task this repository has
make build     # unsigned build of the Mac app
make test      # the macOS test suites
```

Nothing else to install and nothing to configure. The vendored packages under
`Vendor/` are checked in, and Swift Package Manager resolves the rest.

Read [docs/building.md](docs/building.md) for the full picture: signing the app
with your own Apple account, building the Linux app, and the unsandboxed build
that runs `ProxyCommand`.

## What the code is

| Path | What it holds |
|------|---------------|
| `sshconfigmanager/` | the macOS app target — a thin `@main` shell |
| `Packages/SSHConfigMacUI/` | the SwiftUI screens, stores and macOS services |
| `Packages/SSHConfigKit/` | the shared core: parsing, crypto, services, tunnel engine |
| `Packages/SSHManagerUI/` | the GTK4 and libadwaita app for Linux |
| `Vendor/` | patched copies of swift-nio-ssh and a bcrypt KDF |

`Packages/SSHConfigKit` is the port. Every target in it builds on Linux and must
keep doing so, which means no AppKit, no CryptoKit, no `os.Logger`, and no
Security, IOKit or Network framework. Where the core needs the host program — a
passphrase prompt, an ssh-agent — it declares a protocol and each front end
supplies it. `make linux-check` proves this from a Mac.

[CLAUDE.md](CLAUDE.md) holds the deeper architecture notes.

## Before you open a pull request

```sh
make check
```

That runs the formatter, validates the changelog, compares the Linux app version
against `MARKETING_VERSION`, and runs every macOS test. CI runs the lint, the
checks, the shared core and the Linux app on every pull request. The macOS tests
run in CI only when a maintainer adds the `macos-tests` label, so run
`make check` before you open the pull request.

`make format` reformats the sources in place. `Vendor/` is excluded on purpose,
so a rebase onto upstream stays possible.

## Changelog

Every change a user notices gets a changelog entry **in the same commit as the
change**. `CHANGELOG.md` ships to the App Store, so a late
entry is a missed release.

- Add the entry under `## [Unreleased]`, in one of the six fixed sections:
  Added, Changed, Deprecated, Removed, Fixed, Security. Never invent a seventh.
- Write the effect on the user, not the patch. No symbol names, no file paths,
  no pull-request numbers. One change per bullet.
- Prefix a bullet that applies to one platform only: `- **Linux.** …`
- **No entry** for a refactor, a test, a lint fix, a formatting pass, a silent
  dependency bump, CI, tooling or documentation.

[docs/changelog.md](docs/changelog.md) has the release-time steps.

## Commits and pull requests

Write the commit subject as one imperative line — "Add a Makefile covering both
platforms", not "added makefile". Say in the body what forced the change. The
diff already shows what the change does.

In the pull request, describe the problem and how a reviewer can see it. If the
change alters what the app shows, attach a screenshot.

## Reporting a bug

Open an [issue](https://github.com/CodeLieutenant/sshconfigmanager/issues/new). Tell
us your macOS or distribution version, the application version from the About
screen, and the steps that reproduce the problem.

**Never paste a private key, a passphrase, or a real host name you care about.**
An `~/.ssh/config` fragment is often the fastest way to reproduce a parsing bug —
replace the host names and the identity file paths before you attach it.

## Reporting a security problem

Do not open a public issue. Email `sshconfigmanager@dusanmalusev.dev` with the
steps to reproduce, and give us time to ship a fix before you publish.

## Third-party code

`Vendor/` holds patched copies of other people's work, and the build resolves
more packages from the network. [NOTICE.md](NOTICE.md) lists all of them with
their licences. Add a row there when you add a dependency.

Keep the copyright header at the top of every file in
`Vendor/swift-bcrypt-pbkdf/Sources/CBcryptPBKDF/`. Those are OpenBSD sources and
their licences require it.
