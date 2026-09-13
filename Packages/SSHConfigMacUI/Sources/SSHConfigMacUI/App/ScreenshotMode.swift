//
//  ScreenshotMode.swift
//  sshconfigmanager
//
//  DEBUG-only support for capturing App Store screenshots and preview videos with
//  the `scripts/screenshots.sh` / `scripts/record-preview.sh` harness. The whole
//  file compiles OUT of Release — it is gated on `#if DEBUG` and only activates
//  when launched with `--uitest-screenshot`, an argument no shipping path passes.
//
//  It pairs with the existing QA seams:
//    --uitest-screenshot        seed a polished ~/.ssh fixture, a running tunnel list,
//                               and a deterministic ssh-agent identity list
//    --uitest-tunnel-demo       seed 3 tunnel presets + DemoTunnelEngine
//    --uitest-window-size WxH    pin a deterministic capture size (default 1440x900,
//                                which is exactly 2880x1800 px on a 2x Retina display —
//                                both are valid Mac App Store screenshot dimensions)
//
//  Seeding here mirrors ConfigStore's proven `--uitest-seed-keys` pattern: the app
//  writes the fixture into its OWN sandbox temp dir so a signed, sandboxed build
//  (what XCUITest requires) can read it without an open-panel grant.
//

#if DEBUG
    import AppKit
    import Foundation
    import SSHConfigCore

    enum ScreenshotMode {
        /// Active when the screenshot/preview harness launched the app.
        nonisolated static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains("--uitest-screenshot")
        }

        // MARK: - Deterministic window size

        /// Parses `--uitest-window-size 1440x900` (points). Defaults to 1440x900.
        static func windowSize() -> NSSize {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--uitest-window-size"), i + 1 < args.count {
                let parts = args[i + 1].lowercased().split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                    return NSSize(width: w, height: h)
                }
            }
            return NSSize(width: 1440, height: 900)
        }

        /// Pins the main window's CONTENT area to the capture size and centers it. The
        /// content area (not the full frame) is what an XCUITest window screenshot
        /// captures, so sizing it to 1440x900 lands the PNG on exactly 2880x1800 px on a
        /// 2x Retina display — a valid Mac App Store dimension.
        @MainActor static func applyWindowFrame() {
            let size = windowSize()
            for window in NSApp.windows where window.identifier?.rawValue == "main" {
                window.styleMask.remove(.fullScreen)
                window.setContentSize(size)
                window.center()
            }
        }

        // MARK: - Tunnel demo (three forward modes, DemoTunnelEngine)

        /// Active when the tunnel demo recording harness launched the app.
        static var isTunnelDemo: Bool {
            ProcessInfo.processInfo.arguments.contains("--uitest-tunnel-demo")
        }

        /// Three presets covering all forward modes: local (-L) × 2 and dynamic (-D /
        /// SOCKS5). Pre-seeded so the list is never empty on launch; the first preset
        /// is injected as already "Active" by `TunnelStore.seedTunnelDemo()`.
        static func sampleTunnelPresets() -> [TunnelPreset] {
            [
                TunnelPreset(
                    name: "Postgres via bastion",
                    hostAlias: "db-bastion", mode: .local,
                    mappings: [
                        PortMapping(
                            bindAddress: "127.0.0.1",
                            listenPort: 5432,
                            targetHost: "10.0.1.20",
                            targetPort: 5432)
                    ]),
                TunnelPreset(
                    name: "Redis via bastion",
                    hostAlias: "db-bastion", mode: .local,
                    mappings: [
                        PortMapping(
                            bindAddress: "127.0.0.1",
                            listenPort: 6379,
                            targetHost: "10.0.1.20",
                            targetPort: 6379)
                    ]),
                TunnelPreset(
                    name: "SOCKS5 Proxy",
                    hostAlias: "db-bastion", mode: .dynamic,
                    mappings: [PortMapping(listenPort: 1080)]),
            ]
        }

        /// Extra presets shown ONLY in the App Store screenshot run, never in the
        /// tunnel recording. `record-tunnel-demo.sh` drives the three presets above by
        /// name and needs Redis and SOCKS5 to still be stopped so it can press Start;
        /// adding these here keeps that script's expectations untouched while the
        /// screenshot gets a list at a believable scale, across several hosts and modes.
        static func extraScreenshotTunnelPresets() -> [TunnelPreset] {
            [
                TunnelPreset(
                    name: "Grafana on prod",
                    hostAlias: "production-web", mode: .local,
                    mappings: [
                        PortMapping(
                            bindAddress: "127.0.0.1", listenPort: 3000,
                            targetHost: "10.0.2.10", targetPort: 3000, hasWebUI: true)
                    ]),
                TunnelPreset(
                    name: "Staging API",
                    hostAlias: "staging-api", mode: .local,
                    mappings: [
                        PortMapping(
                            bindAddress: "127.0.0.1", listenPort: 8080,
                            targetHost: "10.0.3.5", targetPort: 8080, hasWebUI: true)
                    ]),
                TunnelPreset(
                    name: "Home Assistant",
                    hostAlias: "raspberry-pi", mode: .local,
                    mappings: [
                        PortMapping(
                            bindAddress: "127.0.0.1", listenPort: 8123,
                            targetHost: "192.168.1.42", targetPort: 8123, hasWebUI: true)
                    ]),
                TunnelPreset(
                    name: "Webhook callback",
                    hostAlias: "production-web", mode: .remote,
                    mappings: [
                        PortMapping(
                            listenPort: 9000, targetHost: "127.0.0.1", targetPort: 4000)
                    ]),
            ]
        }

        // MARK: - Agent identities (deterministic, not the developer's real agent)

        /// The identities the Agent screen shows during a screenshot run.
        ///
        /// Without this the capture reads the *live* ssh-agent, so the shot documented
        /// whatever the machine happened to be holding — in practice a dozen leftover
        /// `sshcfgmgr-test` keys from `AgentIntegrationTests`. Seeding makes the screen
        /// reproducible and shows the states worth showing: a key matched to one on
        /// disk, two loaded from somewhere else entirely, and (because `id_rsa` is
        /// absent here) a disk key that is not loaded.
        ///
        /// `seedByte 0x11` is the same byte the fixture's `id_ed25519.pub` uses, so the
        /// fingerprints match and `AgentKeyCorrelation.merge` pairs them.
        static func sampleAgentIdentities() -> [AgentIdentity] {
            [
                agentIdentity(comment: "deploy@prod", seedByte: 0x11),
                agentIdentity(comment: "me@laptop", seedByte: 0x31),
                agentIdentity(comment: "ci-runner@github", seedByte: 0x32),
            ]
        }

        private static func agentIdentity(comment: String, seedByte: UInt8) -> AgentIdentity {
            AgentIdentity(
                keyBlob: ed25519Blob(seedByte: seedByte),
                comment: comment,
                keyType: "ssh-ed25519")
        }

        // MARK: - Identity-file path presentation

        /// How a fixture key's `IdentityFile` path should read on screen.
        ///
        /// The fixture lives in the app's sandbox temp dir, so the honest abbreviation
        /// is `~/tmp/screenshot-ssh/id_ed25519` — a harness path that appears in no
        /// real user's config. Screenshot runs present the `~/.ssh` path the same key
        /// would have on a real machine. Returns nil outside screenshot mode, and for
        /// any key that is not part of the fixture.
        ///
        /// This is presentation only, but it does reach the two places that *consume*
        /// the value (the `IdentityFile` picker and the copied `ssh-add` command). Both
        /// write to a throwaway fixture whose config already names `~/.ssh/id_ed25519`,
        /// so the substitution stays consistent with what is on screen.
        nonisolated static func presentedIdentityFilePath(for key: SSHPublicKey) -> String? {
            guard isActive else { return nil }
            let url = key.privateKeyURL ?? key.publicKeyURL?.deletingPathExtension()
            guard let url, url.path.contains("/screenshot-ssh/") else { return nil }
            return "~/.ssh/" + url.lastPathComponent
        }

        // MARK: - Polished ~/.ssh fixture

        /// Writes the screenshot fixture into the app's sandbox temp dir and returns it,
        /// or nil on failure. Mirrors `ConfigStore.createSeededUITestDirectory()`.
        static func createSeededDirectory() -> URL? {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("screenshot-ssh", isDirectory: true)
            try? FileManager.default.removeItem(at: base)
            do {
                try seed(in: base)
                return base
            } catch {
                return nil
            }
        }

        /// A presentable config (several realistically named hosts incl. a ProxyJump)
        /// plus two healthy public keys and a known_hosts file, all with correct perms
        /// so the key-health audit stays clean for the Keys capture.
        static func seed(in base: URL) throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)

            func write(_ text: String, _ name: String, mode: Int) throws {
                let url = base.appendingPathComponent(name)
                try text.write(to: url, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }

            let config = """
                # Managed by SSH Config Manager
                Host production-web
                    HostName web.prod.example.com
                    User deploy
                    Port 22
                    IdentityFile ~/.ssh/id_ed25519

                Host db-bastion
                    HostName bastion.example.com
                    User admin
                    IdentityFile ~/.ssh/id_ed25519

                Host staging-api
                    HostName api.staging.example.com
                    User deploy
                    ProxyJump db-bastion

                Host raspberry-pi
                    HostName 192.168.1.42
                    User pi

                Host github.com
                    HostName github.com
                    User git
                    IdentityFile ~/.ssh/id_ed25519
                """
            try write(config + "\n", "config", mode: 0o600)

            // One modern ed25519 key + one healthy 3072-bit RSA key, with matching
            // private placeholders at 0600 so the audit reports no permission issues.
            let privatePEM = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
            try write(ed25519PublicLine(comment: "deploy@prod", seedByte: 0x11), "id_ed25519.pub", mode: 0o644)
            try write(privatePEM, "id_ed25519", mode: 0o600)
            try write(healthyRSAPublicLine(comment: "admin@bastion"), "id_rsa.pub", mode: 0o644)
            try write(privatePEM, "id_rsa", mode: 0o600)

            // Real (well-formed) ed25519 host-key blobs so fingerprints compute.
            let knownHosts = """
                web.prod.example.com ssh-ed25519 \(ed25519Base64(seedByte: 0x21))
                bastion.example.com ssh-ed25519 \(ed25519Base64(seedByte: 0x22))
                github.com ssh-ed25519 \(ed25519Base64(seedByte: 0x23))
                """
            try write(knownHosts + "\n", "known_hosts", mode: 0o644)
        }

        /// `length`-prefixed SSH wire encoding of a byte field.
        private static func sshField(_ bytes: [UInt8]) -> [UInt8] {
            let n = UInt32(bytes.count)
            return [
                UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF),
                UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF),
            ] + bytes
        }

        /// A well-formed `ssh-ed25519` key blob (32-byte key of `seedByte`).
        /// Display/fingerprint only — not a real curve point, but parses and hashes.
        /// The agent seed and the on-disk fixture share this, so a matching `seedByte`
        /// is what makes their fingerprints correlate.
        private static func ed25519Blob(seedByte: UInt8) -> [UInt8] {
            let pub = [UInt8](repeating: seedByte, count: 32)
            return sshField(Array("ssh-ed25519".utf8)) + sshField(pub)
        }

        private static func ed25519Base64(seedByte: UInt8) -> String {
            Data(ed25519Blob(seedByte: seedByte)).base64EncodedString()
        }

        private static func ed25519PublicLine(comment: String, seedByte: UInt8) -> String {
            "ssh-ed25519 " + ed25519Base64(seedByte: seedByte) + " " + comment + "\n"
        }

        /// An `ssh-rsa <base64> comment` line with a 3072-bit modulus (healthy).
        private static func healthyRSAPublicLine(comment: String) -> String {
            var modulus = [UInt8](repeating: 0, count: 3072 / 8)
            modulus[0] = 0x80
            let blob = sshField(Array("ssh-rsa".utf8)) + sshField([0x01, 0x00, 0x01]) + sshField([0x00] + modulus)
            return "ssh-rsa " + Data(blob).base64EncodedString() + " " + comment + "\n"
        }
    }

    // MARK: - Demo tunnel engine

    /// A `TunnelEngine` that never opens a network connection. On `start`, emits a
    /// deterministic sequence of realistic lifecycle log lines followed by `.connected`.
    /// Throughput grows linearly to simulate live traffic. Used exclusively by
    /// `TunnelStore` in `--uitest-tunnel-demo` mode so the recording shows authentic
    /// UI behaviour without requiring a real SSH server.
    @MainActor
    final class DemoTunnelEngine: TunnelEngine {
        let capabilities = TunnelEngineCapabilities(
            reportsLiveness: true,
            canStop: true,
            survivesAppQuit: false,
            reportsThroughput: true
        )

        private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
        private var startTimes: [UUID: Date] = [:]

        func start(_ preset: TunnelPreset) throws {
            startTimes[preset.id] = Date()
        }

        func stop(_ preset: TunnelPreset) {
            continuations[preset.id]?.finish()
            continuations.removeValue(forKey: preset.id)
        }

        func events(for preset: TunnelPreset) -> AsyncStream<EngineEvent>? {
            let result = AsyncStream<EngineEvent>.makeStream()
            let continuation = result.continuation
            continuations[preset.id] = continuation
            let host = preset.hostAlias
            let isDynamic = preset.mode == .dynamic
            let port = preset.mappings.first?.listenPort ?? 0
            Task {
                let messages: [(TunnelLogLevel, String)] = [
                    (.info, "Connecting to \(host)…"),
                    (.detail, "Host key verified (ssh-ed25519 SHA256:aBcDeFgH1234xYz)"),
                    (.info, "Authenticated using publickey (id_ed25519)"),
                    (
                        .info,
                        isDynamic
                            ? "SOCKS5 proxy listening on 127.0.0.1:\(port)"
                            : "Listening on 127.0.0.1:\(port)"
                    ),
                ]
                for (level, message) in messages {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continuation.yield(.log(level, message))
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                continuation.yield(.connected)
                // Stream stays open; stop() finishes it when the tunnel is stopped.
            }
            return result.stream
        }

        func throughput(for preset: TunnelPreset) -> TunnelThroughput? {
            let elapsed = max(0, -(startTimes[preset.id]?.timeIntervalSinceNow ?? 0))
            return TunnelThroughput(
                bytesIn: 2_341_760 + UInt64(elapsed * 2_560),
                bytesOut: 487_424 + UInt64(elapsed * 256)
            )
        }
    }
#endif
