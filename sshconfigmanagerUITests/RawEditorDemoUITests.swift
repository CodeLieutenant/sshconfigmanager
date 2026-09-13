//
//  RawEditorDemoUITests.swift
//  sshconfigmanagerUITests
//
//  Drives a paced walkthrough of the raw ssh_config editor — syntax highlighting
//  plus live IntelliSense completion — so `scripts/record-raw-demo.sh` can screen-
//  record it into an App Store preview clip. Not an assertion test: the deliberate
//  sleeps exist so the completion popup is visible on screen long enough to film.
//
//  Launch flags (DEBUG-only seams): --uitest-screenshot seeds a polished host and
//  --uitest-window-size pins a deterministic capture size.
//
//  Run via scripts/record-raw-demo.sh (signed build + GUI session required).
//

import XCTest

final class RawEditorDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testRawEditorIntelliSenseDemo() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest-screenshot",
            "--uitest-window-size", "1440x900",
        ]
        app.launch()
        // Give the external screen recorder a moment to find the window and start
        // capturing before anything happens on screen.
        beat(4.0)

        // Open a seeded host, then switch it into the raw editor.
        let host = app.descendants(matching: .any)["host-row-production-web"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 20))
        host.click()
        beat(1.0)

        let editRaw = app.descendants(matching: .any)["edit-raw"].firstMatch
        XCTAssertTrue(editRaw.waitForExistence(timeout: 10))
        editRaw.click()
        beat(1.2)

        // Focus the editor and move the caret to the end of the document.
        let editor = app.textViews["raw-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: .command)
        beat(0.8)

        // Each token is typed atomically (one typeText, not char-by-char) to avoid
        // racing the completion popup's main-thread work — the per-char race dropped
        // keystrokes and left the popup mid-layout. A long hold after each lets the
        // popup settle into place so the recording captures it cleanly.

        // 1) Keyword completion.
        typeToken(app, prefix: "\n    ", "Compr", hold: 2.6) // → Compression
        app.typeKey(.tab, modifierFlags: [])
        beat(0.6)
        // 2) Value completion (yes/no).
        typeToken(app, prefix: " ", "y", hold: 2.2) // → yes
        app.typeKey(.tab, modifierFlags: [])
        beat(0.6)
        // 3) Keyword + algorithm-value completion (the richest list).
        typeToken(app, prefix: "\n    ", "Ciph", hold: 2.2) // → Ciphers
        app.typeKey(.tab, modifierFlags: [])
        typeToken(app, prefix: " ", "aes", hold: 2.8) // → aes256-gcm@openssh.com, …
        app.typeKey(.tab, modifierFlags: [])
        beat(0.6)
        // 4) One more keyword to leave the result full + highlighted.
        typeToken(app, prefix: "\n    ", "ServerAl", hold: 2.2) // → ServerAliveInterval
        app.typeKey(.tab, modifierFlags: [])
        type(app, " 60")
        beat(2.5) // final hold
    }

    // MARK: - Helpers

    /// Types a string in one shot.
    @MainActor private func type(_ app: XCUIApplication, _ s: String) {
        app.typeText(s)
    }

    /// Types `prefix` (indent/space) then `token` atomically, then holds so the
    /// completion popup settles into a stable, fully-rendered state for the camera.
    @MainActor private func typeToken(
        _ app: XCUIApplication, prefix: String,
        _ token: String, hold: Double
    ) {
        type(app, prefix)
        beat(0.5) // let the new line/whitespace commit before the token
        type(app, token)
        beat(hold)
    }

    /// A filming pause.
    @MainActor private func beat(_ seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}
