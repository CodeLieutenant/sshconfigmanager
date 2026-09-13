//
//  TunnelCommandBuilder.swift
//  sshconfigmanager
//
//  Pure: turns a `TunnelPreset` into an `ssh` argument vector (and a shell
//  command string). It passes the host *alias* and lets `ssh` resolve the rest
//  from ~/.ssh/config — so User/IdentityFile/ProxyJump are inherited exactly the
//  way a terminal `ssh <alias>` would. No I/O; trivially unit-testable.
//  See docs/plans/tunneling/command-builder.md.
//

import Foundation

public enum TunnelCommandBuilder {
    /// The `ssh` argument vector for a preset, starting with `ssh`.
    ///
    /// Using an argv (not a shell string) is injection-safe: each element is one
    /// argument no matter what characters it contains.
    public static func arguments(for preset: TunnelPreset) -> [String] {
        // -N: no remote command, -T: no PTY.
        // ControlPath=none forces a dedicated connection: without it, a user's
        // `ControlMaster auto` + `ControlPersist` config would hand the forwards
        // to a background master that outlives the terminal window, so closing
        // the window wouldn't stop the tunnel. A standalone connection dies with
        // its window, which is the lifecycle the Assist engine promises.
        var args = ["ssh", "-N", "-T", "-o", "ControlPath=none"]

        for mapping in preset.mappings {
            args += [preset.mode.flag, mapping.forwardSpec(for: preset.mode)]
        }

        args.append(preset.hostAlias)
        return args
    }

    /// A ready-to-run, shell-safe command string (for copying or launching in a
    /// terminal). Each argument is quoted only when it needs to be.
    public static func commandString(for preset: TunnelPreset) -> String {
        arguments(for: preset).map(shellQuoted).joined(separator: " ")
    }

    /// Single-quotes an argument if it contains anything outside a safe set —
    /// see `ShellQuoting.argument`.
    public nonisolated static func shellQuoted(_ argument: String) -> String {
        ShellQuoting.argument(argument)
    }
}
