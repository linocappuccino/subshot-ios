import Foundation
import SwiftUI

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
    var emoji: String?
    /// Manual drag-to-reorder position on the home screen grid (2026-07-11)
    /// — same idea as ProjectFolder.sortOrder.
    var sortOrder: Int = 0
    var shootDate: Date?
    var locationAddress: String?
    var locationLat: Double?
    var locationLng: Double?
    /// Client the shoot is for (2026-07-13, Lino) — shown on the
    /// project-level Projektinfo tile only.
    var clientName: String?
    var folderId: String?
    var thumbnailUrl: String?
    let lastOpenedAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, color, emoji
        case sortOrder = "sort_order"
        case shootDate = "shoot_date"
        case locationAddress = "location_address"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
        case clientName = "client_name"
        case folderId = "folder_id"
        case thumbnailUrl = "thumbnail_url"
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
    }

    /// Deletion cron (scripts/deletion_job.py) warns at day 25, deletes at
    /// day 30 of inactivity — purely a function of lastOpenedAt, no separate
    /// backend field needed.
    var daysUntilDeletion: Int {
        let deletesAt = lastOpenedAt.addingTimeInterval(30 * 24 * 3600)
        return max(0, Calendar.current.dateComponents([.day], from: .now, to: deletesAt).day ?? 0)
    }
}

struct ProjectFolder: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var color: String
    var emoji: String?
    var sortOrder: Int
    var backgroundImageURL: String?
    /// Fractional (0-1) face-detected focus point within the cover image,
    /// or nil when no face was found (see app/face_detect.py on the
    /// backend) — used by AsyncShotThumbnail's FocusedFillImage to pan the
    /// crop toward the face instead of a plain center crop.
    var backgroundImageFocusX: Double?
    var backgroundImageFocusY: Double?
    var projectCount: Int
    let createdAt: Date

    var backgroundImageFocusPoint: UnitPoint? {
        guard let backgroundImageFocusX, let backgroundImageFocusY else { return nil }
        return UnitPoint(x: backgroundImageFocusX, y: backgroundImageFocusY)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, emoji
        case sortOrder = "sort_order"
        case backgroundImageURL = "background_image_url"
        case backgroundImageFocusX = "background_image_focus_x"
        case backgroundImageFocusY = "background_image_focus_y"
        case projectCount = "project_count"
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
    var folderId: String?
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
        case folderId = "folder_id"
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
        case todoLists = "todo_lists"
        case sections
    }
}

struct SceneDialogue: Codable, Identifiable, Hashable {
    let id: String
    let sceneId: String
    var text: String
    var done: Bool
    var sortOrder: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, text, done
        case sceneId = "scene_id"
        case sortOrder = "sort_order"
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
    var goodTakeFilename: String?
    let number: Int
    let letter: String?
    var priority: ShotPriority?
    /// Set once at creation (which FAB menu option was tapped), never
    /// changes after. Lighter-weight scenes for connective beats: no shot
    /// list, no priority shown on their tile — see ShotListView.sceneTile.
    var isIntermediateStep: Bool
    /// Individually-checkable dialogue lines ("+ Dialog" on the tile) —
    /// separate from `dialogue` above, which stays the single free-text
    /// quick-entry field for a brand-new scene that doesn't have an id yet.
    var dialogues: [SceneDialogue] = []
    /// A "Projektinfo" tile (2026-07-10 redesign, matches the web app's
    /// ProjectInfoTile) — a scene that drags/reorders/moves-between-sections
    /// exactly like any other scene (reuses the same drag machinery on
    /// purpose), but always renders full-width and always sorts first
    /// within whichever section (or "Ohne Abschnitt") it's in — see
    /// ShotListViewModel.scenes(in:). Never auto-creates a Section: the "+"
    /// menu's "Projektinfo" option creates this directly with no section_id
    /// (lands in "Ohne Abschnitt"), same as the web app.
    var isProjectInfo: Bool = false
    /// Only populated/used for a Projektinfo scene — its own todo lists, same
    /// idea as SceneSection.todoLists but scene-scoped (see
    /// Scene.isProjectInfo doc above; the section-scoped mechanism is legacy).
    var todoLists: [TodoList] = []
    /// Auftraggeber (2026-07-13, Lino) — only ever set/shown on
    /// isProjectInfo tiles, unused on normal scenes.
    var clientName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, description, dialogue, completed, number, letter, priority, dialogues
        case projectId = "project_id"
        case scheduledAt = "scheduled_at"
        case durationMinutes = "duration_minutes"
        case imageUrl = "image_url"
        case sortOrder = "sort_order"
        case assigneeId = "assignee_id"
        case sectionId = "section_id"
        case locationAddress = "location_address"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
        case goodTakeFilename = "good_take_filename"
        case isIntermediateStep = "is_intermediate_step"
        case isProjectInfo = "is_project_info"
        case todoLists = "todo_lists"
        case clientName = "client_name"
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
        case .must: return "Wichtig"
        case .should: return "Nice to have"
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
    // Camera settings (2026-07-13, Lino).
    var lens: String?
    var fStop: String?
    var frameRate: String?
    var shutterAngle: Double?
    var iso: Int?
    var codec: String?
    var cameraId: String?
    var cameraSupport: CameraSupport?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, description, priority, status, lens, iso, codec
        case projectId = "project_id"
        case sceneId = "scene_id"
        case imageUrl = "image_url"
        case durationSeconds = "duration_seconds"
        case cameraAngle = "camera_angle"
        case sortOrder = "sort_order"
        case goodTakeFilename = "good_take_filename"
        case fStop = "f_stop"
        case frameRate = "frame_rate"
        case shutterAngle = "shutter_angle"
        case cameraId = "camera_id"
        case cameraSupport = "camera_support"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum CameraSupport: String, Codable, CaseIterable, Identifiable {
    case gimbal, handheld, tripod
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gimbal: return "Gimbal"
        case .handheld: return "Handheld"
        case .tripod: return "Stativ"
        }
    }
}

struct Member: Codable, Identifiable, Hashable {
    var id: String { userId }
    let userId: String
    let email: String
    let name: String?
    let role: String
    /// Google/Apple OAuth profile picture, synced from Clerk at first login
    /// — nil for email/password accounts.
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case email, name, role
        case userId = "user_id"
        case avatarUrl = "avatar_url"
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
    /// Old attached-to-section mechanism (superseded by sceneId below, see
    /// Scene.isProjectInfo) — kept only so any pre-existing section-owned
    /// lists still decode.
    var sectionId: String?
    /// Set when this list belongs to a "Projektinfo" scene tile's own todo
    /// section (2026-07-10 redesign) — see Scene.isProjectInfo.
    var sceneId: String?
    var name: String
    var sortOrder: Int
    var items: [TodoItem]

    enum CodingKeys: String, CodingKey {
        case id, name, items
        case projectId = "project_id"
        case sectionId = "section_id"
        case sceneId = "scene_id"
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
    /// Multi-day shoots (2026-07-10): a section can optionally carry its own
    /// mini project-info box (shoot date/location/todo lists), same fields
    /// as Project's own top-level ones. false/nil fields = no box, not "box
    /// with empty fields" — see backend Section.has_project_info doc.
    var hasProjectInfo: Bool = false
    var shootDate: Date?
    var locationAddress: String?
    var locationLat: Double?
    var locationLng: Double?
    /// Same field as Project.clientName, kept in lockstep since this box
    /// mirrors the project-level Projektinfo tile field-for-field.
    var clientName: String?
    var todoLists: [TodoList] = []

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectId = "project_id"
        case sortOrder = "sort_order"
        case hasProjectInfo = "has_project_info"
        case shootDate = "shoot_date"
        case locationAddress = "location_address"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
        case clientName = "client_name"
        case todoLists = "todo_lists"
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

struct NotionDatabase: Codable, Identifiable, Hashable {
    let id: String
    let title: String
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
