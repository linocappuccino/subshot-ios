import Foundation

// Mirrors the backend's Pydantic schemas exactly (app/schemas.py on the server) —
// keep these two in sync by hand for now; there's no shared-codegen step yet.

struct Me: Codable {
    let id: String
    let email: String
    let name: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name
        case avatarUrl = "avatar_url"
    }
}

struct Project: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var color: String
    let lastOpenedAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
    }
}

struct ProjectDetail: Codable {
    let id: String
    var name: String
    var color: String
    let lastOpenedAt: Date
    let createdAt: Date
    var scenes: [Scene]
    var shots: [Shot]

    enum CodingKeys: String, CodingKey {
        case id, name, color, scenes, shots
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
    }
}

struct Scene: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    var name: String?
    var color: String
    var description: String?
    var dialogue: String?
    var focalLengthMm: Int?
    var imageUrl: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, color, description, dialogue
        case projectId = "project_id"
        case focalLengthMm = "focal_length_mm"
        case imageUrl = "image_url"
        case sortOrder = "sort_order"
    }
}

enum ShotPriority: String, Codable, CaseIterable, Identifiable {
    case must, should, optional
    var id: String { rawValue }

    var label: String {
        switch self {
        case .must: return "Muss"
        case .should: return "Sollte"
        case .optional: return "Optional"
        }
    }
}

enum ShotStatus: String, Codable {
    case open, done, deleted
}

struct Shot: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    var sceneId: String?
    var imageUrl: String?
    var description: String?
    var durationSeconds: Int?
    var cameraAngle: String?
    var priority: ShotPriority?
    var status: ShotStatus
    var sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, description, priority, status
        case projectId = "project_id"
        case sceneId = "scene_id"
        case imageUrl = "image_url"
        case durationSeconds = "duration_seconds"
        case cameraAngle = "camera_angle"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct Member: Codable, Identifiable, Hashable {
    var id: String { userId }
    let userId: String
    let email: String
    let name: String?
    let role: String

    enum CodingKeys: String, CodingKey {
        case email, name, role
        case userId = "user_id"
    }
}

struct Invite: Codable {
    let id: String
    let email: String
    let role: String
    let token: String
    let createdAt: Date
    let acceptedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, email, role, token
        case createdAt = "created_at"
        case acceptedAt = "accepted_at"
    }
}

// Common camera angles offered in the shot detail picker (spec: "Picker mit
// vordefinierten Optionen + Andere") — free text is still accepted since
// `cameraAngle` is a plain string on the wire, this is just UI convenience.
enum CameraAngle: String, CaseIterable, Identifiable {
    case wide = "Weitwinkel"
    case medium = "Halbtotale"
    case closeUp = "Nahaufnahme"
    case extremeCloseUp = "Detail"
    case overhead = "Vogelperspektive"
    case lowAngle = "Froschperspektive"
    case pov = "POV"
    case other = "Andere"
    var id: String { rawValue }
}
