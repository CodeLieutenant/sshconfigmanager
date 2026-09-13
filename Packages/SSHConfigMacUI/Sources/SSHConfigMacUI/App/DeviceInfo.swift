//
//  DeviceInfo.swift
//  SSHConfigMacUI
//
//  App + host identifiers used in the launch log line.
//

import Foundation

enum DeviceInfo {
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    static var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    static var versionSummary: String {
        [appVersion, appBuild.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }
    static var platformSummary: String {
        [osVersion, model.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    /// Hardware model identifier (e.g. "Mac14,2"), via sysctl. Sandbox-safe.
    static var model: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
