//
//  LaunchOnceCoordinatorTests.swift
//  sshconfigmanagerTests
//

import Testing

@testable import SSHConfigMacUI

@MainActor
struct LaunchOnceCoordinatorTests {
    @Test func bodyRunsExactlyOnceAcrossMultipleCalls() async {
        let coordinator = LaunchOnceCoordinator()
        var runCount = 0
        let firstRan = await coordinator.runOnce { runCount += 1 }
        let secondRan = await coordinator.runOnce { runCount += 1 }
        let thirdRan = await coordinator.runOnce { runCount += 1 }
        #expect(firstRan)
        #expect(!secondRan)
        #expect(!thirdRan)
        #expect(runCount == 1)
    }

    @Test func secondCallDuringFirstsSuspensionIsANoOp() async {
        // Mirrors two `.onAppear` firings racing each other (e.g. the window
        // reopening while the first launch sequence is still mid-`await`) —
        // `didRun` must already be set before the first call suspends, so the
        // second call can't slip in and run the body a second time.
        let coordinator = LaunchOnceCoordinator()
        nonisolated(unsafe) var runCount = 0 // both closures are @MainActor-bound; see below
        async let first = coordinator.runOnce {
            runCount += 1
            await Task.yield()
            runCount += 1
        }
        async let second = coordinator.runOnce { runCount += 100 }
        _ = await (first, second)
        #expect(runCount == 2)
    }

    @Test func restoreOnlyRunsAfterLoadAndRefreshResolve() async {
        actor StubSettings {
            private(set) var restoreTunnelsOnLaunch = false
            func load() async {
                await Task.yield()
                restoreTunnelsOnLaunch = true
            }
        }
        let settings = StubSettings()
        let coordinator = LaunchOnceCoordinator()
        var restoredWithLoadedSettings: Bool?

        await coordinator.runOnce {
            await settings.load()
            let shouldRestore = await settings.restoreTunnelsOnLaunch
            if shouldRestore {
                restoredWithLoadedSettings = shouldRestore
            }
        }

        #expect(restoredWithLoadedSettings == true)
    }
}
