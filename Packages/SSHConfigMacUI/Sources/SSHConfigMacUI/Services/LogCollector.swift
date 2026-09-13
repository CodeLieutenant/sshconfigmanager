//
//  LogCollector.swift
//  sshconfigmanager
//
//  Pulls the app's own recent unified-logging entries back out of the system log
//  store so they can be attached to a bug report. Sandbox-safe: it uses
//  `OSLogStore(scope: .currentProcessIdentifier)`, which needs no special
//  entitlement and returns only *this app's current process* entries — it cannot
//  read other apps' logs or the system-wide store.
//
//  Caveat: `.currentProcessIdentifier` scope means entries from the *current run*
//  only. Logs from a previous launch (e.g. just before a crash) are not available
//  here — that history comes from MetricKit's crash payload instead. For an
//  in-session "Report a Bug", this captures everything since launch.
//

import Foundation
import OSLog

/// Gathers a redaction-aware text snapshot of the app's recent logs.
///
/// `nonisolated` on purpose: reading the store walks every entry synchronously, and
/// the log window tails it every two seconds, so callers must be able to run it off
/// the main actor. Nothing here holds state.
nonisolated enum LogCollector {
    /// A single rendered log line.
    struct Entry: Sendable {
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    /// Returns up to `maxEntries` of the app's own log entries from the last
    /// `since` seconds, newest-relevant first in chronological order, rendered as
    /// plain text. Returns a short marker string (never throws) if the log store is
    /// unavailable, so the caller can always produce *some* report.
    static func snapshot(
        since: TimeInterval = 3600,
        maxEntries: Int = 2000,
        maxCharacters: Int = 200_000
    ) -> String {
        let entries = collect(since: since, maxEntries: maxEntries)
        guard !entries.isEmpty else { return "(no log entries available for this session)" }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var text = ""
        // Render oldest→newest so the report reads like a transcript.
        for entry in entries {
            let line = "\(iso.string(from: entry.date)) [\(entry.level)] \(entry.category): \(entry.message)\n"
            text += line
            if text.count > maxCharacters {
                text = String(text.suffix(maxCharacters))
                text = "(…truncated to most recent \(maxCharacters) characters…)\n" + text
                break
            }
        }
        return text
    }

    /// Structured form, for callers that want to preview/count before sending.
    static func collect(since: TimeInterval = 3600, maxEntries: Int = 2000) -> [Entry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date(timeIntervalSinceNow: -since))
            // Filter to this app's subsystem; categories are all ours (see `Log`).
            let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
            let raw = try store.getEntries(at: start, matching: predicate)

            var out: [Entry] = []
            for case let entry as OSLogEntryLog in raw {
                out.append(
                    Entry(
                        date: entry.date,
                        category: entry.category,
                        level: levelString(entry.level),
                        message: entry.composedMessage))
            }
            // Keep the most recent `maxEntries`.
            if out.count > maxEntries { out = Array(out.suffix(maxEntries)) }
            return out
        } catch {
            Log.diagnostics.error("log snapshot failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "undefined"
        @unknown default: return "unknown"
        }
    }
}
