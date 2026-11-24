import Foundation

/// 2026-11-24 (audit #5, API contract security-fixes b1b5b04) — the two «too big» answers (HTTP 413) of
/// POST /videos/{id}/versions and POST /video-versions/{id}/complete:
///   {"error":"upload_too_large","size_bytes","max_bytes","detail"}
///   {"error":"storage_limit_reached","used_bytes","limit_bytes","tier_gb","team_id","scope","detail"}
/// Unit-tested (SubshotTests/UploadLimitTests).
enum UploadLimitProblem: Equatable {
    case tooLarge(sizeBytes: Int64?, maxBytes: Int64?)
    case storageFull(usedBytes: Int64?, limitBytes: Int64?, scope: String?, teamId: String?)

    nonisolated static func parse(status: Int, body: String) -> UploadLimitProblem? {
        guard status == 413, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let int = { (k: String) -> Int64? in (json[k] as? NSNumber)?.int64Value }
        switch json["error"] as? String {
        case "upload_too_large":
            return .tooLarge(sizeBytes: int("size_bytes"), maxBytes: int("max_bytes"))
        case "storage_limit_reached":
            return .storageFull(usedBytes: int("used_bytes"), limitBytes: int("limit_bytes"),
                                scope: json["scope"] as? String, teamId: json["team_id"] as? String)
        default:
            return nil
        }
    }

    nonisolated static func from(_ error: Error) -> UploadLimitProblem? {
        if case .server(let status, let message) = error as? APIError { return parse(status: status, body: message) }
        return nil
    }

    /// «50 GB» / «2 GB» / «200 MB» — whole numbers where possible (like the web)
    nonisolated static func sizeLabel(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "?" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return mb == mb.rounded() ? "\(Int(mb)) MB" : String(format: "%.0f MB", mb)
    }

    /// where «Speicher erweitern» leads (the website's storage-tier picker, as the web dialog does)
    nonisolated static let upgradeURL = URL(string: "https://app.subshot.ch/team#storage")!

    nonisolated static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
