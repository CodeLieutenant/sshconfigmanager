//
//  AppPreviewDemoUITests.swift
//  sshconfigmanagerUITests
//
//  Full-feature cinematic walkthrough for the App Store preview video.
//  Apple hard-clamps Mac previews to the FIRST 29 s of raw footage — the
//  encode step truncates, it does not retime — and real on-screen pacing
//  runs well behind the sum of this file's `beat()` calls (window-open
//  waits, click latency, sheet animations). So the three features that
//  matter most — search, SSH key generation, known-hosts verify — run
//  FIRST, guaranteeing they survive the clamp. Host detail, add-setting,
//  SSH agent, and version history are bonus material appended after: nice
//  to have, not guaranteed to make the final cut.
//
//  Tunnels and the raw-editor IntelliSense completions each have their own
//  dedicated preview video (TunnelDemoUITests / IntelliSenseDemoUITests) —
//  deliberately NOT duplicated here.
//
//  Run via scripts/record-preview.sh (signed build + GUI session required).
//  The script drives screencapture -v -l<winid> so only the app window is
//  captured — no desktop, no "Automation Running" overlay — then encodes
//  down to the App Store spec (1920×1080) regardless of the window's native
//  (Retina) capture resolution.
//
//  Launch flags (DEBUG-only seams):
//    --uitest-screenshot   seed a polished ~/.ssh + a sample tunnel preset
//    --uitest-window-size  pin the capture size (native window points, not output px)
//

import XCTest

final class AppPreviewDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testFullFeaturePreviewWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest-screenshot",
            "--uitest-window-size", "1440x900",
        ]
        app.launch()

        // 0–2 s: sidebar with host groups is visible. Gives screencapture time to
        // find the window ID and start capturing before anything moves on screen.
        beat(2.0)

        // Search — filter the host list, then clear it. First among the
        // must-show features so it always survives the App Store 29 s clamp.
        let search = app.textFields["sidebar-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "sidebar search field must exist")
        search.click()
        app.typeText("prod")
        beat(1.3) // hold on the filtered results
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        beat(0.3)

        // SSH key generation — the default file name collides with a seeded key,
        // so the demo also shows renaming it before Generate lights up.
        navigate(app, to: "sidebar-keys", hold: 0.6)
        let generateButton = app.descendants(matching: .any)["generate-key-button"].firstMatch
        if generateButton.waitForExistence(timeout: 5) {
            generateButton.click()
            let fileNameField = app.textFields["key-filename-field"].firstMatch
            if fileNameField.waitForExistence(timeout: 5) {
                beat(0.5)
                fileNameField.click()
                app.typeKey("a", modifierFlags: .command)
                app.typeText("id_ed25519_demo")
                beat(0.8)
                let confirm = app.descendants(matching: .any)["generate-key-confirm-button"].firstMatch
                if confirm.waitForExistence(timeout: 5) {
                    confirm.click()
                    beat(1.8) // new key settles into the list
                }
            }
        }

        // Known hosts — select the seeded db-bastion entry to show its trusted
        // key detail. Deliberately not github.com: HostKeyMonitor auto-checks
        // the selected host in the background, and github.com is a REAL,
        // reachable server — it will always disagree with this fixture's fake
        // seeded fingerprint and throw up a scary "Host key CHANGED" warning,
        // the wrong impression for a marketing video. db-bastion's hostname
        // isn't real, so the same background check just reports "Unreachable"
        // (neutral) instead of a false compromise alert.
        navigate(app, to: "sidebar-known-hosts", hold: 0.8)
        let knownHostRow = app.descendants(matching: .any)["known-host-row-db-bastion"].firstMatch
        if knownHostRow.waitForExistence(timeout: 5) {
            knownHostRow.click()
            beat(2.2) // hold on the trusted-key detail
        }

        // ── Bonus material below: included if time allows, but not guaranteed
        // to survive the 29 s clamp. ────────────────────────────────────────

        // Host detail.
        let host = app.descendants(matching: .any)["host-row-production-web"].firstMatch
        if host.waitForExistence(timeout: 5) {
            host.click()
            beat(1.2)
        }

        // Add-setting keyword catalog.
        let addSetting = app.descendants(matching: .any)["add-setting"].firstMatch
        if addSetting.waitForExistence(timeout: 3) {
            addSetting.click()
            let sheet = app.descendants(matching: .any)["add-setting-sheet"].firstMatch
            _ = sheet.waitForExistence(timeout: 3)
            beat(1.2)
            app.typeKey(.escape, modifierFlags: [])
            beat(0.3)
        }

        // SSH agent.
        navigate(app, to: "sidebar-agent", hold: 1.0)

        // Version history timeline.
        navigate(app, to: "sidebar-history", hold: 1.5)

        // Keep the app alive until screencapture's -V window expires. Without this
        // tail, xcodebuild kills the app when the test function returns (~28 s), the
        // window disappears mid-recording, and screencapture writes corrupted frames
        // for the remainder of its capture window. 15 s of idle is more than enough
        // buffer for any RECORD_SECONDS value up to 45 s.
        beat(15.0)
    }

    // MARK: - Helpers

    @MainActor
    private func navigate(_ app: XCUIApplication, to identifier: String, hold: Double) {
        let item = app.descendants(matching: .any)[identifier].firstMatch
        guard item.waitForExistence(timeout: 10) else {
            XCTFail("\(identifier) never appeared")
            return
        }
        item.click()
        beat(hold)
    }

    @MainActor
    private func beat(_ seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}
