import XCTest

/// 2026-11-16 — regression check for the backend's 3-logins guard: the app's board warm-up
/// (POST /me/web-ticket) used to create web sessions that pushed the app's own Clerk session
/// out, so after a few launches the Projects screen showed «All 0». Relaunches the DEBUG app
/// 5 times as the test account, opens the demo idea board each time and fails if the project
/// list ever comes back empty. Not part of the devlog screenshot workflow; run it by hand:
/// `-only-testing:SubshotUITests/SessionStabilityTests` with SUBSHOT_TEST_TICKET or DEBUG_TICKET_SECRET.
final class SessionStabilityTests: XCTestCase {
    func testRelaunchWithBoardKeepsSession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let ticket = env["SUBSHOT_TEST_TICKET"], !ticket.isEmpty else {
            throw XCTSkip("SUBSHOT_TEST_TICKET not set")
        }
        for round in 1...5 {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-lastOpenedWorkflowSection", "0"]
            if round == 1 { app.launchArguments += ["-SubshotTestTicket", ticket] }
            app.launch()
            let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All,' OR label BEGINSWITH 'Alle,'")).firstMatch
            let back = app.buttons["BackButton"]
            // the app may reopen the last project after a relaunch — go back to the Projects screen;
            // wait until the project count has settled (it starts at 0 while loading)
            var label = ""
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                if back.exists && back.isHittable { back.tap() }
                if all.exists {
                    label = all.label
                    if !label.hasSuffix(", 0") { break }
                }
                sleep(2)
            }
            print("ROUND \(round) \(ISO8601DateFormatter().string(from: Date())) filter=\(label)")
            XCTAssertFalse(label.isEmpty, "round \(round): projects screen missing")
            XCTAssertFalse(label.hasSuffix(", 0"), "round \(round): project list empty (\(label))")
            // open the demo project + its approved idea's board, then go on to the next launch
            let tile = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Alpenbahn'")).firstMatch
            if tile.waitForExistence(timeout: 10), tile.isHittable {
                tile.tap()
                let idea = app.staticTexts["Panoramafahrt im Morgenlicht"]
                if idea.waitForExistence(timeout: 10), idea.isHittable {
                    idea.tap()
                    sleep(12) // board + its web sign-in
                    print("ROUND \(round) board opened")
                }
            }
            sleep(20) // pause between launches (webhook + guard)
            app.terminate()
        }
    }
}
