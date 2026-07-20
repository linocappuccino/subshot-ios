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
    /// Pipeline-Module-Checkboxen (2026-07-17, #96 — erster Baustein der
    /// "Grossen Pipeline-Vision"). Rein informativ fuer jetzt, kein
    /// Freischalt-Gate. 2026-07-19: moduleVideoFeedback entfernt, gleiche
    /// Begruendung wie Web (siehe ProjectEditModal.tsx) — Postproduction
    /// Tracking und Video Feedback sind das gleiche Modul jetzt.
    var moduleConcept: Bool = true
    var moduleScripting: Bool = true
    var modulePostproduction: Bool = true

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
        case moduleConcept = "module_concept"
        case moduleScripting = "module_scripting"
        case modulePostproduction = "module_postproduction"
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
    /// 2026-07-20 — folders can nest (web #249, 2026-07-19); this iOS model
    /// never picked up `folder_count`/`parent_folder_id` even though the
    /// backend's FolderOut always sent them, so a folder containing only a
    /// SUBFOLDER (no direct project) looked like an empty dead end here —
    /// its real content (a project nested one level deeper) was completely
    /// unreachable, see ProjectListView's own updated doc comment.
    var folderCount: Int
    var parentFolderId: String?
    let createdAt: Date

    var backgroundImageFocusPoint: UnitPoint? {
        guard let backgroundImageFocusX, let backgroundImageFocusY else { return nil }
        return UnitPoint(x: backgroundImageFocusX, y: backgroundImageFocusY)
    }

    /// Same wording/branching as the web app's projects/page.tsx folder tile
    /// subtitle — a folder holding only subfolders (no direct project) used
    /// to just show "0 Projekte" here, indistinguishable from a genuinely
    /// empty folder even though real content sat one level deeper.
    var tileSubtitle: String {
        let projectPart = "\(projectCount) Projekt\(projectCount == 1 ? "" : "e")"
        guard folderCount > 0 else { return projectPart }
        return "\(folderCount) Ordner, \(projectPart)"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, emoji
        case sortOrder = "sort_order"
        case backgroundImageURL = "background_image_url"
        case backgroundImageFocusX = "background_image_focus_x"
        case backgroundImageFocusY = "background_image_focus_y"
        case projectCount = "project_count"
        case folderCount = "folder_count"
        case parentFolderId = "parent_folder_id"
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
    var clientName: String?
    let lastOpenedAt: Date
    let createdAt: Date
    var scenes: [Scene]
    var shots: [Shot]
    var todoLists: [TodoList]
    var sections: [SceneSection]
    /// Pipeline-Module-Checkboxen (#96) — hier nur modulePostproduction
    /// gebraucht, um den Postproduction-Tab (#11 Schritt 5+6) ein-/
    /// auszublenden.
    var modulePostproduction: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, color, scenes, shots
        case shootDate = "shoot_date"
        case locationAddress = "location_address"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
        case folderId = "folder_id"
        case clientName = "client_name"
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
        case todoLists = "todo_lists"
        case sections
        case modulePostproduction = "module_postproduction"
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
    /// Persistent AI-image-generation lock (2026-07-16) — survives sheet
    /// close/reopen and app relaunch, unlike a local-only "just tapped"
    /// flag, since the actual RunPod job runs well after this scene's
    /// response already came back. Mirrors the web app's own
    /// `existing.image_generating` (see SceneEditModal.tsx).
    var imageGenerating: Bool = false
    var completed: Bool
    var sortOrder: Int
    var assigneeId: String?
    /// 2026-07-14, Lino: "mehrere Personen auswählen können" — replaces
    /// assigneeId as the source of truth for display/editing; assigneeId
    /// stays for backward compat (see backend Scene.assignee_id doc
    /// comment) but is no longer written to.
    var assigneeIds: [String] = []
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
        case imageGenerating = "image_generating"
        case sortOrder = "sort_order"
        case assigneeId = "assignee_id"
        case assigneeIds = "assignee_ids"
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

    /// Same palette as the web app's PRIORITY_COLORS (lib/types.ts) and the
    /// share_view.py PDF/preview export — must=red, should=orange,
    /// optional=blue, kept in one place (2026-07-17) so every picker that
    /// shows a priority's own color (not just a generic accent) stays in
    /// sync with the other two clients by construction, not by copy-paste.
    var color: Color {
        switch self {
        case .must: return .red
        case .should: return .orange
        case .optional: return Color(red: 0x3d / 255.0, green: 0x84 / 255.0, blue: 0xd8 / 255.0)
        }
    }

    /// "Keine" (no priority set) isn't a case of the enum itself (priority
    /// is `ShotPriority?` everywhere it's stored) — this is the color for
    /// that nil state, same neutral gray as the web app's PRIORITY_COLORS[null].
    static let noneColor = Color(.systemGray3)
}

enum ShotStatus: String, Codable {
    case open, done, deleted
}

// MARK: - Ideas (Planungssektor)
//
// 2026-07-17 — ported from the web app (app/projects/[id]/page.tsx's
// IdeaGrid + backend app/schemas.py's IdeaOut/IdeaImageOut/IdeaFeedbackOut).
// An Idea lives in a project's "Planungssektor", the stage BEFORE the
// Scripting-Tool (Sections/Scenes/Shots above): title + free text + up to
// 10 images, client feedback collected via a public no-login share link
// (feedback itself is written on the WEB share page only — this app is
// PL-facing read-only for feedback, see IdeaFeedbackSheet), "Abgenommen"
// converts it into a real Section + Scene (see approveIdea).
//
// NOT included in ProjectDetail (unlike Scene/Shot/TodoList/SceneSection)
// — ideas are always a separate `listIdeas` round trip on the web app too,
// so ShotListViewModel.loadIdeas() is its own call, same pattern as its
// existing independent `members` fetch in load().

enum IdeaStatus: String, Codable {
    case open, approved
}

enum IdeaImageStatus: String, Codable {
    case ready, generating
}

enum IdeaImageSource: String, Codable {
    case upload, ai
}

struct IdeaImage: Codable, Identifiable, Hashable {
    let id: String
    let ideaId: String
    var imageUrl: String?
    var source: IdeaImageSource
    var status: IdeaImageStatus
    var sortOrder: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, source, status
        case ideaId = "idea_id"
        case imageUrl = "image_url"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }
}

/// Client comment on an Idea, left from the public share page (no login) —
/// read-only here, this app never writes one. `status`: "draft" (client
/// saved but hasn't sent yet, 2026-07-17) or "sent" (final/locked) — see
/// backend IdeaFeedback's own doc comment. Only "sent" ones are ever
/// included in an Idea's `feedbackCount` or in `GET /ideas/{id}/feedback`
/// (drafts are filtered out server-side), so every IdeaFeedback this app
/// ever sees is already final.
/// 2026-07-18, web-parity: `round`/`resolved` added alongside the web app's
/// same-day IdeaFeedback additions (see [[feedback_ios_web_parity]]) — round
/// groups entries into "01 Feedback"/"02 Feedback"/... (see
/// IdeaFeedbackSheet), resolved is the PL-side "abgehakt" toggle.
struct IdeaFeedback: Codable, Identifiable, Hashable {
    let id: String
    let ideaId: String
    var authorName: String
    var comment: String
    var status: String
    var round: Int
    var resolved: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, comment, status, round, resolved
        case ideaId = "idea_id"
        case authorName = "author_name"
        case createdAt = "created_at"
    }
}

struct Idea: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    var title: String
    /// May contain a small whitelisted set of rich-text HTML tags
    /// (`<b>/<strong>/<i>/<em>/<br>/<div>`) written by the web app's
    /// RichTextEditor — this app has no rich-text editor of its own (see
    /// IdeaEditSheet), so it edits/displays this as plain text. `plainText`
    /// below strips tags for anywhere a preview snippet is needed, mirroring
    /// the web app's IdeaTile.tsx textPreview regex.
    var text: String
    var sortOrder: Int
    var status: IdeaStatus
    var sectionId: String?
    var sceneId: String?
    let createdAt: Date
    /// Wann die Idee angenommen wurde (2026-07-17) — nil solange status
    /// "open" ist, einmalig gesetzt beim Wechsel zu "approved".
    var approvedAt: Date?
    var images: [IdeaImage] = []
    /// Count of "sent" client feedback only (drafts never counted) — drives
    /// the Idee/1. Feedback/2. Feedback/Abgenommen grouping, see
    /// IdeaStatusGroup below. Not a mapped DB column server-side (see
    /// backend IdeaOut.feedback_count's own doc comment), always present in
    /// every response regardless.
    var feedbackCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, title, text, status, images
        case projectId = "project_id"
        case sortOrder = "sort_order"
        case sectionId = "section_id"
        case sceneId = "scene_id"
        case createdAt = "created_at"
        case approvedAt = "approved_at"
        case feedbackCount = "feedback_count"
    }

    var plainText: String {
        var result = ""
        var insideTag = false
        for ch in text {
            if ch == "<" { insideTag = true }
            else if ch == ">" { insideTag = false }
            else if !insideTag { result.append(ch) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var readyImages: [IdeaImage] {
        images.filter { $0.status == .ready && $0.imageUrl != nil }
    }

    var isGeneratingAnyImage: Bool {
        images.contains { $0.status == .generating }
    }
}

/// Idee / 1. Feedback / 2. Feedback / Abgenommen (2026-07-17, Lino — same
/// grouping as the web app's IdeaGrid.tsx IDEA_STATUS_GROUPS) — purely
/// derived from status/feedbackCount, never set directly.
enum IdeaStatusGroup: Int, CaseIterable, Hashable {
    case idea, firstFeedback, secondFeedback, approved

    var label: String {
        switch self {
        case .idea: return "Idee"
        case .firstFeedback: return "1. Feedback"
        case .secondFeedback: return "2. Feedback"
        case .approved: return "Abgenommen"
        }
    }

    static func of(_ idea: Idea) -> IdeaStatusGroup {
        if idea.status == .approved { return .approved }
        if idea.feedbackCount >= 2 { return .secondFeedback }
        if idea.feedbackCount == 1 { return .firstFeedback }
        return .idea
    }
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
    /// Postproduction-Tracking (2026-07-17, #11 Schritt 5+6). Eine Section
    /// wandert erst nach expliziter Bestaetigung ("Alle Szenen im Kasten?
    /// Ab in die Postproduction?") ins Tracking, nicht automatisch.
    var inPostproduction: Bool = false
    var postproductionStatus: PostproductionStatus?
    var postproductionDeadline: Date?

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
        case inPostproduction = "in_postproduction"
        case postproductionStatus = "postproduction_status"
        case postproductionDeadline = "postproduction_deadline"
    }
}

enum PostproductionStatus: String, Codable, CaseIterable {
    case wartend, inBearbeitung = "in_bearbeitung", wartetAufFeedback = "wartet_auf_feedback"
    case abgeschlossen, abgelehnt

    var label: String {
        switch self {
        case .wartend: return "Wartend"
        case .inBearbeitung: return "In Bearbeitung"
        case .wartetAufFeedback: return "Wartet auf Feedback"
        case .abgeschlossen: return "Abgeschlossen"
        case .abgelehnt: return "Abgelehnt"
        }
    }
}

/// Video-Feedback-Tool (2026-07-17, #11 Schritt 7) — haengt an einer
/// SceneSection (siehe backend Video's Doc-Kommentar: 0-n Videos pro
/// Section, jedes mit eigener VideoVersion-Historie).
struct Video: Codable, Identifiable, Hashable {
    let id: String
    let sectionId: String
    var title: String
    var sortOrder: Int
    let createdAt: Date
    var versions: [VideoVersion] = []

    enum CodingKeys: String, CodingKey {
        case id, title, versions
        case sectionId = "section_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }
}

struct VideoVersion: Codable, Identifiable, Hashable {
    let id: String
    let videoId: String
    var versionNumber: Int
    var originalFilename: String?
    var contentType: String?
    var fileSizeBytes: Int?
    var durationSeconds: Double?
    var status: String
    let createdAt: Date
    /// Presigned R2 URL, frisch pro Response generiert. Bei einer gerade
    /// erst erzeugten ('uploading') Version ist das die presigned PUT-
    /// Ziel-URL fuer den Upload, nicht zum Abspielen — siehe backend
    /// create_video_version's Doc-Kommentar, dasselbe Feld fuer beide
    /// Richtungen.
    var playbackUrl: String?
    var comments: [VideoComment] = []

    enum CodingKeys: String, CodingKey {
        case id, status, comments
        case videoId = "video_id"
        case versionNumber = "version_number"
        case originalFilename = "original_filename"
        case contentType = "content_type"
        case fileSizeBytes = "file_size_bytes"
        case durationSeconds = "duration_seconds"
        case createdAt = "created_at"
        case playbackUrl = "playback_url"
    }
}

struct VideoComment: Codable, Identifiable, Hashable {
    let id: String
    let versionId: String
    var timestampSeconds: Double
    var authorName: String
    var comment: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, comment
        case versionId = "version_id"
        case timestampSeconds = "timestamp_seconds"
        case authorName = "author_name"
        case createdAt = "created_at"
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
