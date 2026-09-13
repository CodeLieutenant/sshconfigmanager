# Changelog

One changelog, one release train. Every change that another person must know
about gets one entry in [`CHANGELOG.md`](../CHANGELOG.md), in the same commit as
the change.

It is the product changelog for both platforms, and the source for the App Store
"What's New" text. Write those bullets for a customer.

A bullet that applies to only one platform opens with that platform's name —
`- **Linux.** …`. The App Store notes drop every bullet marked for a platform the
App Store does not ship, so a Linux-only change never reaches a Mac reader.

## What needs an entry

Ask what the reader of that file must know.

Write an entry for:

- a new feature, or a change to how an existing one behaves
- a bug fix a user can notice
- a security fix
- a removed or deprecated feature or setting
- a new build requirement or manual step

Write no entry for:

- a refactor with no change in behavior
- tests, lint fixes, formatting, or a dependency bump with no visible effect
- CI, tooling, or agent-instruction files
- documentation, unless the document is itself the product

A change that needs no entry needs no line in the file. Do not write "internal
cleanup" — that is what `git log` is for.

## Format

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Put your
entry under `## [Unreleased]`, in one of the six fixed sections: **Added**,
**Changed**, **Deprecated**, **Removed**, **Fixed**, **Security**.

```markdown
## [Unreleased] — Stronger crypto and failures you can read

One paragraph. It becomes the first line of the App Store notes. The macOS file
needs a title and a summary.

### Added
- One change, in one bullet. Say what the reader can now do.
```

Rules the checker applies:

1. `[Unreleased]` comes first, and only once.
2. Every other heading is `## [X.Y.Z] - YYYY-MM-DD`, newest first.
3. Every version has a title after an em dash.
4. Section names come from the six above.

Check the file before you commit:

```bash
make changelog-check
```

## Write the bullet for the reader

- Name the effect, not the patch. "A failed connection now names the cause",
  not "unwrap NIOConnectionError in SSHErrorText".
- One change per bullet. One sentence, or two.
- Say the user-visible name of the thing: the menu item, the setting, the flag.
- No symbol names, no file paths, no pull request numbers.
- Open a platform-specific bullet with the platform: `- **Linux.** …`.

## Release a version

1. Move the pending entries into a numbered section. The title moves with them.
   ```bash
   python3 scripts/changelog.py release 1.2.0
   ```
2. Build and upload the Mac app.
   ```bash
   scripts/release.sh release --bump minor
   ```
   **The lanes generate the App Store text themselves.** `fastlane release`
   rewrites `fastlane/metadata/en-US/release_notes.txt` from the section that
   matches `MARKETING_VERSION` before it builds anything, and `fastlane beta`
   sends the same text as the TestFlight "What to Test". A build fails
   immediately when the section is empty or the text passes Apple's
   4000-character limit. Never edit `release_notes.txt` by hand — commit what
   the lane wrote.

   To see or refresh the file without a build:
   ```bash
   python3 scripts/changelog.py notes --project   # print it
   bundle exec fastlane mac release_notes         # write it
   ```
3. Build the Linux packages from the same tag.
   ```bash
   cd Packages/SSHManagerUI && make package-all
   cd Packages/SSHManagerUI && make release-build && make package
   ```
   `make version-check` reads `MARKETING_VERSION` out of the Xcode project, so a
   package can never carry a version the Mac app does not.

## Release branches

An entry travels with its commit. A backport cherry-picks the fix **and** its
changelog line onto the release branch, where it lands under `[Unreleased]` and
becomes the next patch release.

Two consequences:

- The `[Unreleased]` sections of `main` and the release branch differ. That is
  correct — they ship different versions next.
- A cherry-pick can conflict inside `[Unreleased]`. Resolve it like any other
  file.

## The tool

`scripts/changelog.py` needs Python 3 and nothing else.

| Command | Use |
|---------|-----|
| `check` | validate the file. Exits 1 with the line numbers |
| `show [version]` | print one parsed section |
| `notes [version] [--write]` | render the section as App Store notes, macOS bullets only |
| `release <version>` | promote `[Unreleased]` to a numbered section |

`notes` defaults to `[Unreleased]`.
