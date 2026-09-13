//
//  IncludeResolutionTests.swift
//  sshconfigmanagerTests
//
//  The effective-config resolver must linearize the config the way real `ssh`
//  does: an `Include` is expanded *inline* at its directive's position, so an
//  include near the top of the main file outranks a *later* matching block in the
//  same file (first-obtained value wins over that single stream). These tests
//  build a `ConfigGraph` directly (the in-memory equivalent of what ConfigStore
//  assembles from disk) and check ordering for the cases the flat overload got
//  wrong. Cross-checked against `ssh -G` output for the same layouts.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct IncludeResolutionTests {
    /// Builds a `ConfigGraph` from named in-memory files. `Include` values are read
    /// as space-separated file names that key into `files`; nested includes resolve
    /// recursively, mirroring `ConfigStore.reload()`'s DFS load + dedup.
    private func graph(main: String, _ files: [String: String]) -> ConfigGraph {
        var docs: [String: SSHConfigDocument] = [:]
        for (name, content) in files {
            docs[name] = SSHConfigParser.parse(content, sourceURL: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        var ordered: [SSHConfigDocument] = []
        var inclusions: [UUID: [SSHConfigDocument]] = [:]
        var visited: Set<String> = []

        func walk(_ name: String) {
            guard let doc = docs[name], !visited.contains(name) else { return }
            visited.insert(name)
            ordered.append(doc)
            for include in doc.includeDirectives {
                let names = include.value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                inclusions[include.id] = names.compactMap { docs[$0] }
                for childName in names { walk(childName) }
            }
        }
        walk(main)
        return ConfigGraph(documents: ordered, inclusions: inclusions)
    }

    // MARK: - Include position vs. a later block in the main file

    @Test func includeAtTopOutranksLaterWildcardInMain() {
        let g = graph(
            main: "config",
            [
                "config": """
                Include hosts.conf
                Host *
                    Port 99
                """,
                "hosts.conf": """
                Host web
                    HostName web.example.com
                    Port 22
                """,
            ])
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: g)
        // hosts.conf is spliced *before* the main file's `Host *`, so its Port 22
        // is obtained first and wins — matching `ssh -G web` (Port 22).
        #expect(resolved.firstValue(of: "Port") == "22")
        #expect(resolved.firstValue(of: "HostName") == "web.example.com")
    }

    @Test func includeAtEndLosesToEarlierBlockInMain() {
        let g = graph(
            main: "config",
            [
                "config": """
                Host *
                    Port 99
                Include hosts.conf
                """,
                "hosts.conf": """
                Host web
                    Port 22
                """,
            ])
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: g)
        // The main file's `Host *` precedes the include in the stream, so Port 99
        // is obtained first — matching `ssh -G web` (Port 99).
        #expect(resolved.firstValue(of: "Port") == "99")
    }

    @Test func nestedIncludesSpliceInStreamOrder() {
        let g = graph(
            main: "config",
            [
                "config": """
                Include mid.conf
                Host *
                    User mainuser
                """,
                "mid.conf": """
                Include leaf.conf
                Host *
                    User miduser
                """,
                "leaf.conf": """
                Host web
                    User leafuser
                    HostName leaf.example.com
                """,
            ])
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: g)
        // leaf.conf is spliced deepest-first at the top of the stream, so its
        // `Host web` wins User before either `Host *` is reached.
        #expect(resolved.firstValue(of: "User") == "leafuser")
        #expect(resolved.firstValue(of: "HostName") == "leaf.example.com")
    }

    @Test func repeatableIdentityFileAccumulatesInStreamOrder() {
        let g = graph(
            main: "config",
            [
                "config": """
                IdentityFile ~/.ssh/main_top
                Include hosts.conf
                Host *
                    IdentityFile ~/.ssh/main_star
                """,
                "hosts.conf": """
                Host web
                    IdentityFile ~/.ssh/child_web
                """,
            ])
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: g)
        // Global (preamble) IdentityFile, then the spliced include, then the main
        // file's `Host *` — in exactly that stream order, like `ssh -G web`.
        #expect(
            resolved.values(of: "IdentityFile") == [
                "~/.ssh/main_top", "~/.ssh/child_web", "~/.ssh/main_star",
            ])
    }

    @Test func includeInsideMatchingHostBlockSplicesThere() {
        let g = graph(
            main: "config",
            [
                "config": """
                Host web
                    Include host-extra.conf
                    Port 99
                """,
                "host-extra.conf": """
                Host web
                    Port 22
                    Compression yes
                """,
            ])
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: g)
        // The include sits before `Port 99` inside the matched block, so Port 22
        // (from the spliced file) is obtained first.
        #expect(resolved.firstValue(of: "Port") == "22")
        #expect(resolved.firstValue(of: "Compression") == "yes")
    }

    @Test func includeInsideNonMatchingHostBlockIsSkipped() {
        let g = graph(
            main: "config",
            [
                "config": """
                Host other
                    Include host-extra.conf
                Host web
                    Port 99
                """,
                "host-extra.conf": """
                Host web
                    Port 22
                """,
            ])
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: g)
        // The include is gated behind `Host other`, which doesn't match `web`, so it
        // never splices — only the main file's `Host web` contributes.
        #expect(resolved.firstValue(of: "Port") == "99")
    }

    // MARK: - Flat overload still behaves as before (regression guard)

    @Test func flatOverloadStillAppendsIncludesAfterMain() {
        // Same layout as `includeAtTopOutranksLaterWildcardInMain`, but the flat
        // overload processes documents sequentially (main fully, then includes), so
        // the main file's `Host *` wins — the historical, ssh-divergent behavior the
        // ConfigGraph overload fixes. Locked in so the two paths stay distinct.
        let main = SSHConfigParser.parse(
            """
            Include hosts.conf
            Host *
                Port 99
            """, sourceURL: URL(fileURLWithPath: "/tmp/config"))
        let child = SSHConfigParser.parse(
            """
            Host web
                Port 22
            """, sourceURL: URL(fileURLWithPath: "/tmp/hosts.conf"))
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: [main, child])
        #expect(resolved.firstValue(of: "Port") == "99")
    }

    // MARK: - Jump chain honors include order

    @Test func jumpChainResolvesTargetThroughIncludeOrder() throws {
        let g = graph(
            main: "config",
            [
                "config": """
                Include hosts.conf
                Host *
                    Port 99
                """,
                "hosts.conf": """
                Host web
                    HostName web.example.com
                    Port 22
                """,
            ])
        let chain = try TunnelJumpChain.resolve(alias: "web", in: g)
        #expect(chain.count == 1)
        #expect(chain[0].host == "web.example.com")
        // Port comes from the spliced include, not the later `Host *`.
        #expect(chain[0].port == 22)
    }
}
