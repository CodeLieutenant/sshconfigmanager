//
//  ConfigFileWatcher.swift
//  SSHConfigMacUI
//
//  Watches many files for external changes through a single kqueue, rather than
//  one kqueue-backed DispatchSourceFileSystemObject (one open fd, one dispatch
//  source, one debounce Task) per file. `ConfigStore` needs a watch per document
//  in the config graph — every `Include`d file — plus one for `known_hosts`; with
//  the previous design that meant N independent kernel event sources for a config
//  that splits across N files. Here there is exactly one kqueue fd and one
//  `DispatchSourceRead` draining it; each watched path still needs its own open fd
//  (there's no way to ask kqueue to watch a path without a handle to it), but
//  registering that fd's `EVFILT_VNODE` events onto the shared kqueue is all that
//  costs per additional file — no extra dispatch source, no extra debounce timer.
//
//  A kqueue descriptor is itself pollable (see kqueue(2): "kqueue descriptors may
//  be monitored for readiness using select(2), poll(2), or another kqueue(2)"), so
//  wrapping it in a plain `DispatchSource.makeReadSource` and draining pending
//  events with a zero-timeout `kevent()` call on each fire is the standard way to
//  fold a kqueue into an existing run loop / dispatch-based app without a second
//  thread.
//
//  Handles the atomic-replace save pattern many editors and tools use (write a
//  temp file, then rename it over the original) by re-opening the watch on
//  `NOTE_DELETE`/`NOTE_RENAME` (under a fresh fd, since the old one now points at
//  an unlinked inode); a plain in-place write (e.g. ssh appending a newly-trusted
//  host key to `known_hosts`) is caught by `NOTE_WRITE`/`NOTE_EXTEND` alone.
//
//  Scheduled on the main queue, which is the same executor MainActor uses, so the
//  event handler re-enters isolation with `MainActor.assumeIsolated` rather than
//  hopping through a `Task` (see `AppDelegate.appearanceObservation` for the same
//  bridge over a KVO callback). The class itself is `@MainActor` so the debounce
//  `Task` in `scheduleFire()` inherits that isolation instead of running on the
//  global concurrent executor.
//

import Darwin
import Foundation

/// A reference to the raw `kevent(2)` syscall, captured as a value rather than
/// called bare. `Darwin` exports both a `kevent` function and a `kevent` struct;
/// calling `kevent(...)` directly makes the compiler consider the struct's
/// memberwise initializer as a candidate overload too (and it wins arity-based
/// resolution, producing "missing argument labels" errors), so the syscall is
/// captured through this unlabeled function value instead — the same workaround
/// SwiftNIO's kqueue backend uses (`NIOPosix/System.swift`'s `sysKevent`).
private let sysKevent = kevent

@MainActor
final class ConfigFileWatcher {
    private struct Watch {
        let url: URL
        let onChange: () -> Void
    }

    private let debounce: Duration

    private var kq: Int32 = -1
    private var readSource: DispatchSourceRead?
    /// Keyed by the currently-open fd for that URL — kqueue events arrive with
    /// `ident == fd`, and a delete/rename recovery swaps the fd (and this key) in
    /// place while the URL keeps its single logical watch.
    private var watchesByFD: [Int32: Watch] = [:]
    private var fdByURL: [URL: Int32] = [:]

    /// Callbacks queued by `drain()` since the last flush, keyed by URL so a file
    /// that fires more than once inside the debounce window still calls its
    /// handler exactly once per flush.
    private var pending: [URL: () -> Void] = [:]
    private var debounceTask: Task<Void, Never>?
    /// Polling for a URL whose delete/rename reopen (see `drain()`) failed
    /// because the path was momentarily gone — e.g. vim renames the original
    /// aside before writing the new file (audit #28). One entry per URL; a
    /// fresh `add`/`remove` cancels it so a stale retry can't re-arm a watch
    /// the caller has since replaced or torn down.
    private var reopenRetryTasks: [URL: Task<Void, Never>] = [:]

    init(debounce: Duration = .milliseconds(400)) {
        self.debounce = debounce
    }

    deinit {
        for task in reopenRetryTasks.values { task.cancel() }
        for fd in watchesByFD.keys { close(fd) }
        // `cancel()` closes `kq` itself, asynchronously, via the cancel handler
        // installed in `ensureQueue()` — closing it again here would race that
        // handler and risk closing whatever fd the OS has since reused this
        // number for.
        readSource?.cancel()
    }

    /// Starts (or replaces) a watch on `url`, invoking `onChange` (debounced, on
    /// the main actor) whenever the kernel reports it changed. A no-op if `url`
    /// doesn't exist yet — callers that create the file on demand should call
    /// `add` again once it's written.
    func add(url: URL, onChange: @escaping () -> Void) {
        remove(url: url)
        guard let fd = openAndRegister(url: url, onChange: onChange) else { return }
        fdByURL[url] = fd
    }

    /// Stops watching `url`. A no-op if it isn't currently watched.
    func remove(url: URL) {
        reopenRetryTasks.removeValue(forKey: url)?.cancel()
        guard let fd = fdByURL.removeValue(forKey: url) else { return }
        unregisterAndClose(fd: fd)
        pending.removeValue(forKey: url)
    }

    /// Stops watching every URL and tears down the shared kqueue itself.
    func removeAll() {
        for task in reopenRetryTasks.values { task.cancel() }
        reopenRetryTasks.removeAll()
        for fd in watchesByFD.keys { close(fd) }
        watchesByFD.removeAll()
        fdByURL.removeAll()
        // `cancel()` closes `kq` asynchronously via the cancel handler installed
        // in `ensureQueue()`. Clearing `kq` to -1 here (rather than closing it
        // ourselves) is what lets a subsequent `add()` create a genuinely fresh
        // kqueue instead of racing that handler's close against a reused fd
        // number — see the same reasoning in `deinit`.
        readSource?.cancel()
        readSource = nil
        kq = -1
        debounceTask?.cancel()
        debounceTask = nil
        pending.removeAll()
    }

    // MARK: - kqueue plumbing

    private func ensureQueue() -> Bool {
        if kq >= 0 { return true }
        let newQueue = kqueue()
        guard newQueue >= 0 else { return false }
        let source = DispatchSource.makeReadSource(fileDescriptor: newQueue, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        source.setCancelHandler { close(newQueue) }
        source.resume()
        kq = newQueue
        readSource = source
        return true
    }

    @discardableResult
    private func openAndRegister(url: URL, onChange: @escaping () -> Void) -> Int32? {
        guard ensureQueue() else { return nil }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        // NOTE_ATTRIB matters here specifically for a bare truncate: ftruncate()
        // delivers NOTE_ATTRIB, not NOTE_WRITE (verified empirically — a
        // truncate-to-empty with no following write is otherwise invisible to
        // this watch, since it changes the vnode's size/attributes without a
        // write() call).
        var event = kevent(
            ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_EXTEND | NOTE_ATTRIB),
            data: 0, udata: nil)
        guard sysKevent(kq, &event, 1, nil, 0, nil) == 0 else {
            close(fd)
            return nil
        }
        watchesByFD[fd] = Watch(url: url, onChange: onChange)
        return fd
    }

    /// Clears the kernel's registration for `fd` and closes it. Closing is what
    /// actually releases the watch — the kqueue keeps a reference to a registered
    /// fd until it's closed, `EV_DELETE` alone isn't enough — but detaching first
    /// keeps a close-in-flight fd from delivering a stray event during teardown.
    private func unregisterAndClose(fd: Int32) {
        var event = kevent(
            ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_DELETE),
            fflags: 0, data: 0, udata: nil)
        _ = sysKevent(kq, &event, 1, nil, 0, nil)
        watchesByFD.removeValue(forKey: fd)
        close(fd)
    }

    /// Drains every pending event off the kqueue in one pass (a zero-timeout
    /// `kevent()` call, so it never blocks). An atomic-replace save (temp file
    /// renamed over the original) shows up as `NOTE_DELETE`/`NOTE_RENAME` on the
    /// old fd — re-open the same path under a fresh fd so the watch survives the
    /// replace, exactly once per file rather than each watched file independently
    /// reimplementing the recovery.
    private func drain() {
        guard kq >= 0 else { return }
        // `[kevent](repeating:count:)` sugar is ambiguous here for the same reason
        // `sysKevent` exists above — `[kevent]` alone can parse as a one-element
        // array *literal* of the function value rather than the `Array<kevent>`
        // type — so the generic form is spelled out explicitly instead.
        // swift-format-ignore: UseShorthandTypeNames
        var events = Array<kevent>(repeating: kevent(), count: 32)
        var firedThisPass = false
        while true {
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let n = events.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return sysKevent(kq, nil, 0, base, Int32(buffer.count), &timeout)
            }
            guard n > 0 else { break }
            firedThisPass = true
            for i in 0..<Int(n) {
                let event = events[i]
                let fd = Int32(event.ident)
                guard let watch = watchesByFD[fd] else { continue }
                if event.fflags & (UInt32(NOTE_DELETE) | UInt32(NOTE_RENAME)) != 0 {
                    unregisterAndClose(fd: fd)
                    if let newFD = openAndRegister(url: watch.url, onChange: watch.onChange) {
                        fdByURL[watch.url] = newFD
                    } else {
                        // The path is momentarily gone — e.g. vim renames the
                        // original aside before writing the new file, so `open()`
                        // races a real (if brief) window with nothing there. A
                        // single failed attempt used to drop the watch forever
                        // (audit #28): `ConfigStore.updateFileWatchers()` still
                        // believes this URL is watched, so nothing else would
                        // ever retry. Poll instead of giving up.
                        fdByURL.removeValue(forKey: watch.url)
                        scheduleReopenRetry(url: watch.url, onChange: watch.onChange)
                    }
                }
                pending[watch.url] = watch.onChange
            }
            if Int(n) < events.count { break }
        }
        guard firedThisPass, !pending.isEmpty else { return }
        scheduleFire()
    }

    /// Polls for `url` to reappear after a failed delete/rename reopen,
    /// re-arming the watch the moment it does (audit #28). Exponential backoff
    /// capped at 2s — retried indefinitely, not a bounded attempt count, since a
    /// deleted config file (or a not-yet-created `known_hosts`) may legitimately
    /// reappear at any point while the app keeps running.
    private func scheduleReopenRetry(url: URL, onChange: @escaping () -> Void) {
        reopenRetryTasks[url]?.cancel()
        reopenRetryTasks[url] = Task { [weak self] in
            var delayMilliseconds = 50
            let capMilliseconds = 2000
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                guard !Task.isCancelled, let self else { return }
                if let newFD = self.openAndRegister(url: url, onChange: onChange) {
                    self.fdByURL[url] = newFD
                    self.reopenRetryTasks.removeValue(forKey: url)
                    return
                }
                delayMilliseconds = min(delayMilliseconds * 2, capMilliseconds)
            }
        }
    }

    private func scheduleFire() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let debounce = self?.debounce else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            let callbacks = self.pending
            self.pending.removeAll()
            for callback in callbacks.values { callback() }
        }
    }
}
