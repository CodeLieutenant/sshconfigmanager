import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

nonisolated enum VerifyOutcome: Equatable {
    case verified(HostKeyScanner.Probe)
    case changed(HostKeyScanner.Probe)
    case notStored(HostKeyScanner.Probe)
    case failed(HostKeyScanner.ScanError)

    init(probe: HostKeyScanner.Probe, group: KnownHostGroup) {
        if group.entries.contains(where: { $0.fingerprint == probe.fingerprint }) {
            self = .verified(probe)
        } else if group.entries.contains(where: { $0.keyType == probe.keyType }) {
            self = .changed(probe)
        } else {
            self = .notStored(probe)
        }
    }

    var status: StatusKind {
        switch self {
        case .verified: return .ok
        case .changed: return .error
        case .notStored: return .warn
        case .failed: return .idle
        }
    }

    var headline: String {
        switch self {
        case .verified: return "Host key verified"
        case .changed: return "Host key CHANGED"
        case .notStored: return "New key type offered"
        case .failed: return "Couldn't verify"
        }
    }

    var detail: String {
        switch self {
        case .verified(let p):
            return "The \(p.keyType) key the server presents matches your known_hosts."
        case .changed(let p):
            return
                "The server is presenting a different \(p.keyType) key than the one you trust. Confirm out-of-band before trusting it."
        case .notStored(let p):
            return "The server offered a \(p.keyType) key that isn't in your known_hosts for this host."
        case .failed(let e):
            return e.message
        }
    }

    var fingerprint: String? {
        switch self {
        case .verified(let p), .changed(let p), .notStored(let p): return p.fingerprint
        case .failed: return nil
        }
    }

    var isChange: Bool {
        if case .changed = self { return true }
        return false
    }

    var scannedKeyToTrust: HostKeyScanner.Probe? {
        switch self {
        case .changed(let p), .notStored(let p): return p
        case .verified, .failed: return nil
        }
    }
}
