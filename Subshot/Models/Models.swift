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
    var shootDate: Date?
    var locationAddress: String?
    var locationLat: Double?
    var locationLng: Double?
    let lastOpenedAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case shootDate = "shoot_date"
        case locationAddress = "location_address"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
    }
}

struct ProjectDetail: Codable {
    let id: String
    var name: String
    var color: String
    var shootDate: Date?
    var locationAddress: String?
    var locationLat: Double?
    var locationLng: Double?
    let lastOpenedAt: Date
    let createdAt: Date
    var scenes: [Scene]
    var shots: [Shot]
    var todoLists: [TodoList]
    var sections: [SceneSection]

    enum CodingKeys: String, CodingKey {
        case id, name, color, scenes, shots
        case shootDate = "shoot_date"
        case locationAddress = "location_address"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
        case todoLists = "todo_lists"
        case sections
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
    var scheduledAt: Date?
    var durationMinutes: Int?
    var imageUrl: String?
    var completed: Bool
    var sortOrder: Int
    var assigneeId: String?
    var sectionId: String?
    var locationAddress: String?
    var locationLat: Double?
    var locationLng: Double?
    let number: Int
    let letter: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, description, dialogue, completed, number, letter
        case projectId = "project_id"
        case focalLengthMm = "focal_length_mm"
        case scheduledAt = "scheduled_at"
        case durationMinutes = "duration_minutes"
        case imageUrl = "image_url"
        case sortOrder = "sort_order"
        case assigneeId = "assignee_id"
        case sectionId = "section_id"
        case locationAddress = "location_address"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
    }

    /// "3A" / "12" — the display label shown on the scene tile.
    var displayNumber: String {
        number.description + (letter ?? "")
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
    var goodTakeFilename: String?
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
        case goodTakeFilename = "good_take_filename"
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

struct TodoItem: Codable, Identifiable, Hashable {
    let id: String
    let todoListId: String
    var text: String
    var done: Bool
    var assigneeId: String?
    var sortOrder: Int
    let createdAt: Date
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, text, done
        case todoListId = "todo_list_id"
        case assigneeId = "assignee_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

struct TodoList: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    var name: String
    var sortOrder: Int
    var items: [TodoItem]

    enum CodingKeys: String, CodingKey {
        case id, name, items
        case projectId = "project_id"
        case sortOrder = "sort_order"
    }
}

/// Named `SceneSection` (not `Section`) to avoid shadowing SwiftUI's own
/// `Section` view type in this module — the exact same trap as the earlier
/// `Scene`/`SwiftUI.Scene` collision (see SubshotApp.swift), and `Section(...)
/// { }` is used everywhere in Forms/Lists across this app.
struct SceneSection: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    var name: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectId = "project_id"
        case sortOrder = "sort_order"
    }
}

/// Named `AppNotification` to avoid colliding with Foundation's own
/// `Notification` type.
struct AppNotification: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let kind: String
    let count: Int
    let title: String
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let readAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, count, title, body
        case projectId = "project_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case readAt = "read_at"
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
