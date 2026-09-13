//
//  ScreenshotUITests.swift
//  sshconfigmanagerUITests
//
//  Captures RAW app-window screenshots by driving the *real* app. Launched by
//  `scripts/screenshots.sh`, which extracts the named PNG attachments from the
//  resulting .xcresult into `store-assets/raw/en-US/`. These are inputs, not the
//  finished article: `scripts/store-frames.sh` crops each window out and composes it
//  onto the captioned App Store canvas. Nothing here pads, resizes or annotates.
//
//  Launch flags (all DEBUG-only seams — see ScreenshotMode.swift):
//    --uitest-screenshot          seed a polished ~/.ssh, a running tunnel list, and a
//                                 deterministic ssh-agent identity list
//    --uitest-window-size 1440x900  pin the capture size (→ 2880x1800 px on Retina)
//
//  MUST be a SIGNED build (an unsigned XCUITest runner is killed before it connects).
//  Do NOT pass CODE_SIGNING_ALLOWED=NO. Needs an interactive GUI login session.
//
//  Whole-window shots use the pinned main window. The Add-Setting sheet is captured as
//  its own sheet element, at its own size — storeframes handles the difference.
//

import XCTest

final class ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        // Keep going after a single screen fails so one bad shot doesn't lose the rest.
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureAppStoreScreenshots() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest-screenshot",
            "--uitest-window-size", "1440x900",
            // Force en-US formatting. These are the en-US store captures, and on a Mac
            // set to a European locale the byte counters render "2,3 MB" instead of
            // "2.3 MB" — a detail that reads as a bug to an American shopper.
            "-AppleLanguages", "(en-US)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        // 1) Host detail / config editor (hero): select a seeded host so the detail
        //    editor is populated — this also serves as the "host itself" shot.
        //    (firstMatch: a favorited host appears in both Favorites and its group.)
        let host = app.descendants(matching: .any)["host-row-production-web"].firstMatch
        if host.waitForExistence(timeout: 20) { host.click() }
        settle()
        snapshot(app, named: "01-host-detail")

        // 2) Adding a setting to a host: open the keyword catalog sheet over the host.
        let addSetting = app.descendants(matching: .any)["add-setting"].firstMatch
        if addSetting.waitForExistence(timeout: 10) {
            addSetting.click()
            let sheet = app.sheets.firstMatch
            if sheet.waitForExistence(timeout: 10) {
                settle()
                snapshotElement(sheet, named: "02-add-setting")
            }
            app.typeKey(.escape, modifierFlags: []) // dismiss the sheet
            settle()
        }

        // 3) Groups: the sidebar is grouped (Production / Staging / Home / Personal)
        //    by the seed. Select a different host so this reads distinctly from #1.
        let bastion = app.descendants(matching: .any)["host-row-db-bastion"].firstMatch
        if bastion.waitForExistence(timeout: 10) { bastion.click() }
        settle()
        snapshot(app, named: "03-groups")

        // 4) Tunnels: seven seeded presets, three of them up and one reconnecting. The
        //    first is selected by default and carries a populated console + throughput.
        navigate(app, to: "sidebar-tunnels")
        settle()
        snapshot(app, named: "04-tunnels")

        // 5) Keys: the seeded healthy public keys.
        navigate(app, to: "sidebar-keys")
        snapshot(app, named: "05-keys")

        // 6) SSH agent.
        navigate(app, to: "sidebar-agent")
        snapshot(app, named: "06-agent")

        // 7) Known hosts.
        navigate(app, to: "sidebar-known-hosts")
        snapshot(app, named: "07-known-hosts")

        // 8) Version History: the git-style timeline of config changes. The
        //    HEAD version auto-selects; give the async diff a moment to render.
        navigate(app, to: "sidebar-history")
        settle()
        snapshot(app, named: "08-version-history")

        // The Settings window is deliberately NOT captured: a settings pane sells
        // nothing, and frames.json has no shot for it.
    }

    // MARK: - Helpers

    /// Clicks a sidebar destination by its accessibility identifier and settles.
    @MainActor
    private func navigate(_ app: XCUIApplication, to identifier: String) {
        let item = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(identifier) should exist")
        item.click()
        settle()
    }

    /// Lets a view finish rendering/animating before capture.
    @MainActor
    private func settle() { usleep(700_000) }

    /// Captures the main window (pinned to an exact frame → exact App Store size).
    @MainActor
    private func snapshot(_ app: XCUIApplication, named name: String) {
        let window = app.windows["main"].exists ? app.windows["main"] : app.windows.firstMatch
        attach(window.exists ? window.screenshot() : app.screenshot(), name: name)
    }

    /// Captures a specific window/sheet element (Settings, Help, the Add-Setting
    /// sheet). screenshots.sh normalizes these onto the main canvas.
    @MainActor
    private func snapshotElement(_ element: XCUIElement, named name: String) {
        attach(element.screenshot(), name: name)
    }

    @MainActor
    private func attach(_ shot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
