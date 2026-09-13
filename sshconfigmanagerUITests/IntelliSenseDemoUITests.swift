//
//  IntelliSenseDemoUITests.swift
//  sshconfigmanagerUITests
//
//  App Store preview video: IntelliSense / code-completion showcase.
//  Covers all completion kinds in ~26 s: snippet (LocalForward template),
//  keyword (Compression), enum value (yes/no), ProxyJump + host alias from
//  the document, and cipher algorithm list (aes256-gcm@openssh.com).
//
//  Run via scripts/record-intellisense-demo.sh (signed build + GUI session required).
//
//  Launch flags:
//    --uitest-screenshot   seed a polished ~/.ssh fixture so the host list is full
//    --uitest-window-size  pin capture size (→ 2880×1800 px on Retina)
//

import XCTest

final class IntelliSenseDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testIntelliSenseDemoWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest-screenshot",
            "--uitest-window-size", "1440x900",
        ]
        app.launch()

        // 0–2 s: sidebar is visible with seeded host groups.
        beat(2.0)

        // 2–4 s: click the production-web host → detail pane populates.
        let host = app.descendants(matching: .any)["host-row-production-web"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 20), "seeded host row must exist")
        host.click()
        beat(2.0)

        // 4–5 s: open the raw editor for this host block.
        let editRaw = app.descendants(matching: .any)["edit-raw"].firstMatch
        guard editRaw.waitForExistence(timeout: 5) else {
            XCTFail("edit-raw button not found")
            beat(15.0)
            return
        }
        editRaw.click()
        beat(0.8)

        let editor = app.textViews["raw-editor"].firstMatch
        guard editor.waitForExistence(timeout: 5) else {
            XCTFail("raw-editor not found")
            beat(15.0)
            return
        }
        editor.click()
        // Cursor to end of block so typed text appends cleanly.
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: .command)
        beat(0.4)

        // ── Phase 1: Snippet — LocalForward template ──────────────────────────
        // "LocalF" triggers the snippet; popup shows the full template + docs.
        app.typeText("\n    LocalF")
        beat(2.5) // camera dwells on the snippet popup
        app.typeKey(.tab, modifierFlags: [])
        beat(1.0) // show the inserted template

        // ── Phase 2: Keyword → enum value (Compression yes/no) ───────────────
        app.typeText("\n    Compr")
        beat(2.5) // popup: "Compression" keyword + yes/no hint
        app.typeKey(.tab, modifierFlags: [])
        app.typeText(" y")
        beat(2.0) // popup: yes / no enum choices
        app.typeKey(.tab, modifierFlags: [])
        beat(0.5)

        // ── Phase 3: Keyword → host alias (ProxyJump + db-bastion) ───────────
        app.typeText("\n    ProxyJ")
        beat(2.0) // popup: "ProxyJump" keyword
        app.typeKey(.tab, modifierFlags: [])
        app.typeText(" db")
        beat(2.5) // popup: host aliases containing "db"
        app.typeKey(.tab, modifierFlags: [])
        beat(0.5)

        // ── Phase 4: Keyword → algorithm list (Ciphers aes256-gcm) ──────────
        app.typeText("\n    Ciph")
        beat(2.0) // popup: "Ciphers" keyword
        app.typeKey(.tab, modifierFlags: [])
        app.typeText(" aes256")
        beat(2.5) // hold: rich cipher algorithm list
        app.typeKey(.tab, modifierFlags: [])
        beat(1.5) // final shot: accepted cipher in context

        // Keep the app alive until screencapture's -V window expires.
        beat(15.0)
    }

    @MainActor
    private func beat(_ seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}
