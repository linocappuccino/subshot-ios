import XCTest

/// 2026-11-16 — several platform icons per video (web parity). Opens the demo project's
/// post-production as the test account, adds Instagram to the first video (YouTube is set in the
/// demo data), checks both icons are stacked on the tile, then restores YouTube only.
/// Needs SUBSHOT_TEST_TICKET. Changes demo data only (claude-urltest@subshot.dev).
final class VideoPlatformsTests: XCTestCase {
    func testAddAndRemovePlatform() throws {
        guard let ticket = ProcessInfo.processInfo.environment["SUBSHOT_TEST_TICKET"], !ticket.isEmpty else {
            throw XCTSkip("SUBSHOT_TEST_TICKET not set")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-UITestNoAnimations", "YES",
                               "-lastOpenedWorkflowSection", "2",
                               "-lastOpenedProjectId", "c15ead5c-1d16-4f9b-ac97-547fb244e7a4",
                               "-SubshotTestTicket", ticket]
        app.launch()
        let picker = app.buttons.matching(identifier: "videoTile.platforms").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 45), "platform picker missing")
        sleep(2)
        add(shot(app, "platforms-before"))
        // checks look only inside the first tile's picker (other videos further down can carry Instagram too)
        // a previous run may have left Instagram on: take it off first
        if picker.images["Instagram"].exists {
            picker.tap()
            XCTAssertTrue(app.buttons["Instagram"].waitForExistence(timeout: 5))
            app.buttons["Instagram"].tap()
            XCTAssertTrue(gone(picker.images["Instagram"]), "could not reset Instagram")
        }

        picker.tap()
        let instagram = app.buttons["Instagram"]
        XCTAssertTrue(instagram.waitForExistence(timeout: 5), "menu did not open")
        instagram.tap()
        sleep(3)
        XCTAssertTrue(picker.images["YouTube"].exists, "YouTube icon gone")
        XCTAssertTrue(picker.images["Instagram"].waitForExistence(timeout: 5), "Instagram icon not shown")
        add(shot(app, "platforms-two"))

        // restore the demo data: YouTube only
        picker.tap()
        XCTAssertTrue(app.buttons["Instagram"].waitForExistence(timeout: 5))
        app.buttons["Instagram"].tap()
        XCTAssertTrue(gone(picker.images["Instagram"]), "Instagram icon still shown")
        XCTAssertTrue(picker.images["YouTube"].exists, "YouTube icon gone after restore")
    }

    private func gone(_ e: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let done = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
    }

    private func shot(_ app: XCUIApplication, _ name: String) -> XCTAttachment {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        return a
    }
}
