//
//  ConfigFileWatcherTests.swift
//  sshconfigmanagerTests
//
//  The single-kqueue file watcher: real files, real kernel events, a short
//  debounce so the suite stays fast. Polls with a generous timeout rather than a
//  fixed sleep, since kqueue delivery + debounce timing isn't instantaneous.
//

import Foundation
import Testing

@testable import SSHConfigMacUI

@MainActor
struct ConfigFileWatcherTests {
    private actor Signal {
        private(set) var fireCount = 0
        func fire() { fireCount += 1 }
    }

    /// Tracks which of several concurrently-watched files fired, for the
    /// many-files-on-one-kqueue test.
    private actor FiredIndices {
        private(set) var indices: Set<Int> = []
        func mark(_ i: Int) { indices.insert(i) }
    }

    /// Polls `condition` until it's true or `timeout` elapses. Returns whether it
    /// became true in time — real filesystem + kqueue + debounce timing isn't
    /// synchronous, so tests wait rather than assert immediately.
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private func makeFile(in dir: URL, named name: String = "config", contents: String = "one\n") -> URL {
        let url = dir.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Appends in place (same inode, no rename) — the shape of an editor's
    /// non-atomic save, or ssh appending a trusted host key to `known_hosts`.
    /// Distinct from `makeFile`'s atomic write, which replaces the inode.
    private func appendInPlace(_ url: URL, _ text: String) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfw-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writingAWatchedFileFiresOnChange() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await signal.fire() } }

        try? "two\n".write(to: url, atomically: true, encoding: .utf8)

        let fired = await waitUntil { await signal.fireCount > 0 }
        #expect(fired)
        watcher.removeAll()
    }

    /// The atomic-replace save pattern (write a temp file, rename it over the
    /// original) many editors use — the watched inode goes away, so the watcher
    /// has to re-open the same path under a fresh fd to keep following it.
    @Test func atomicReplaceSaveKeepsWatching() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await signal.fire() } }

        let tmp = dir.appendingPathComponent("config.tmp")
        try? "replaced\n".write(to: tmp, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)

        let firedAfterReplace = await waitUntil { await signal.fireCount > 0 }
        #expect(firedAfterReplace)

        // The watch must have survived the replace under a fresh fd: a second,
        // ordinary write to the (new) file still fires.
        let countAfterReplace = await signal.fireCount
        try? "replaced again\n".write(to: url, atomically: true, encoding: .utf8)
        let firedAgain = await waitUntil { await signal.fireCount > countAfterReplace }
        #expect(firedAgain)
        watcher.removeAll()
    }

    @Test func removeStopsFurtherNotifications() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await signal.fire() } }
        watcher.remove(url: url)

        try? "changed\n".write(to: url, atomically: true, encoding: .utf8)

        // Give the kernel/debounce every chance to fire before asserting silence.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await signal.fireCount == 0)
        watcher.removeAll()
    }

    /// Two files sharing the one kqueue must stay independent — writing one
    /// doesn't fire the other's callback.
    @Test func eachWatchedFileGetsItsOwnCallback() async {
        let dir = tempDirectory()
        let urlA = makeFile(in: dir, named: "a")
        let urlB = makeFile(in: dir, named: "b")
        let signalA = Signal()
        let signalB = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: urlA) { Task { await signalA.fire() } }
        watcher.add(url: urlB) { Task { await signalB.fire() } }

        try? "changed\n".write(to: urlA, atomically: true, encoding: .utf8)

        let firedA = await waitUntil { await signalA.fireCount > 0 }
        #expect(firedA)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await signalB.fireCount == 0)
        watcher.removeAll()
    }

    /// Watching a path that doesn't exist yet is a silent no-op, not a crash —
    /// callers (like `ConfigStore`, for a document that hasn't been written) retry
    /// by calling `add` again later.
    @Test func addingNonexistentFileIsANoop() async {
        let dir = tempDirectory()
        let missing = dir.appendingPathComponent("does-not-exist")
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: missing) { Task { await signal.fire() } }

        try? await Task.sleep(for: .milliseconds(200))
        #expect(await signal.fireCount == 0)
        watcher.removeAll()
    }

    /// Re-adding a URL replaces its watch rather than stacking a second one — a
    /// second `add` call for the same URL should still fire its (new) callback
    /// exactly like a fresh watch, not double-fire or leak the old fd.
    @Test func readdingSameURLReplacesTheWatch() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let firstSignal = Signal()
        let secondSignal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await firstSignal.fire() } }
        watcher.add(url: url) { Task { await secondSignal.fire() } }

        try? "changed\n".write(to: url, atomically: true, encoding: .utf8)

        let fired = await waitUntil { await secondSignal.fireCount > 0 }
        #expect(fired)
        #expect(await firstSignal.fireCount == 0)
        watcher.removeAll()
    }

    /// The whole point of debouncing: several in-place writes to the same file
    /// inside the debounce window must collapse into exactly one callback, not
    /// one per kernel event.
    @Test func rapidWritesToSameFileDebounceToOneCall() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(200))
        watcher.add(url: url) { Task { await signal.fire() } }

        for i in 0..<5 {
            appendInPlace(url, "write \(i)\n")
            try? await Task.sleep(for: .milliseconds(10))
        }

        // The last write was well inside the debounce window each time (10ms
        // gaps vs a 200ms window) — give it a comfortable margin to settle into
        // a single flush before asserting the count.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await signal.fireCount == 1)
        watcher.removeAll()
    }

    /// Two distinct files changing inside the same debounce window must still
    /// each fire their own callback exactly once — the per-URL `pending` dict
    /// dedupes repeats of the *same* file without swallowing a *different* one.
    @Test func changesToDifferentFilesInSameWindowEachFireExactlyOnce() async {
        let dir = tempDirectory()
        let urlA = makeFile(in: dir, named: "a")
        let urlB = makeFile(in: dir, named: "b")
        let signalA = Signal()
        let signalB = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(200))
        watcher.add(url: urlA) { Task { await signalA.fire() } }
        watcher.add(url: urlB) { Task { await signalB.fire() } }

        appendInPlace(urlA, "x")
        try? await Task.sleep(for: .milliseconds(10))
        appendInPlace(urlB, "y")

        let firedBoth = await waitUntil {
            let a = await signalA.fireCount
            let b = await signalB.fireCount
            return a > 0 && b > 0
        }
        #expect(firedBoth)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await signalA.fireCount == 1)
        #expect(await signalB.fireCount == 1)
        watcher.removeAll()
    }

    /// A genuine delete (no replacement) fires once; the watcher then keeps
    /// polling in the background to reopen (audit #28) rather than dying
    /// permanently after the first failed attempt — recreating the path resumes
    /// it with no explicit re-`add` needed, matching what
    /// `ConfigStore.updateFileWatchers()` assumes (it only re-`add`s a URL that
    /// dropped out of the document graph and came back, not one that's still
    /// current but silently went dead underneath it).
    @Test func genuineDeleteFiresThenAutomaticallyResumesOnceRecreated() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await signal.fire() } }

        try? FileManager.default.removeItem(at: url)

        let firedOnDelete = await waitUntil { await signal.fireCount > 0 }
        #expect(firedOnDelete)
        let countAfterDelete = await signal.fireCount

        try? "recreated\n".write(to: url, atomically: true, encoding: .utf8)
        // The recreation write itself may or may not land inside the retry's
        // reopen window (that race is exactly why this polls rather than
        // asserting immediately) — give it a moment, then confirm the watch
        // has resumed via a definite follow-up write.
        try? await Task.sleep(for: .milliseconds(300))
        appendInPlace(url, "changed again\n")
        let resumed = await waitUntil(timeout: .seconds(5)) { await signal.fireCount > countAfterDelete }
        #expect(resumed)
        watcher.removeAll()
    }

    /// The vim-style save this fix specifically targets: the original is
    /// renamed aside (not deleted outright), leaving a real — if brief — window
    /// where nothing exists at the original path before the new file lands
    /// there. A single failed reopen attempt inside that window used to kill
    /// the watch forever; it must instead recover on its own (audit #28).
    @Test func renameAsideThenRecreateResumesWatching() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await signal.fire() } }

        let asideURL = dir.appendingPathComponent("config.orig")
        try? FileManager.default.moveItem(at: url, to: asideURL)
        // A real gap before the new file reappears at the original path.
        try? await Task.sleep(for: .milliseconds(80))
        try? "new content\n".write(to: url, atomically: true, encoding: .utf8)

        // Keep touching the file, spaced well past the 50ms debounce window,
        // until a write lands after the retry loop has actually resumed the
        // watch — a single append immediately after recreating the file could
        // race a reopen attempt still in flight. (Polling faster than the
        // debounce window would keep re-arming it and never let a write
        // settle into a fired callback at all.)
        let countBeforeFollowUp = await signal.fireCount
        var resumed = false
        for _ in 0..<20 {
            appendInPlace(url, "changed again\n")
            try? await Task.sleep(for: .milliseconds(250))
            if await signal.fireCount > countBeforeFollowUp {
                resumed = true
                break
            }
        }
        #expect(resumed)
        watcher.removeAll()
    }

    /// The core point of this design: many files multiplexed onto one kqueue,
    /// not one kqueue-backed dispatch source per file. Watches a config-sized
    /// batch of files and confirms writing a handful fires exactly those
    /// callbacks — no cross-talk, no missed events at this fd count.
    @Test func manyFilesCanBeWatchedOnOneKqueueWithoutCrossTalk() async {
        let dir = tempDirectory()
        let fileCount = 64
        var urls: [URL] = []
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        let fired = FiredIndices()

        for i in 0..<fileCount {
            let url = makeFile(in: dir, named: "included-\(i)")
            urls.append(url)
            watcher.add(url: url) { Task { await fired.mark(i) } }
        }

        let changedIndices: Set<Int> = [0, 10, 20, 30, 40, 50, 60]
        for i in changedIndices { appendInPlace(urls[i], "changed\n") }

        let done = await waitUntil(timeout: .seconds(3)) { await fired.indices.count >= changedIndices.count }
        #expect(done)
        #expect(await fired.indices == changedIndices)
        watcher.removeAll()
    }

    /// `removeAll()` tears down the shared kqueue itself, not just the
    /// individual watches — a fresh `add` afterward must recreate it rather than
    /// silently doing nothing.
    @Test func removeAllThenAddWorksAgain() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await signal.fire() } }
        watcher.removeAll()

        watcher.add(url: url) { Task { await signal.fire() } }
        appendInPlace(url, "changed\n")

        let fired = await waitUntil { await signal.fireCount > 0 }
        #expect(fired)
        watcher.removeAll()
    }

    @Test func removingUnwatchedURLIsANoop() {
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        let url = tempDirectory().appendingPathComponent("never-watched")
        watcher.remove(url: url)
        watcher.removeAll()
    }

    /// Simulates ssh appending a newly-trusted host key to `known_hosts`: an
    /// in-place append, not an atomic replace — must be caught by
    /// `NOTE_WRITE`/`NOTE_EXTEND` alone, with no delete/rename involved.
    @Test func appendOnlyWriteFires() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir)
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await signal.fire() } }

        appendInPlace(url, "appended-host-key\n")

        let fired = await waitUntil { await signal.fireCount > 0 }
        #expect(fired)
        watcher.removeAll()
    }

    /// A truncate (same inode, no rename/delete — e.g. a tool zeroing the file
    /// before rewriting it) is a plain `NOTE_WRITE` and must fire like any other
    /// in-place modification.
    @Test func truncatingToEmptyStillFires() async {
        let dir = tempDirectory()
        let url = makeFile(in: dir, contents: "some content\n")
        let signal = Signal()
        let watcher = ConfigFileWatcher(debounce: .milliseconds(50))
        watcher.add(url: url) { Task { await signal.fire() } }

        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        }

        let fired = await waitUntil { await signal.fireCount > 0 }
        #expect(fired)
        watcher.removeAll()
    }
}
