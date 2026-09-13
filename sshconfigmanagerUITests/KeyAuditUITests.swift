//
//  KeyAuditUITests.swift
//  sshconfigmanagerUITests
//
//  End-to-end UI tests for the key health audit, driving the *real* app: launch
//  with `--uitest-seed-keys` (the app seeds a fixture ~/.ssh inside its own sandbox
//  temp), open the Issues screen, and exercise the action buttons whose closures
//  unit tests can't reach — Fix permissions, orphaned-key Delete (with
//  confirmation), and Generate Replacement.
//
//  HOW TO RUN — must be a SIGNED build (an unsigned XCUITest runner is killed before
//  it can connect: "signal kill before establishing connection"). Do NOT pass
//  CODE_SIGNING_ALLOWED=NO here. Needs an interactive GUI login session and an Apple
//  account in Xcode (for -allowProvisioningUpdates):
//
//      xcodebuild test -project sshconfigmanager.xcodeproj -scheme sshconfigmanager \
//        -only-testing:sshconfigmanagerUITests/KeyAuditUITests \
//        -destination 'platform=macOS' -allowProvisioningUpdates
//
//  The fixture lives in the app's sandbox container, so the test process can't see it
//  on disk — assertions are made through the UI (the standard XCUITest contract).
//

import XCTest

final class KeyAuditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-seed-keys"]
        app.launch()
        return app
    }

    /// Opens the Issues screen.
    private func openIssues(_ app: XCUIApplication) {
        let issues = app.descendants(matching: .any)["sidebar-issues"]
        XCTAssertTrue(issues.waitForExistence(timeout: 20), "Issues sidebar item should appear")
        issues.click()
    }

    // MARK: - Tests

    @MainActor
    func testIssuesScreenShowsKeyFindings() {
        let app = launchedApp()
        openIssues(app)
        XCTAssertTrue(app.buttons["fix-permissions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["delete-orphan"].exists)
        XCTAssertTrue(app.buttons["generate-replacement"].exists)
    }

    @MainActor
    func testFixPermissionsClearsTheFinding() {
        let app = launchedApp()
        openIssues(app)
        let fix = app.buttons["fix-permissions"]
        XCTAssertTrue(fix.waitForExistence(timeout: 10))
        fix.click()
        XCTAssertTrue(
            waitForDisappearance(of: fix, timeout: 10),
            "Fix-permissions button should vanish once perms are corrected")
    }

    @MainActor
    func testDeleteOrphanedKeyConfirmsAndRemovesIt() {
        let app = launchedApp()
        openIssues(app)
        let delete = app.buttons["delete-orphan"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.click()

        // The confirmation dialog's destructive button is labelled `Delete "<name>"`.
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Confirmation dialog should appear")
        confirm.click()

        XCTAssertTrue(
            waitForDisappearance(of: delete, timeout: 10),
            "Orphaned finding should clear after deletion")
    }

    @MainActor
    func testGenerateReplacementOpensPrefilledSheet() {
        let app = launchedApp()
        openIssues(app)
        let generate = app.buttons["generate-replacement"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.click()
        XCTAssertTrue(
            app.staticTexts["Generate SSH Key"].waitForExistence(timeout: 10),
            "Generate Key sheet should open from the deep-link")
    }

    // MARK: - Helpers

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
