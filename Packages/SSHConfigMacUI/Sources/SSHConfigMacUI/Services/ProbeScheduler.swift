//
//  ProbeScheduler.swift
//  sshconfigmanager
//
//  Shared scheduling discipline for background TCP probes: a bounded concurrency
//  cap, pause-while-offline / asleep gating, and jittered (Low-Power-aware)
//  intervals — owning the single app-level NWPathMonitor + sleep/wake observers
//  so multiple probe consumers don't each wake the radio on their own schedule.
//
//  Today only the tunnel supervisor (TunnelStore) drives it; it's deliberately
//  engine-agnostic so a future ReachabilityMonitor shares the same instance →
//  one path monitor, one concurrency budget. See docs/plans/done/tunneling/monitor.md §6.
//

import AppKit
import Foundation
import Network

actor ProbeScheduler {
    /// The app-wide scheduler. Sharing one instance is the whole point: a single
    /// NWPathMonitor and one concurrency budget across every probe consumer.
    static let shared = ProbeScheduler()

    /// Connectivity / power transitions, fanned out to subscribers so they can
    /// re-arm promptly instead of waiting out a backoff.
    enum Signal: Sendable { case pathReturned, pathLost, didWake }

    private let maxConcurrent: Int
    private var inFlight = 0
    /// Waiters parked because the cap is full or probing is paused, keyed so a
    /// cancelled caller's own continuation can be found and resumed early
    /// (audit #29) without disturbing anyone else's.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Probing pauses while offline or asleep. Defaults to "satisfied" so the
    /// scheduler never blocks before the first NWPathMonitor callback arrives.
    private var pathSatisfied = true
    private var asleep = false
    private var paused: Bool { !pathSatisfied || asleep }

    private var pathMonitor: NWPathMonitor?
    private var started = false

    /// Multicast signal subscribers.
    private var signalContinuations: [UUID: AsyncStream<Signal>.Continuation] = [:]

    init(maxConcurrent: Int = 5) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    // MARK: - Lifecycle

    /// Begins observing connectivity and sleep/wake. Idempotent.
    nonisolated func start() {
        Task { await self.startObserving() }
    }

    private func startObserving() {
        guard !started else { return }
        started = true

        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.setPathSatisfied(satisfied) }
        }
        monitor.start(queue: .global(qos: .utility))

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.setAsleep(true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.handleWake() }
        }
    }

    // MARK: - Gating inputs

    private func setPathSatisfied(_ satisfied: Bool) {
        let was = pathSatisfied
        pathSatisfied = satisfied
        if satisfied && !was {
            resumeWaiters()
            broadcast(.pathReturned)
        } else if !satisfied && was {
            broadcast(.pathLost)
        }
    }

    private func setAsleep(_ value: Bool) {
        asleep = value
        if !value { resumeWaiters() }
    }

    private func handleWake() {
        asleep = false
        resumeWaiters()
        broadcast(.didWake)
    }

    var isPathSatisfied: Bool { pathSatisfied }

    #if DEBUG
        /// Test seam: simulate going offline (pauses `run`) / online (resumes it)
        /// without a live NWPathMonitor.
        func setPausedForTesting(_ value: Bool) { setPathSatisfied(!value) }
    #endif

    // MARK: - Bounded, gated execution

    /// Runs `work` once a probe slot is free and probing isn't paused. The cap and
    /// the pause gate are shared across all callers, so N tunnels + M hosts never
    /// open more than `maxConcurrent` sockets at once and all stop together offline.
    /// Runs `work` once a probe slot is free and probing isn't paused, or
    /// returns nil immediately if the calling task is cancelled while parked
    /// waiting for one (audit #29) — a cancelled caller used to sit blocked in
    /// `acquire` until a slot actually freed (up to the full offline/asleep
    /// pause, not just a probe timeout), ignoring cancellation entirely instead
    /// of returning promptly like every other cancellation-aware await point.
    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T? {
        guard await acquire() else { return nil }
        defer { release() }
        return await work()
    }

    /// Returns `true` once a slot is acquired, `false` if the caller was
    /// cancelled first.
    private func acquire() async -> Bool {
        // Park until there's both a free slot and an unpaused gate. Re-check after
        // each resume since several waiters may be woken for one freed slot.
        while paused || inFlight >= maxConcurrent {
            if Task.isCancelled { return false }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiters[id] = continuation
                }
            } onCancel: {
                // Runs off the actor (cancellation handlers aren't isolated) —
                // hop back on to touch `waiters` safely. A no-op if
                // `resumeWaiters()` already claimed this id first; a
                // `CheckedContinuation` only tolerates exactly one resume, so
                // whichever removes it from the dict first is the one that
                // actually resumes it.
                Task { await self.cancelWaiter(id) }
            }
            if Task.isCancelled { return false }
        }
        inFlight += 1
        return true
    }

    private func release() {
        inFlight -= 1
        resumeWaiters()
    }

    /// Wakes parked waiters; each re-checks its own condition in `acquire`.
    private func resumeWaiters() {
        guard !waiters.isEmpty else { return }
        let parked = waiters
        waiters.removeAll()
        for continuation in parked.values { continuation.resume() }
    }

    /// Resumes and removes one specific parked waiter, if it's still pending —
    /// see `resumeWaiters()`'s doc comment for why a double-resume can't happen.
    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    // MARK: - Cadence

    /// A poll interval with ±20% jitter (so many tunnels dropped by the same event
    /// don't re-probe in a synchronized burst), stretched ×3 under Low Power Mode.
    func interval(base: Duration) -> Duration {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let baseMillis = base.milliseconds * (lowPower ? 3 : 1)
        let jitter = Int64.random(in: -(baseMillis / 5)...(baseMillis / 5))
        return .milliseconds(max(0, baseMillis + jitter))
    }

    // MARK: - Signals (multicast)

    /// A fresh subscription to connectivity/wake transitions. The caller consumes
    /// it to re-arm degraded/failed work. The subscription ends when the returned
    /// stream's task is cancelled.
    func signals() -> AsyncStream<Signal> {
        AsyncStream { continuation in
            let id = UUID()
            signalContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSignalSubscriber(id) }
            }
        }
    }

    private func removeSignalSubscriber(_ id: UUID) {
        signalContinuations[id] = nil
    }

    private func broadcast(_ signal: Signal) {
        for continuation in signalContinuations.values { continuation.yield(signal) }
    }
}

extension Duration {
    /// Whole milliseconds (the components are seconds + attoseconds). `nonisolated`
    /// so the scheduler `actor` can read it off the main actor.
    fileprivate nonisolated var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
