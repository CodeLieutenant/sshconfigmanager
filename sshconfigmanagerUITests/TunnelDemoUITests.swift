//
//  TunnelDemoUITests.swift
//  sshconfigmanagerUITests
//
//  App Store preview video: in-process SSH tunnel showcase.
//  Covers the full tunnel lifecycle in ~26 s: pre-seeded Active tunnel →
//  Stop → Start → connection console fills with lifecycle log → Active →
//  switch tunnel presets (Redis local, SOCKS5 dynamic) → start each.
//
//  Requires --uitest-tunnel-demo (seeds DemoTunnelEngine + 3 presets, first
//  already Active with a rich console log). The DemoTunnelEngine emits a
//  realistic connection sequence without ever opening a real SSH connection.
//
//  Run via scripts/record-tunnel-demo.sh (signed build + GUI session required).
//

import XCTest

final class TunnelDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testTunnelDemoWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest-screenshot",
            "--uitest-tunnel-demo",
            "--uitest-window-size", "1440x900",
        ]
        app.launch()

        // 0–2 s: initial sidebar (app startup, config loading).
        beat(2.0)

        // 2–4 s: navigate to Tunnels — list shows Postgres (Active ●),
        // Redis (Stopped ○), SOCKS5 Proxy (Stopped ○).
        let tunnelItem = app.descendants(matching: .any)["sidebar-tunnels"].firstMatch
        XCTAssertTrue(tunnelItem.waitForExistence(timeout: 20), "sidebar-tunnels must exist")
        tunnelItem.click()
        beat(2.0)

        // 4–7.5 s: Postgres is auto-selected. Detail shows: Active status pill,
        // console with pre-seeded connection history, throughput counter.
        beat(3.5)

        // 7.5–9.5 s: click Stop in the detail header.
        // Console appends "Stopped" status transition.
        let stopButton = app.buttons["Stop"].firstMatch
        if stopButton.waitForExistence(timeout: 5) {
            stopButton.click()
        }
        beat(2.0)

        // 9.5–14 s: click Start → DemoTunnelEngine fires lifecycle events.
        // Console fills: "Connecting…" → "Host key verified" →
        // "Authenticated" → "Listening on 127.0.0.1:5432" → "Active" pill.
        let startButton = app.buttons["Start"].firstMatch
        if startButton.waitForExistence(timeout: 5) {
            startButton.click()
        }
        beat(4.5) // wait for all 4 lifecycle log lines + connected

        // 14–15 s: tunnel is Active; throughput counter is visible.
        beat(1.0)

        // 15–19.5 s: select Redis tunnel, start it, watch connection log.
        let redisRow = app.descendants(matching: .any)["tunnel-row-redis-via-bastion"].firstMatch
        if redisRow.waitForExistence(timeout: 5) {
            redisRow.click()
        }
        beat(0.5)
        let startRedis = app.buttons["Start"].firstMatch
        if startRedis.waitForExistence(timeout: 5) {
            startRedis.click()
        }
        beat(4.0) // connection log fills, status → Active

        // 19.5–25 s: select SOCKS5 Proxy tunnel, start it.
        // Console shows "SOCKS5 proxy listening on 127.0.0.1:1080".
        let socksRow = app.descendants(matching: .any)["tunnel-row-socks5-proxy"].firstMatch
        if socksRow.waitForExistence(timeout: 5) {
            socksRow.click()
        }
        beat(0.5)
        let startSocks = app.buttons["Start"].firstMatch
        if startSocks.waitForExistence(timeout: 5) {
            startSocks.click()
        }
        beat(4.5) // connection log + Active

        // 25–27 s: final shot — SOCKS5 detail with Active status and SOCKS5 log.
        beat(2.0)

        // Keep the app alive until screencapture's -V window expires.
        beat(15.0)
    }

    @MainActor
    private func beat(_ seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}
