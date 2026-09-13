//
//  SSHConfigCore.swift
//  SSHConfigKit
//
//  The shared, platform-agnostic core: ssh_config model + lossless parser +
//  pure logic, with zero non-Foundation dependencies so a Linux CLI/daemon can
//  link it directly. Real types are migrated here in staged commits; this file
//  marks the module and will hold any small cross-cutting helpers.
//

/// Namespace marker for the shared core module.
public enum SSHConfigCore {
    /// The semantic area this module owns. Present so the module is non-empty
    /// while types are migrated in; safe to remove once real types land.
    public static let moduleName = "SSHConfigCore"
}
