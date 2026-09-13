//
//  TerminalLauncherTests.swift
//  sshconfigmanagerTests
//
//  Phase 2 of Connect & Launch. The OS-touching `launch` can't run in a unit
//  test (it would drive AppleScript), so the testable contract is the pure
//  helpers — `{ssh}` template substitution and AppleScript construction/quoting —
//  plus `ConfigStore.connect` wired to a fake launcher to prove the outcome →
//  `launchStatus` mapping without opening a terminal.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

// MARK: - Pure helpers

@MainActor
struct TerminalLauncherHelperTests {
    @Test func emptyTemplateRunsCommandVerbatim() {
        #expect(TerminalLauncher.applyTemplate("", to: "ssh box") == "ssh box")
    }

    @Test func templateWithoutPlaceholderIsIgnored() {
        // A template that forgot `{ssh}` would otherwise drop the command — guard it.
        #expect(TerminalLauncher.applyTemplate("tmux new-window", to: "ssh box") == "ssh box")
    }

    @Test func templateSubstitutesAndTrims() {
        #expect(
            TerminalLauncher.applyTemplate("  tmux new-window '{ssh}'  ", to: "ssh box")
                == "tmux new-window 'ssh box'")
    }

    @Test func appleScriptQuoteEscapesBackslashAndQuote() {
        #expect(TerminalLauncher.appleScriptQuote(#"a"b\c"#) == #""a\"b\\c""#)
    }

    @Test func terminalScriptUsesDoScript() {
        let script = TerminalLauncher.appleScript(for: .terminal, command: "ssh example")
        #expect(script.contains(#"do script "ssh example""#))
        #expect(script.contains(#"tell application "Terminal""#))
    }

    @Test func processLaunchArgumentsRunTheCommandThroughSh() {
        let ghostty = TerminalPreset.preset(id: "ghostty")
        #expect(
            TerminalLauncher.processLaunchArguments(for: ghostty, command: "ssh box")
                == ["-na", "Ghostty", "--args", "-e", "/bin/sh", "-c", "ssh box"])
        let kitty = TerminalPreset.preset(id: "kitty")
        #expect(
            TerminalLauncher.processLaunchArguments(for: kitty, command: "ssh box")
                == ["-na", "kitty", "--args", "/bin/sh", "-c", "ssh box"])
        let wezterm = TerminalPreset.preset(id: "wezterm")
        #expect(
            TerminalLauncher.processLaunchArguments(for: wezterm, command: "ssh box")
                == ["-na", "WezTerm", "--args", "start", "--", "/bin/sh", "-c", "ssh box"])
    }

    @Test func processLaunchArgumentsAreNilForAppleScriptTerminals() {
        let terminal = TerminalPreset.preset(id: "terminal")
        #expect(TerminalLauncher.processLaunchArguments(for: terminal, command: "ssh box") == nil)
    }

    @Test func itermScriptOpensWindowAndWritesText() {
        let script = TerminalLauncher.appleScript(for: .iterm, command: "ssh example")
        #expect(script.contains(#"tell application "iTerm""#))
        #expect(script.contains("create window with default profile"))
        #expect(script.contains(#"write text "ssh example""#))
    }

    @Test func deniedAutomationPointsAtPrivacyAndReset() {
        // -1743 (errAEEventNotPermitted): the failure the user actually hits when a
        // stale/poisoned grant blocks the event — must name both the Automation
        // pane and the tccutil reset escape hatch.
        let message = TerminalLauncher.failureMessage(for: -1743, terminalName: "Terminal")
        #expect(message.contains("Privacy & Security ▸ Automation"))
        #expect(message.contains("tccutil reset AppleEvents"))
        #expect(message.contains("clipboard"))
    }

    @Test func unreachableTerminalIsDistinctFromDenial() {
        // -600 (procNotFound): don't blame automation settings when the app simply
        // isn't reachable.
        let message = TerminalLauncher.failureMessage(for: -600, terminalName: "iTerm")
        #expect(!message.contains("Automation"))
        #expect(message.contains("clipboard"))
    }

    @Test func unknownErrorSurfacesTheNumber() {
        let message = TerminalLauncher.failureMessage(for: -42, terminalName: "Terminal")
        #expect(message.contains("-42"))
    }
}

// MARK: - Preset lookup

@MainActor
struct TerminalPresetTests {
    @Test func unknownIDFallsBackToTerminal() {
        #expect(TerminalPreset.preset(id: "nope").id == "terminal")
    }

    @Test func clipboardOnlyTerminalsAreMarkedSo() {
        #expect(TerminalPreset.preset(id: "ghostty").handoff == .clipboardOnly)
        #expect(TerminalPreset.preset(id: "terminal").handoff == .appleScript(.terminal))
    }
}

// MARK: - connect() outcome → launchStatus

@MainActor
private final class FakeLauncher: TerminalLaunching {
    var lastCommand: SSHCommandBuilder.Command?
    var lastPreset: TerminalPreset?
    var outcome: TerminalLaunchOutcome = .launched(terminalName: "Terminal")

    func launch(_ command: SSHCommandBuilder.Command, using preset: TerminalPreset) -> TerminalLaunchOutcome {
        lastCommand = command
        lastPreset = preset
        return outcome
    }
}

@MainActor
struct ConnectFlowTests {
    private func store(template: String = "", terminal: String = "terminal") -> (ConfigStore, FakeLauncher) {
        let settings = AppSettings(database: nil)
        settings.terminalCommandTemplate = template
        settings.preferredTerminalID = terminal
        let store = ConfigStore(settings: settings)
        let launcher = FakeLauncher()
        store.terminalLauncher = launcher
        store.loadForTesting([
            SSHConfigParser.parse(
                "Host box\n    HostName 10.0.0.5\n", sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        return (store, launcher)
    }

    private var box: HostBlock {
        SSHConfigParser.parse(
            "Host box\n    HostName 10.0.0.5\n",
            sourceURL: URL(fileURLWithPath: "/tmp/config")
        ).blocks[0]
    }

    /// A successful launch leaves no status alert and passes the alias command
    /// and the chosen preset through to the launcher.
    @Test func launchedLeavesNoStatusAndForwardsAliasCommand() {
        let (store, launcher) = store(terminal: "iterm")
        store.connect(box)
        #expect(store.launchStatus == nil)
        #expect(launcher.lastCommand?.shellString == "ssh box")
        #expect(launcher.lastPreset?.id == "iterm")
    }

    /// A clipboard fallback surfaces its message via `launchStatus` (an info
    /// alert), never `errorMessage`.
    @Test func clipboardFallbackSetsLaunchStatus() {
        let (store, launcher) = store()
        launcher.outcome = .copiedToClipboard(message: "Copied — paste it.")
        store.connect(box)
        #expect(store.launchStatus == "Copied — paste it.")
        #expect(store.errorMessage == nil)
    }

    /// The `{ssh}` template wraps the command before it reaches the launcher.
    @Test func templateIsAppliedBeforeLaunch() {
        let (store, launcher) = store(template: "tmux new-window '{ssh}'")
        store.connect(box)
        #expect(launcher.lastCommand?.shellString == "tmux new-window 'ssh box'")
    }

    /// A pattern-only block has no destination — connect must be a no-op.
    @Test func wildcardBlockDoesNotLaunch() {
        let (store, launcher) = store()
        let wildcard = SSHConfigParser.parse(
            "Host *\n    User deploy\n",
            sourceURL: URL(fileURLWithPath: "/tmp/config")
        ).blocks[0]
        store.connect(wildcard)
        #expect(launcher.lastCommand == nil)
    }
}
