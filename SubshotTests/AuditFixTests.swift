import XCTest
@testable import Subshot

/// 2026-11-24 — unit tests for the audit fixes (#2 host allowlist, #3 bridge origin, #4 error state,
/// #6 log redaction, #10 shot-list delete keeps post-production groups).
@MainActor
final class AuditFixTests: XCTestCase {
    // MARK: #2 board page allowlist

    func testBoardAllowsSubshotClerkR2() {
        for s in ["https://app.subshot.ch/embed/idea/p/i", "https://accounts.subshot.ch/sign-in", "https://clerk.subshot.ch/v1/client",
                  "https://subshot.ch/x", "https://abc.clerk.accounts.dev/v1", "https://acct.r2.cloudflarestorage.com/b/k.mp4?X-Amz=1",
                  "about:blank", "blob:https://app.subshot.ch/123"] {
            XCTAssertTrue(BoardWebPolicy.isAllowedPage(URL(string: s)!), s)
        }
    }

    func testBoardBlocksForeignAndLookalikes() {
        for s in ["https://evil.example/phish", "https://subshot.ch.evil.example/", "https://evilsubshot.ch/", "http://app.subshot.ch/",
                  "https://www.youtube.com/watch?v=1", "https://maps.google.com/", "javascript:alert(1)", "file:///etc/passwd"] {
            XCTAssertFalse(BoardWebPolicy.isAllowedPage(URL(string: s)!), s)
        }
    }

    func testExternalOpenableOnlySafeSchemes() {
        XCTAssertTrue(BoardWebPolicy.isExternalOpenable(URL(string: "https://maps.google.com")!))
        XCTAssertTrue(BoardWebPolicy.isExternalOpenable(URL(string: "mailto:a@b.ch")!))
        XCTAssertFalse(BoardWebPolicy.isExternalOpenable(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(BoardWebPolicy.isExternalOpenable(URL(string: "file:///x")!))
    }

    // MARK: #3 bridge origin

    func testBridgeOnlyMainFrameOnApp() {
        XCTAssertTrue(BoardWebPolicy.acceptsMessage(isMainFrame: true, host: "app.subshot.ch"))
        XCTAssertFalse(BoardWebPolicy.acceptsMessage(isMainFrame: false, host: "app.subshot.ch"))  // iframe of the board
        XCTAssertFalse(BoardWebPolicy.acceptsMessage(isMainFrame: true, host: "www.youtube.com"))
        XCTAssertFalse(BoardWebPolicy.acceptsMessage(isMainFrame: true, host: "accounts.subshot.ch"))
        XCTAssertFalse(BoardWebPolicy.acceptsMessage(isMainFrame: true, host: nil))
    }

    // MARK: #4 projects list state

    func testProjectListState() {
        XCTAssertEqual(ProjectListContentState.of(hasItems: true, isLoading: false, loadError: "x"), .content)
        XCTAssertEqual(ProjectListContentState.of(hasItems: false, isLoading: true, loadError: "x"), .loading)
        XCTAssertEqual(ProjectListContentState.of(hasItems: false, isLoading: false, loadError: "offline"), .failed("offline"))
        XCTAssertEqual(ProjectListContentState.of(hasItems: false, isLoading: false, loadError: nil), .empty)
    }

    // MARK: #6 log redaction

    func testLogRedactDropsSignature() {
        let raw = "https://acct.r2.cloudflarestorage.com/bucket/img.webp?X-Amz-Signature=secret&X-Amz-Credential=c"
        let out = LogRedact.url(raw)
        XCTAssertEqual(out, "https://acct.r2.cloudflarestorage.com/bucket/img.webp")
        XCTAssertFalse(out.contains("secret"))
    }

    // MARK: #10 shot-list delete

    private func section(_ id: String, postpro: Bool) throws -> SceneSection {
        let json: [String: Any] = ["id": id, "project_id": "p", "name": id, "sort_order": 0, "has_project_info": false,
                                   "todo_lists": [], "in_postproduction": postpro, "timecode_offset_seconds": 0, "reference_videos": []]
        return try JSONDecoder().decode(SceneSection.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testDeleteKeepsPostproGroup() throws {
        let all = [try section("plain", postpro: false), try section("pp", postpro: true), try section("other", postpro: false)]
        let afterPlain = ShotlistFilter.afterShotlistDelete(all, deletedId: "plain")
        XCTAssertEqual(afterPlain.map(\.id), ["pp", "other"])
        let afterPP = ShotlistFilter.afterShotlistDelete(all, deletedId: "pp")
        XCTAssertEqual(afterPP.map(\.id), ["plain", "pp", "other"])          // stays for Post-production
        XCTAssertEqual(afterPP.first { $0.id == "pp" }?.isUnplanned, true)    // … and is no shot list any more
        XCTAssertFalse(ShotlistFilter.visible(afterPP, sectionIdsWithScenes: []).contains { $0.id == "pp" })
    }
}
