import XCTest
@testable import Subshot

/// 2026-11-24 (audit #5) — decoding of the two 413 answers (API contract security-fixes b1b5b04).
@MainActor
final class UploadLimitTests: XCTestCase {
    func testUploadTooLarge() {
        let body = #"{"error":"upload_too_large","size_bytes":60000000000,"max_bytes":53687091200,"detail":"Die Datei ist zu gross."}"#
        XCTAssertEqual(UploadLimitProblem.parse(status: 413, body: body), .tooLarge(sizeBytes: 60_000_000_000, maxBytes: 53_687_091_200))
        XCTAssertEqual(UploadLimitProblem.sizeLabel(53_687_091_200), "50 GB")
        XCTAssertEqual(UploadLimitProblem.sizeLabel(2_147_483_648), "2 GB")
        XCTAssertEqual(UploadLimitProblem.sizeLabel(209_715_200), "200 MB")
    }

    func testStorageFull() {
        let body = #"{"error":"storage_limit_reached","used_bytes":107374182400,"limit_bytes":107374182400,"tier_gb":100,"team_id":"t1","scope":"team","detail":"Speicher voll"}"#
        XCTAssertEqual(UploadLimitProblem.parse(status: 413, body: body),
                       .storageFull(usedBytes: 107_374_182_400, limitBytes: 107_374_182_400, scope: "team", teamId: "t1"))
        let trial = #"{"error":"storage_limit_reached","used_bytes":1073741824,"limit_bytes":1073741824,"tier_gb":1,"team_id":null,"scope":"trial","detail":"x"}"#
        XCTAssertEqual(UploadLimitProblem.parse(status: 413, body: trial),
                       .storageFull(usedBytes: 1_073_741_824, limitBytes: 1_073_741_824, scope: "trial", teamId: nil))
    }

    func testOtherAnswersAreNotLimits() {
        XCTAssertNil(UploadLimitProblem.parse(status: 400, body: #"{"error":"upload_too_large"}"#))   // only 413
        XCTAssertNil(UploadLimitProblem.parse(status: 413, body: #"{"detail":"Request Entity Too Large"}"#))  // nginx-style
        XCTAssertNil(UploadLimitProblem.parse(status: 413, body: "<html>413</html>"))
        XCTAssertEqual(UploadLimitProblem.from(APIError.server(status: 413, message: #"{"error":"upload_too_large","max_bytes":2147483648}"#)),
                       .tooLarge(sizeBytes: nil, maxBytes: 2_147_483_648))
        XCTAssertNil(UploadLimitProblem.from(APIError.notAuthenticated))
    }
}
