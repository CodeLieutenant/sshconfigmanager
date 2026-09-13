# Changelog

Every user-visible change to SSH Config Manager, on every platform. A bullet
that applies to only one platform names it.

This file is the product changelog. It is the source for the App Store
"What's New" text (`fastlane/metadata/en-US/release_notes.txt`), so write each
bullet for a customer, not for a reviewer.

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The
six section names are fixed: Added, Changed, Deprecated, Removed, Fixed,
Security.

Run `scripts/changelog.py check` before you commit. See
[docs/changelog.md](docs/changelog.md) for the workflow.

## [Unreleased]

### Added

- Tunnels now understand three common `ProxyCommand` patterns — `ssh -W`
  jump hosts, a SOCKS5 proxy, and an HTTP CONNECT proxy — and run them
  in-process, no separate binary needed.
- The direct-download build (not the Mac App Store one) now runs any other
  `ProxyCommand` as a real subprocess, and opens Ghostty, kitty or WezTerm
  directly for Connect & Launch instead of only copying the command.
- GitHub Gist sync: sign in with GitHub, back up your SSH config to a
  private gist, and pull it down on another machine. Optional end-to-end
  encryption, and a conflict prompt (Keep Local / Take Remote) if both sides
  changed since the last sync.
- Version history records each pull from sync as its own entry, so you can go
  back to the config you had before the pull.
- Issues finds a setting that two lines give a different value to. ssh keeps the
  first value it reads, so the second line never applies. The entry names the
  value that wins, the value that does not, and the `ssh -G` command that shows
  you the result.
- Issues finds the same clash between two hosts of the same name in different
  files. Which one wins depends on where the `Include` line sits, so the entry
  names the file that wins.
- Issues reports an option name ssh does not know as an error. ssh stops with
  "Bad configuration option" and connects to nothing, so one misspelled name
  breaks every host in the file, not only the host that holds it. An option
  listed in `IgnoreUnknown` is not reported.

- **Linux.** Packages for Debian and Red Hat based distributions, for 64-bit Intel and ARM.
  The binary carries its own Swift runtime, so it installs on a system with no
  Swift packages.
- **Linux.** `.deb`, `.rpm` and Flatpak packages on the project's releases page.
- **Linux.** `sshmanager`, the desktop application for GNOME. It follows your system theme,
  your accent colour and your contrast setting, because it is built from stock
  GTK 4 and libadwaita widgets.
- **Linux.** Every host in your configuration, including the hosts an included file defines.
  Edit a setting and only that line changes — your comments, blank lines,
  indentation and quoting stay exactly as you wrote them.
- **Linux.** Screens for your keys, the SSH agent, known hosts, tunnels, issues and version
  history, plus global defaults and background notifications.
- **Linux.** Key generation for Ed25519 and ECDSA. A new private key is created with owner
  only permissions before any secret is written into it.
- **Linux.** A version of every configuration file the app writes, kept under
  `~/.local/share/sshmanager/history`. Compare a version with the file on disk,
  and put any version back — the restore is itself recorded, so it can be undone.
- **Linux.** A search field and a Go to dialog that find a host by name, by host name or by
  tag.
- **Linux.** Preferences for saving, appearance, the editor, keys and tunnels, history, the
  key audit and privacy.

### Changed

- SSH Config Manager is now free and open source. Every feature that used to
  need Pro — tunnels, key generation, agent management, version history,
  known-hosts editing, code completion, menu-bar items and background host-key
  checks — is available to everyone, with nothing to buy and nothing to unlock.
- The Mac app needs macOS 15 or later.
- The Mac app keeps tunnels, version history, groups, favorites, tags and the
  host key log in a new data store. The first launch after the update moves
  your existing data across. Nothing needs to be set up again.

- **Linux.** SSH Config Manager is free and open source. There is no paid tier, so every
  feature is available to everyone.
- **Linux.** Report a Bug opens the project's issue tracker in your browser.
- **Linux.** Every screen now opens with a header that names it: a coloured badge, the
  title, and a line that says what you are looking at. Before this, one screen
  looked much like the next.
- **Linux.** A host, a key, an agent identity and a stored host key each show their state as
  a small coloured capsule — reachable, loaded, revoked, no passphrase — so you
  can read it without opening the row.
- **Linux.** The settings inside a host read as a property list: the keyword on the left and
  the value on the right, plain until you click into it. Each setting used to be
  a form field with its label floating inside the box and a line of help beneath.
  The help is now on hover.
- **Linux.** The host screen uses two columns on a wide window. The settings stay on the
  left, and the keys, tunnels and actions for that host move to the right.
- **Linux.** The settings a host does not use yet appear as buttons you can press, one for
  each, in place of a line of names.
- **Linux.** The key list is grouped by algorithm, and each key says whether both halves of
  the pair are on disk.
- **Linux.** Known hosts are split into host names, IP addresses and hashed entries, and a
  row marks a revoked key or an entry that needs review.

### Removed

- The app no longer contacts any server. Licensing, purchases, the free trial,
  account registration, crash reporting, the daily install report and the
  in-app bug reporter are all gone. The only network traffic left is the SSH
  connections you start and the GitHub Gist sync you turn on.
- Report a Bug now opens the project's issue tracker in your browser.

### Fixed

- **Linux.** Selecting a different area or host in the sidebar now shows it. The highlight
  moved but the page did not, so the app stayed on whatever it opened with.
- **Linux.** The Global Defaults screen shows your `Host *` block instead of reporting that
  the host was not found. Edits made there were also discarded.

### Security

- Trust on first use now refuses a host name that carries spaces or an `@`
  marker. A crafted host alias could add a rule to `known_hosts` that trusted an
  attacker key for every server.
- Sync now only pulls back the config files it already tracks. A tampered gist
  can no longer drop a private key, an `authorized_keys` file, or any other file
  into your `.ssh` folder.

- **Linux.** The application writes `~/.ssh/config` with owner only permissions, and creates
  `~/.ssh` with mode 0700 when it is missing. ssh refuses a configuration other
  users can write.

## [1.1.0] - 2026-08-11 — Stronger crypto and failures you can read

This release teaches the tunnel engine to talk to hardened OpenSSH servers, and
to tell you what went wrong when a connection does not come up.

### Added

- Post-quantum key exchange (`mlkem768x25519-sha256`), AES-CTR ciphers and
  HMAC-SHA2 integrity. Hardened servers that refused the connection now accept it.
- A server security audit. The app flags a weak host key, cipher or MAC, and
  Known Hosts shows the result for each server. Two settings control the check
  and whether a weak server is refused.
- A log window (View ▸ Open Logs, ⇧⌘L) with level, category and time filters,
  search, a live tail, and copy or save of what you see.

### Changed

- A failed connection now names the cause — "host not found", "connection
  refused", "port 3000 is already in use", or a connect timeout — instead of an
  internal error code. The Tunnels detail view keeps the last failure next to
  the reconnect state.
- The app writes far more detail to the system log, and every log line keeps its
  real severity. Bug reports now carry the errors that matter.

### Fixed

- A tunnel whose server refuses to forward now says so in the console. The
  tunnel stayed green while every request through it returned nothing, and the
  console gave no reason. The line names the address and the server's own cause
  — forwarding turned off, or a target the server cannot reach.

### Security

- The app checks the length the server declares for each SSH packet before it
  trusts it. A hostile server could crash the app on the first packet, or make
  it hold up to four gigabytes in memory.

## [1.0.0] - 2026-07-31 — SSH Config Manager for Mac

The first public release. One native app for your `~/.ssh` folder: the config
file, your keys, `known_hosts`, and tunnels that run inside the app.

### Added

- A visual host editor and a raw text editor for `~/.ssh/config`. The parser
  keeps every comment, blank line and custom format exactly as you wrote it.
- Fuzzy host search, tags, favorites, and a command palette.
- Version history as a git-style tree. Browse an earlier version, compare it,
  and restore it with one click.
- Key generation for Ed25519, ECDSA and RSA, with no `ssh-keygen` flags to recall.
- A `known_hosts` browser that groups the entries for each server, and a Verify
  action that reads the server's key without a login.
- An SSH agent screen that lists the loaded keys and adds or removes one.
- Tunnels that run inside the app, with no Terminal window and no background
  `ssh` process: local (`-L`), remote (`-R`) and dynamic SOCKS (`-D`) forwarding,
  several forwards over one connection, multi-hop `ProxyJump`, agent and
  private-key authentication, `known_hosts` verification with trust on first use,
  live throughput, a per-tunnel console, and reconnect with backoff.
- Completion in the raw editor for keywords, values, algorithms and host names.
- Pro as a one-time purchase. The config editor stays free.
- A Help section with an account menu, and license activation that asks for your
  email when Apple does not share it.

### Security

- The app is sandboxed and reads `~/.ssh` only after you grant permission. Keys,
  configuration and tunnel traffic stay on your Mac. The one network call the
  app makes on its own verifies your license.
