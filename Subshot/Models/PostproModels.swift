import Foundation

// 2026-10-12 — web parity for the Postproduction additions: Fassungen (deliverables) + licences per
// video, technical check (QC) per version, feedback rounds per video. Optional wherever the backend
// may send null.

struct VideoDeliverable: Codable, Equatable, Identifiable {
    let id: String
    let videoId: String
    var label: String
    var sortOrder: Int
    var status: String              // missing | uploading | ready
    var originalFilename: String?
    var contentType: String?
    var fileSizeBytes: Int?
    var uploadedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, label, status
        case videoId = "video_id"
        case sortOrder = "sort_order"
        case originalFilename = "original_filename"
        case contentType = "content_type"
        case fileSizeBytes = "file_size_bytes"
        case uploadedAt = "uploaded_at"
    }
}

struct VideoLicenseFile: Codable, Equatable, Identifiable {
    let id: String
    let videoId: String
    let originalFilename: String?
    let contentType: String?
    let fileSizeBytes: Int?
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case videoId = "video_id"
        case originalFilename = "original_filename"
        case contentType = "content_type"
        case fileSizeBytes = "file_size_bytes"
    }
}

struct VideoExtras: Codable, Equatable {
    var deliverables: [VideoDeliverable]
    var licenses: [VideoLicenseFile]
    static let empty = VideoExtras(deliverables: [], licenses: [])
}

struct VideoQC: Codable, Equatable {
    let status: String              // none | pending | running | done | error
    let checks: [Check]
    let failed: Int
    let error: String?
    let measuredAt: String?

    enum CodingKeys: String, CodingKey {
        case status, checks, failed, error
        case measuredAt = "measured_at"
    }

    struct Check: Codable, Equatable, Identifiable {
        var id: String { key + label }
        let key: String
        let label: String
        let value: String
        let ok: Bool
    }
}

struct FeedbackRounds: Codable, Equatable {
    let defaultLimit: Int?
    let videos: [String: VideoRounds]

    enum CodingKeys: String, CodingKey {
        case videos
        case defaultLimit = "default_limit"
    }

    struct VideoRounds: Codable, Equatable {
        let used: Int
        let versions: [Int]
        let limit: Int?
        let ownLimit: Int?
        enum CodingKeys: String, CodingKey {
            case used, versions, limit
            case ownLimit = "own_limit"
        }
    }
}
