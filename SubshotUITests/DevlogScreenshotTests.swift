import XCTest

/// 2026-11-15 — real iPad screenshots for the Subshot devlog (one entry per fundamental feature).
/// Runs in CI (.github/workflows/devlog-screenshots.yml) against the live backend as the fixed
/// test account only: the workflow mints a 2-minute Clerk sign-in ticket (POST /debug/test-ticket)
/// and hands it in as SUBSHOT_TEST_TICKET; the app's DEBUG-only `-SubshotTestTicket` launch
/// argument signs in with it (see DebugTestLogin in SubshotApp.swift).
///
/// Every screenshot is an XCTAttachment named exactly like the devlog slot (ios-<feature>-<n>).
/// A screen that can't be reached is skipped and logged ("SKIPPED <name>: <why>") — the test
/// never fails because of a missing screen, only the attachment is missing then. The list of
/// skipped shots is attached as `skipped.txt`.
///
/// Labels are matched in German AND English (the app's language comes from the account, not
/// the simulator); the simulator itself runs in English so SF Symbol labels are predictable.
final class DevlogScreenshotTests: XCTestCase {
    private let demoProject = "Alpenbahn"
    /// its id — ShotListView only restores the page (-lastOpenedWorkflowSection) for the project
    /// in lastOpenedProjectId, and a fresh install has none
    private let demoProjectId = "c15ead5c-1d16-4f9b-ac97-547fb244e7a4"
    /// approved idea AND shot-list section of the demo project (has scenes, shots, ticked-off takes)
    private let demoSection = "Panoramafahrt im Morgenlicht"
    /// a scene in that section with image, description and shots
    private let demoScene = "Gipfel erreicht"
    private var app: XCUIApplication!
    private var skipped: [String] = []

    override func setUp() {
        continueAfterFailure = true
    }

    // Four phases, ONE launch each: on the GitHub macos-26 runner XCUITest fails to terminate a
    // running app ("Failed to terminate …:0") — so CI runs every phase as its own xcodebuild call
    // and stops the app with `simctl terminate` in between. Every signed-in phase signs in with
    // its own one-time ticket (the app is reinstalled per call, the session doesn't carry over):
    // in CI the test fetches it (DEBUG_TICKET_SECRET); locally pass a fresh SUBSHOT_TEST_TICKET
    // per phase.

    func test1_SignIn() throws {
        // 1) Sign-in screen — launched WITHOUT a ticket (fresh simulator → signed out).
        app = makeApp(ticket: nil)
        app.launch()
        if app.buttons["Anmelden"].waitForExistence(timeout: 20) || app.buttons["Sign in"].exists {
            dismissSystemAlert() // the push-permission alert pops up on the first launch
            sleep(3) // intro animation (icon fly-in, letterbox bars)
            shot("ios-sign-in-account-1")
        } else {
            skip("ios-sign-in-account-1", "no sign-in button (already signed in?)")
        }
        attachSkipped("1")
    }

    func test2_OverviewAccountIdeas() throws {
        // 2) Signed in as the test account.
        guard let ticket = testTicket() else {
            skip("all signed-in shots", "no ticket (set SUBSHOT_TEST_TICKET or DEBUG_TICKET_SECRET)")
            attachSkipped(phase)
            return
        }
        app = makeApp(ticket: ticket)
        addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for label in ["Don’t Allow", "Don't Allow", "Nicht erlauben", "Allow", "Erlauben"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        let todo = button(["Todoliste", "To-dos"])
        guard todo.waitForExistence(timeout: 40) else {
            skip("all signed-in shots", "projects screen did not appear (ticket expired or sign-in failed)")
            attachSkipped(phase)
            return
        }
        dismissSystemAlert()
        app.tap() // lets the interruption monitor fire if the push alert is still up
        sleep(4) // project tiles + images

        // Projects overview
        shot("ios-projects-overview-1")
        if tap(todo) {
            sleep(2)
            shot("ios-projects-overview-2")
            closeSheet()
        } else { skip("ios-projects-overview-2", "To-do button not hittable") }

        // Account menu + MCP sheet
        let avatar = app.buttons["avatarMenu"]
        if tap(avatar) {
            sleep(1)
            shot("ios-sign-in-account-2")
            if tap(button(["KI verbinden (MCP)", "Connect AI (MCP)"])) {
                sleep(2)
                shot("ios-sign-in-account-3")
                closeSheet()
            } else {
                skip("ios-sign-in-account-3", "MCP menu entry not found")
                app.tap()
            }
        } else {
            skip("ios-sign-in-account-2", "account menu not found")
            skip("ios-sign-in-account-3", "account menu not found")
        }

        // Open the demo project
        let tile = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", demoProject)).firstMatch
        guard tile.waitForExistence(timeout: 10), tap(tile) else {
            skip("ios-ideas-1", "demo project «\(demoProject)» not visible for the test account")
            attachSkipped(phase)
            return
        }
        sleep(4)

        // Ideas (the launch argument opens the project on the ideas page)
        if app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ideas' OR label CONTAINS 'Ideen'")).firstMatch.waitForExistence(timeout: 10) {
            shot("ios-ideas-1")
        } else {
            skip("ios-ideas-1", "ideas page not shown")
        }

        attachSkipped("2")
    }

    func test3_ShotListPlanningPostSharing() throws {
        // Storyboard / shot list — launched straight into the scripting page with a fresh ticket
        // (each xcodebuild call reinstalls the app, so the session doesn't carry over).
        app = makeApp(ticket: testTicket(), section: 1, restoreProject: true)
        app.launch()
        backToProjects()
        let tile2 = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", demoProject)).firstMatch
        guard tile2.waitForExistence(timeout: 30), tap(tile2) else {
            for n in ["ios-storyboard-shot-list-1", "ios-storyboard-shot-list-2", "ios-on-set-1", "ios-shoot-planning-1",
                      "ios-shoot-planning-2", "ios-timecode-markers-1", "ios-post-production-1", "ios-post-production-2",
                      "ios-sharing-team-1", "ios-sharing-team-2"] {
                skip(n, "project not reachable after relaunch (session lost?)")
            }
            attachSkipped(phase)
            return
        }
        sleep(5)
        // open the demo section (shot list overview → its scenes)
        if tap(text(demoSection), timeout: 10) {
            sleep(4)
        } else { print("demo section «\(demoSection)» not found — shooting the overview") }
        shot("ios-storyboard-shot-list-1")

        // Shoot planning chips row (Drehort · Zeitplan · Callsheet · Drehreihenfolge)
        let scheduleChip = button(["Zeitplan", "Schedule"])
        if scheduleChip.waitForExistence(timeout: 5) {
            shot("ios-shoot-planning-1")
            if tap(scheduleChip) {
                sleep(3)
                shot("ios-shoot-planning-2")
                closeSheet()
            } else { skip("ios-shoot-planning-2", "schedule chip not hittable") }
        } else {
            skip("ios-shoot-planning-1", "planning row not found (open a shotlist section first?)")
            skip("ios-shoot-planning-2", "planning row not found")
        }

        // Scene details — first scene card
        if tap(text(demoScene)) || (firstSceneCard().map { tap($0) } ?? false) {
            sleep(2)
            shot("ios-storyboard-shot-list-2")
            closeSheet()
        } else { skip("ios-storyboard-shot-list-2", "no scene card found") }

        // On set — the shot order view (every shot with its tick-off state)
        if tap(button(["Shot order", "Shot-Reihenfolge"]), timeout: 3) {
            sleep(3)
            shot("ios-on-set-1")
            _ = tap(button(["Scene order", "Szenen-Reihenfolge"]), timeout: 3)
            sleep(2)
        } else {
            app.swipeUp()
            sleep(2)
            shot("ios-on-set-1")
        }

        // Timecode / Rec markers
        app.swipeDown()
        sleep(1)
        if tap(element(["Start Rec-Markers", "Set Framerate"]), timeout: 3) {
            sleep(3) // visual-timecode sheet (camera sync / manual framerate)
            shot("ios-timecode-markers-1")
            closeSheet()
        } else if element(["Set Marker"]).exists {
            shot("ios-timecode-markers-1")
        } else { skip("ios-timecode-markers-1", "timecode/marker controls not visible") }
        app.swipeDown()
        sleep(1)

        // Sharing + team (behind the expandable «…» toolbar)
        let more = app.buttons["toolbar.more"]
        if tap(more) {
            sleep(1)
            if tap(app.buttons["toolbar.shareLink"]) {
                sleep(2)
                shot("ios-sharing-team-1")
                closeSheet()
            } else { skip("ios-sharing-team-1", "share-link button not found") }
            if tap(app.buttons["toolbar.team"]) {
                sleep(2)
                shot("ios-sharing-team-2")
                closeSheet()
            } else { skip("ios-sharing-team-2", "team button not found") }

            // Post-production list + player
            if tap(app.buttons["toolbar.postproduction"]) {
                sleep(3)
                shot("ios-post-production-1")
                let play = button(["Abspielen", "Play"])
                if tap(play) || tapFirstVideoTile() {
                    sleep(5) // player + comment list (don't tap «Comments»: it focuses the input → keyboard)
                    shot("ios-post-production-2")
                    closeSheet()
                } else { skip("ios-post-production-2", "no playable video in the demo project") }
                closeSheet()
            } else {
                skip("ios-post-production-1", "post-production module off or button missing")
                skip("ios-post-production-2", "post-production module off or button missing")
            }
        } else {
            for n in ["ios-sharing-team-1", "ios-sharing-team-2", "ios-post-production-1", "ios-post-production-2"] {
                skip(n, "«…» toolbar button not found")
            }
        }

        attachSkipped("3")
    }

    func test4_IdeaBoard() throws {
        // Idea board LAST: its embedded web sign-in creates another Clerk session.
        app = makeApp(ticket: testTicket(), section: 0, restoreProject: true)
        app.launch()
        backToProjects()
        let tile3 = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", demoProject)).firstMatch
        if tile3.waitForExistence(timeout: 30), tap(tile3) {
            sleep(4)
            if tap(text(demoSection), timeout: 10) || (firstIdeaTile().map { tap($0) } ?? false) {
                sleep(12) // embedded web board loads
                shot("ios-idea-board-1")
            } else { skip("ios-idea-board-1", "no idea tile found") }
        } else { skip("ios-idea-board-1", "project not reachable after relaunch") }

        attachSkipped("4")
    }

    // MARK: - Helpers

    /// `restoreProject`: also hand in the demo project's id — needed for `section` to apply on a
    /// fresh install, but then the app opens straight into the project (no Projects screen).
    private func makeApp(ticket: String?, section: Int = 0, restoreProject: Bool = false) -> XCUIApplication {
        let a = XCUIApplication()
        a.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                             // page a project opens on: 0 ideas, 1 shot list (ShotListView.lastOpenedWorkflowSectionKey)
                             "-lastOpenedWorkflowSection", String(section)]
        if restoreProject { a.launchArguments += ["-lastOpenedProjectId", demoProjectId] }
        if let ticket { a.launchArguments += ["-SubshotTestTicket", ticket] }
        return a
    }

    /// The ticket lives 2 minutes — on a slow CI runner it expired before the signed-in launch
    /// (2026-11-15). So in CI the test fetches it itself, right here, with DEBUG_TICKET_SECRET
    /// (passed in as TEST_RUNNER_DEBUG_TICKET_SECRET, never printed). Locally a ready ticket in
    /// SUBSHOT_TEST_TICKET works too.
    private func testTicket() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let t = env["SUBSHOT_TEST_TICKET"], !t.isEmpty { return t }
        guard let secret = env["DEBUG_TICKET_SECRET"], !secret.isEmpty,
              let url = URL(string: "https://subshot.ch/debug/test-ticket") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(secret, forHTTPHeaderField: "X-Debug-Secret")
        var ticket: String?
        let done = expectation(description: "test ticket")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ticket = json["ticket"] as? String
            } else {
                print("test ticket request failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 25)
        return ticket
    }

    private func shot(_ name: String) {
        // device screenshot, not app.screenshot(): the app snapshot timed out on the CI runner
        // while the live schedule sheet was animating
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT \(name)")
    }

    private func skip(_ name: String, _ why: String) {
        skipped.append("\(name): \(why)")
        print("SKIPPED \(name): \(why)")
    }

    /// the running phase's number (from the test name test<N>_…), for the attachment names
    private var phase: String {
        let n = name.replacingOccurrences(of: "-[DevlogScreenshotTests test", with: "")
        return String(n.prefix(1))
    }

    /// The app reopens the last project after a relaunch — go back to the Projects screen.
    private func backToProjects() {
        let back = app.buttons["BackButton"]
        if back.waitForExistence(timeout: 15), back.isHittable { back.tap(); sleep(2) }
    }

    private func attachSkipped(_ phase: String) {
        let a = XCTAttachment(string: skipped.isEmpty ? "none" : skipped.joined(separator: "\n"))
        a.name = "skipped-\(phase)"
        a.lifetime = .keepAlways
        add(a)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "hierarchy-\(phase)"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func predicate(_ labels: [String]) -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: labels.map { NSPredicate(format: "label == %@", $0) })
    }

    private func button(_ labels: [String]) -> XCUIElement {
        app.buttons.matching(predicate(labels)).firstMatch
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(_ labels: [String]) -> XCUIElement {
        app.descendants(matching: .any).matching(predicate(labels)).firstMatch
    }

    @discardableResult
    private func tap(_ e: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard e.waitForExistence(timeout: timeout), e.isHittable else { return false }
        e.tap()
        return true
    }

    private func closeSheet() {
        for label in ["Fertig", "Done", "Schliessen", "Close", "Abbrechen", "Cancel"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); sleep(1); return }
        }
        // no button: drag the sheet down
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        sleep(1)
    }

    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don’t Allow", "Don't Allow", "Nicht erlauben"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 2) { b.tap(); return }
        }
    }

    /// Idea tiles carry the idea title; skip the page's own controls by taking the first big cell.
    private func firstIdeaTile() -> XCUIElement? {
        let candidates = app.buttons.allElementsBoundByIndex.filter { $0.frame.width > 180 && $0.frame.height > 120 && $0.isHittable }
        return candidates.first
    }

    private func firstSceneCard() -> XCUIElement? {
        let candidates = app.buttons.allElementsBoundByIndex.filter { $0.frame.width > 200 && $0.frame.height > 90 && $0.isHittable }
        return candidates.first
    }

    private func tapFirstVideoTile() -> Bool {
        let images = app.images.allElementsBoundByIndex.filter { $0.frame.width > 160 && $0.isHittable }
        guard let first = images.first else { return false }
        first.tap()
        return true
    }
}
