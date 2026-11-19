import XCTest
@testable import Subshot

/// 2026-11-19 — the shot list shows the same sections as the website (page.tsx:1813). Fixture = the PostFinance
/// project's real field combination read from the API on 2026-11-19 (names replaced): 1 shot list with 16 scenes
/// + 21 post-production video groups (in_postproduction, 0 scenes) → exactly 1 visible shot list.
@MainActor
final class ShotlistFilterTests: XCTestCase {
    private func section(_ id: String, postpro: Bool, unplanned: Bool? = nil, order: Int) throws -> SceneSection {
        var json: [String: Any] = [
            "id": id, "project_id": "p", "name": "Bereich \(order)", "sort_order": order,
            "has_project_info": false, "todo_lists": [], "in_postproduction": postpro,
            "timecode_offset_seconds": 0, "reference_videos": [],
        ]
        if let unplanned { json["is_unplanned"] = unplanned }
        return try JSONDecoder().decode(SceneSection.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testPostFinanceShape() throws {
        var sections = [try section("shot", postpro: false, order: 0)]
        for i in 1...21 { sections.append(try section("pp\(i)", postpro: true, order: i)) }
        let withScenes: Set<String> = ["shot"] // the 16 scenes all sit in the one shot list
        let visible = ShotlistFilter.visible(sections, sectionIdsWithScenes: withScenes)
        XCTAssertEqual(sections.count, 22)
        XCTAssertEqual(visible.map(\.id), ["shot"])
    }

    func testRules() throws {
        let withScenes: Set<String> = ["pp-scenes", "plain"]
        // a shot list sent to post-production keeps its scenes → stays a shot list
        XCTAssertTrue(ShotlistFilter.isShotlist(try section("pp-scenes", postpro: true, order: 1), sectionIdsWithScenes: withScenes))
        // an empty shot list that is NOT in post-production stays (can be filled / deleted)
        XCTAssertTrue(ShotlistFilter.isShotlist(try section("empty", postpro: false, order: 2), sectionIdsWithScenes: withScenes))
        // unplanned (one uploaded video) never shows, even with the flag only
        XCTAssertFalse(ShotlistFilter.isShotlist(try section("u", postpro: false, unplanned: true, order: 3), sectionIdsWithScenes: withScenes))
        // post-production group without scenes never shows
        XCTAssertFalse(ShotlistFilter.isShotlist(try section("pp-empty", postpro: true, order: 4), sectionIdsWithScenes: withScenes))
    }
}
