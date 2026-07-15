import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum APIError: Error, LocalizedError {
    case notAuthenticated
    case server(status: Int, message: String)
    case decoding(Error)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Nicht angemeldet."
        case .server(let status, let message): return "Serverfehler (\(status)): \(message)"
        case .decoding: return "Antwort konnte nicht gelesen werden."
        case .network(let e): return "Verbindungsfehler: \(e.localizedDescription)"
        }
    }

    /// A request cancelled mid-flight (e.g. pull-to-refresh released while
    /// the previous load was still running, or the view disappearing) isn't
    /// a real failure — it's expected, benign, and shouldn't ever reach the
    /// user as "Fehler: Verbindungsfehler: cancelled" (2026-07-13, Lino).
    /// Callers that show `errorMessage` from a `.refreshable`/load path
    /// should check this before doing so.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .network(let inner) = error as? APIError, (inner as? URLError)?.code == .cancelled { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

/// Thin async/await wrapper around the Subshot backend. Every call attaches the
/// current Clerk session token as a Bearer header via `tokenProvider` — injected
/// rather than imported directly so this file has no hard Clerk SDK dependency.
final class APIClient {
    static let shared = APIClient()

    // subshot.ch, live since 2026-07-08 (nginx + certbot on the same server
    // as subli.ch, proxying straight to the backend on :8010 — no more
    // /subshot-test/ path prefix now that it has its own domain).
    var baseURL = URL(string: "https://subshot.ch")!

    /// Set by the app at launch to `{ try await Clerk.shared.session?.getToken() }`.
    var tokenProvider: (() async throws -> String?)?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private func authorizedRequest(_ path: String, method: String = "GET") async throws -> URLRequest {
        guard let token = try await tokenProvider?(), !token.isEmpty else {
            throw APIError.notAuthenticated
        }
        // Some paths come from the backend already prefixed with "/" (e.g.
        // shot.imageUrl); strip it so appendingPathComponent never double-slashes.
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Split off any query string ourselves — appendingPathComponent
        // percent-encodes "?"/"=" as literal path characters instead of
        // treating them as a query string, which 404s every call site that
        // passes one (found via /projects?folder_id=... always 404ing: the
        // folder move itself succeeded server-side, the project just never
        // showed up because listing its new folder's contents always failed
        // — same root cause silently broke /me/notifications?unread_only=
        // too, from the very first version of this client).
        let pathOnly: String
        let query: String?
        if let qIndex = cleanPath.firstIndex(of: "?") {
            pathOnly = String(cleanPath[cleanPath.startIndex..<qIndex])
            query = String(cleanPath[cleanPath.index(after: qIndex)...])
        } else {
            pathOnly = cleanPath
            query = nil
        }
        var components = URLComponents(url: baseURL.appendingPathComponent(pathOnly), resolvingAgainstBaseURL: false)
        if let query {
            components?.percentEncodedQuery = query
        }
        guard let url = components?.url else {
            throw APIError.network(URLError(.badURL))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(status: http.statusCode, message: message)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func sendNoContent(_ req: URLRequest) async throws {
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(status: http.statusCode, message: message)
        }
    }

    private func perform(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error)
        }
    }

    // MARK: - Me

    func me() async throws -> Me {
        let req = try await authorizedRequest("me")
        return try await send(req)
    }

    func knownCollaborators() async throws -> [Member] {
        let req = try await authorizedRequest("me/known-collaborators")
        return try await send(req)
    }

    // MARK: - Projects

    /// nil = root level (folder_id IS NULL on the backend), a folder's id =
    /// that folder's contents.
    func listProjects(folderId: String? = nil) async throws -> [Project] {
        let path = folderId.map { "projects?folder_id=\($0)" } ?? "projects"
        let req = try await authorizedRequest(path)
        return try await send(req)
    }

    func createProject(name: String, color: String, emoji: String? = nil, folderId: String? = nil, sortOrder: Int = 0) async throws -> Project {
        var req = try await authorizedRequest("projects", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let color: String; let emoji: String?; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(name: name, color: color, emoji: emoji, sort_order: sortOrder))
        let project: Project = try await send(req)
        // Creation has no folder_id param server-side (ProjectCreate doesn't
        // carry one) — a second patch is the simplest way to land a new
        // project directly inside the folder it was created from.
        guard let folderId else { return project }
        return try await patchProject(project.id, folderId: folderId)
    }

    func getProject(_ id: String) async throws -> ProjectDetail {
        let req = try await authorizedRequest("projects/\(id)")
        return try await send(req)
    }

    func patchProject(
        _ id: String, name: String? = nil, color: String? = nil,
        emoji: String? = nil, clearEmoji: Bool = false,
        shootDate: Date? = nil, locationAddress: String? = nil,
        locationLat: Double? = nil, locationLng: Double? = nil,
        clearLocation: Bool = false,
        clientName: String? = nil,
        folderId: String? = nil, clearFolder: Bool = false, sortOrder: Int? = nil
    ) async throws -> Project {
        var req = try await authorizedRequest("projects/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let name: String?; let color: String?
            let emoji: String?; let clear_emoji: Bool
            let shoot_date: Date?
            let location_address: String?; let location_lat: Double?; let location_lng: Double?
            let clear_location: Bool
            let client_name: String?
            let folder_id: String?; let clear_folder: Bool
            let sort_order: Int?
        }
        req.httpBody = try encoder.encode(Body(
            name: name, color: color, emoji: emoji, clear_emoji: clearEmoji, shoot_date: shootDate,
            location_address: locationAddress, location_lat: locationLat, location_lng: locationLng,
            clear_location: clearLocation,
            client_name: clientName,
            folder_id: folderId, clear_folder: clearFolder, sort_order: sortOrder
        ))
        return try await send(req)
    }

    func deleteProject(_ id: String) async throws {
        let req = try await authorizedRequest("projects/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    // MARK: - Folders

    func listFolders() async throws -> [ProjectFolder] {
        let req = try await authorizedRequest("folders")
        return try await send(req)
    }

    func createFolder(name: String, color: String? = nil, emoji: String? = nil, sortOrder: Int) async throws -> ProjectFolder {
        var req = try await authorizedRequest("folders", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let color: String?; let emoji: String?; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(name: name, color: color, emoji: emoji, sort_order: sortOrder))
        return try await send(req)
    }

    func patchFolder(
        _ id: String, name: String? = nil, color: String? = nil,
        emoji: String? = nil, clearEmoji: Bool = false, sortOrder: Int? = nil,
        clearBackgroundImage: Bool = false
    ) async throws -> ProjectFolder {
        var req = try await authorizedRequest("folders/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let name: String?; let color: String?
            let emoji: String?; let clear_emoji: Bool
            let sort_order: Int?
            let clear_background_image: Bool
        }
        req.httpBody = try encoder.encode(Body(name: name, color: color, emoji: emoji, clear_emoji: clearEmoji, sort_order: sortOrder, clear_background_image: clearBackgroundImage))
        return try await send(req)
    }

    func deleteFolder(_ id: String) async throws {
        let req = try await authorizedRequest("folders/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    #if canImport(UIKit)
    func uploadFolderImage(folderId: String, image: UIImage) async throws -> ProjectFolder {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw APIError.network(URLError(.cannotCreateFile))
        }
        var req = try await authorizedRequest("folders/\(folderId)/image", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"folder.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        return try await send(req)
    }
    #endif

    struct ShareLinkResult: Decodable { let url: String; let expires_at: Date; let has_password: Bool }

    /// Idempotent server-side — calling this again just returns/extends the
    /// same link rather than minting a new URL (see get_or_create_share_link).
    /// `password`/`clearPassword` are optional on purpose: omitting both
    /// leaves whatever password an existing link already had untouched, so
    /// re-sharing without touching password settings can't silently wipe one.
    func projectShareLink(_ id: String, password: String? = nil, clearPassword: Bool = false) async throws -> ShareLinkResult {
        var req = try await authorizedRequest("projects/\(id)/share-link", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let password: String?; let clear_password: Bool }
        req.httpBody = try encoder.encode(Body(password: password, clear_password: clearPassword))
        return try await send(req)
    }

    func projectPdf(_ id: String, view: String = "cards") async throws -> Data {
        let req = try await authorizedRequest("projects/\(id)/pdf?view=\(view)")
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: message)
        }
        return data
    }

    // MARK: - Scenes

    func createScene(
        projectId: String, name: String?, color: String,
        description: String? = nil, dialogue: String? = nil,
        scheduledAt: Date? = nil, durationMinutes: Int? = nil,
        assigneeId: String? = nil, sectionId: String? = nil, sortOrder: Int = 0,
        locationAddress: String? = nil, locationLat: Double? = nil, locationLng: Double? = nil,
        priority: ShotPriority? = nil, isIntermediateStep: Bool = false, isProjectInfo: Bool = false
    ) async throws -> Scene {
        var req = try await authorizedRequest("projects/\(projectId)/scenes", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let name: String?; let color: String; let description: String?
            let dialogue: String?; let scheduled_at: Date?
            let duration_minutes: Int?; let assignee_id: String?; let section_id: String?
            let sort_order: Int
            let location_address: String?; let location_lat: Double?; let location_lng: Double?
            let priority: String?
            let is_intermediate_step: Bool
            let is_project_info: Bool
        }
        req.httpBody = try encoder.encode(Body(
            name: name, color: color, description: description,
            dialogue: dialogue, scheduled_at: scheduledAt,
            duration_minutes: durationMinutes, assignee_id: assigneeId, section_id: sectionId,
            sort_order: sortOrder,
            location_address: locationAddress, location_lat: locationLat, location_lng: locationLng,
            priority: priority?.rawValue, is_intermediate_step: isIntermediateStep,
            is_project_info: isProjectInfo
        ))
        return try await send(req)
    }

    /// `clearAssignee`/`clearSection`/`clearLocation` mirror the backend's
    /// ScenePatch escape hatches — a plain nil assigneeId/sectionId/location
    /// here means "don't touch it", not "remove it" (same convention as
    /// patchTodoItem).
    func patchScene(
        _ id: String, name: String? = nil, color: String? = nil,
        description: String? = nil, dialogue: String? = nil,
        scheduledAt: Date? = nil, durationMinutes: Int? = nil, completed: Bool? = nil,
        assigneeId: String? = nil, clearAssignee: Bool = false,
        assigneeIds: [String]? = nil,
        sectionId: String? = nil, clearSection: Bool = false, sortOrder: Int? = nil,
        locationAddress: String? = nil, locationLat: Double? = nil, locationLng: Double? = nil,
        clearLocation: Bool = false,
        clientName: String? = nil,
        priority: ShotPriority? = nil, clearPriority: Bool = false,
        goodTakeFilename: String? = nil, clearGoodTake: Bool = false,
        // 2026-07-15, Lino: no way to remove a scene's cover photo, only
        // replace it (matches patchShotFull's clearImage, which shots
        // already had) — mirrors that same clear_image escape hatch
        // server-side (ScenePatch.clear_image, added same day).
        clearImage: Bool = false,
        // Explicit delta (seconds) for the server-side time-cascade
        // (2026-07-13, see patch_scene in the backend) — shifts every other
        // same-day-after scene in the project by this much, server-side, so
        // web and iOS always compute the identical result. Not inferred
        // from a before/after diff of THIS call's scheduledAt — the edit
        // and the cascade confirmation are two separate round-trips (the
        // scene is already saved by the time the confirmation dialog is
        // even answered), so pass the delta explicitly.
        cascadeShiftSeconds: Double? = nil
    ) async throws -> Scene {
        var req = try await authorizedRequest("scenes/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let name: String?; let color: String?; let description: String?
            let dialogue: String?; let scheduled_at: Date?
            let duration_minutes: Int?; let completed: Bool?
            let assignee_id: String?; let clear_assignee: Bool
            let assignee_ids: [String]?
            let section_id: String?; let clear_section: Bool
            let sort_order: Int?
            let location_address: String?; let location_lat: Double?; let location_lng: Double?
            let clear_location: Bool
            let client_name: String?
            let priority: String?; let clear_priority: Bool
            let good_take_filename: String?; let clear_good_take: Bool
            let clear_image: Bool
            let cascade_shift_seconds: Double?
        }
        req.httpBody = try encoder.encode(Body(
            name: name, color: color, description: description,
            dialogue: dialogue, scheduled_at: scheduledAt,
            duration_minutes: durationMinutes, completed: completed,
            assignee_id: assigneeId, clear_assignee: clearAssignee,
            assignee_ids: assigneeIds,
            section_id: sectionId, clear_section: clearSection,
            sort_order: sortOrder,
            location_address: locationAddress, location_lat: locationLat, location_lng: locationLng,
            clear_location: clearLocation,
            client_name: clientName,
            priority: priority?.rawValue, clear_priority: clearPriority,
            good_take_filename: goodTakeFilename, clear_good_take: clearGoodTake,
            clear_image: clearImage,
            cascade_shift_seconds: cascadeShiftSeconds
        ))
        return try await send(req)
    }

    /// AI scene image (2026-07-15) — sourced entirely from the scene's own
    /// description server-side, no prompt param here. `style` is
    /// "realistic" or "sketch", `aspectRatio` "16:9" or "9:16" (see
    /// SceneEditSheet's pickers). Fire-and-forget: the backend queues the
    /// job as a background task and responds with 202 immediately, NOT
    /// once the image is actually ready (Lino: "man muss die möglichkeit
    /// haben die seite zu schliessen und die generierung läuft im
    /// hintergrund weiter") — the scene's imageUrl updates server-side
    /// once RunPod finishes, and ShotListView's existing 12s poll picks it
    /// up on its own, whether or not this sheet is still open by then. No
    /// long client-side timeout needed anymore since this call itself
    /// returns fast.
    struct GenerateImageAck: Decodable { let status: String }

    func generateSceneImage(_ sceneId: String, style: String, aspectRatio: String) async throws -> GenerateImageAck {
        var req = try await authorizedRequest("scenes/\(sceneId)/generate-image", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let style: String; let aspect_ratio: String }
        req.httpBody = try encoder.encode(Body(style: style, aspect_ratio: aspectRatio))
        return try await send(req)
    }

    /// Repositions a scene relative to its siblings — server renumbers just
    /// this scene (screenplay-style: stable numbers, letter suffix if it
    /// lands in a gap between two already-numbered scenes). Replaces the old
    /// client-computed multi-PATCH reorder for scenes specifically.
    func moveScene(_ id: String, beforeSceneId: String?) async throws -> Scene {
        var req = try await authorizedRequest("scenes/\(id)/move", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let before_scene_id: String? }
        req.httpBody = try encoder.encode(Body(before_scene_id: beforeSceneId))
        return try await send(req)
    }

    /// Auto-sort button (2026-07-13, Lino) — takes the full target order for
    /// one section (or the unsectioned bucket, sectionId nil) in a single
    /// request instead of one moveScene call per scene, same reasoning as
    /// the other bulk "server already knows the whole order" endpoints.
    func reorderScenes(projectId: String, sectionId: String?, orderedSceneIds: [String]) async throws -> [Scene] {
        var req = try await authorizedRequest("projects/\(projectId)/scenes/reorder", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let section_id: String?; let ordered_scene_ids: [String] }
        req.httpBody = try encoder.encode(Body(section_id: sectionId, ordered_scene_ids: orderedSceneIds))
        return try await send(req)
    }

    /// Server-authoritative reorder (2026-07-13) — same shared endpoint the
    /// web app now calls too, replacing what used to be a client-computed
    /// multi-PATCH loop independently implemented on both platforms.
    func moveSection(_ id: String, beforeSectionId: String?) async throws -> SceneSection {
        var req = try await authorizedRequest("sections/\(id)/move", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let before_section_id: String? }
        req.httpBody = try encoder.encode(Body(before_section_id: beforeSectionId))
        return try await send(req)
    }

    func moveShot(_ id: String, beforeShotId: String?) async throws -> Shot {
        var req = try await authorizedRequest("shots/\(id)/move", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let before_shot_id: String? }
        req.httpBody = try encoder.encode(Body(before_shot_id: beforeShotId))
        return try await send(req)
    }

    func moveProject(_ id: String, beforeProjectId: String?) async throws -> Project {
        var req = try await authorizedRequest("projects/\(id)/move", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let before_project_id: String? }
        req.httpBody = try encoder.encode(Body(before_project_id: beforeProjectId))
        return try await send(req)
    }

    func moveFolder(_ id: String, beforeFolderId: String?) async throws -> ProjectFolder {
        var req = try await authorizedRequest("folders/\(id)/move", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let before_folder_id: String? }
        req.httpBody = try encoder.encode(Body(before_folder_id: beforeFolderId))
        return try await send(req)
    }

    func deleteScene(_ id: String) async throws {
        let req = try await authorizedRequest("scenes/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    /// Copies a scene server-side, landing right after the original in the
    /// same section (see duplicate_scene in main.py — matches the web app's
    /// api.duplicateScene exactly). No request body; the backend decides
    /// what to copy vs. reset.
    func duplicateScene(_ id: String) async throws -> Scene {
        let req = try await authorizedRequest("scenes/\(id)/duplicate", method: "POST")
        return try await send(req)
    }

    // MARK: - Scene dialogues

    func createSceneDialogue(sceneId: String, text: String, sortOrder: Int = 0) async throws -> SceneDialogue {
        var req = try await authorizedRequest("scenes/\(sceneId)/dialogues", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let text: String; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(text: text, sort_order: sortOrder))
        return try await send(req)
    }

    func patchSceneDialogue(_ id: String, text: String? = nil, done: Bool? = nil) async throws -> SceneDialogue {
        var req = try await authorizedRequest("dialogues/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let text: String?; let done: Bool? }
        req.httpBody = try encoder.encode(Body(text: text, done: done))
        return try await send(req)
    }

    func deleteSceneDialogue(_ id: String) async throws {
        let req = try await authorizedRequest("dialogues/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    #if canImport(UIKit)
    func uploadSceneImage(sceneId: String, image: UIImage) async throws -> Scene {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw APIError.network(URLError(.cannotCreateFile))
        }
        var req = try await authorizedRequest("scenes/\(sceneId)/image", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"scene.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        return try await send(req)
    }
    #endif

    // MARK: - Shots

    struct ShotCreateBody: Encodable {
        var scene_id: String?
        var description: String?
        var duration_seconds: Int?
        var camera_angle: String?
        var priority: String?
        var sort_order: Int = 0
        var lens: String?
        var f_stop: String?
        var frame_rate: String?
        var shutter_angle: Double?
        var iso: Int?
        var codec: String?
        var camera_id: String?
        var camera_support: String?
    }

    func createShot(projectId: String, body: ShotCreateBody) async throws -> Shot {
        var req = try await authorizedRequest("projects/\(projectId)/shots", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        return try await send(req)
    }

    struct ShotPatchBody: Encodable {
        var scene_id: String??
        var image_url: String??
        var description: String??
        var duration_seconds: Int??
        var camera_angle: String??
        var priority: String??
        var status: String?
        var sort_order: Int?
    }

    /// Partial update — only non-nil fields in `body` are sent, so e.g. patching
    /// just `status` never clobbers `description` etc. (mirrors the backend's
    /// ShotPatch, where every field is optional and omitted ones are untouched).
    func patchShot(_ id: String, status: String) async throws -> Shot {
        var req = try await authorizedRequest("shots/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["status": status])
        return try await send(req)
    }

    /// Used by ShotDetailSheet, which always edits the full set of these fields
    /// at once — so unlike other patch calls, `nil` here means "clear this
    /// field to null" (sent explicitly as JSON null), not "leave untouched".
    /// A form that only ever changes one field at a time should NOT reuse this
    /// method as-is, or it'll wipe the others.
    func patchShotFull(
        _ id: String,
        description: String?,
        durationSeconds: Int?,
        cameraAngle: String?,
        priority: String?,
        goodTakeFilename: String?,
        lens: String? = nil,
        fStop: String? = nil,
        frameRate: String? = nil,
        shutterAngle: Double? = nil,
        iso: Int? = nil,
        codec: String? = nil,
        cameraId: String? = nil,
        cameraSupport: String? = nil,
        // "Foto entfernen" (2026-07-14) — a plain image_url:null in this
        // same dict WOULD already null the column (image_url is one of the
        // generic model_fields_set-driven fields on the backend), but that
        // alone leaves the uploaded file orphaned on disk. clear_image
        // additionally tells the backend to delete the file itself
        // (mirrors delete_shot's own _delete_shot_image_file cleanup).
        clearImage: Bool = false
    ) async throws -> Shot {
        var req = try await authorizedRequest("shots/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "description": description ?? NSNull(),
            "duration_seconds": durationSeconds ?? NSNull(),
            "camera_angle": cameraAngle ?? NSNull(),
            "priority": priority ?? NSNull(),
            "good_take_filename": goodTakeFilename ?? NSNull(),
            "lens": lens ?? NSNull(),
            "f_stop": fStop ?? NSNull(),
            "frame_rate": frameRate ?? NSNull(),
            "shutter_angle": shutterAngle ?? NSNull(),
            "iso": iso ?? NSNull(),
            "codec": codec ?? NSNull(),
            "camera_id": cameraId ?? NSNull(),
            "camera_support": cameraSupport ?? NSNull(),
            "clear_image": clearImage,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await send(req)
    }

    func patchShot(_ id: String, sceneId: String) async throws -> Shot {
        var req = try await authorizedRequest("shots/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["scene_id": sceneId])
        return try await send(req)
    }

    /// Drag & drop: reassigns scene (nil = unassigned) and position in one
    /// call. Unlike `patchShot(_:sceneId:)` above, `sceneId` here can be
    /// explicitly null'd out (moving a shot back to "kein Szene"), so this
    /// builds the JSON body by hand like `patchShotFull` does.
    func moveShot(_ id: String, sceneId: String?, sortOrder: Int) async throws -> Shot {
        var req = try await authorizedRequest("shots/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "scene_id": sceneId ?? NSNull(),
            "sort_order": sortOrder,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await send(req)
    }

    func deleteShot(_ id: String) async throws {
        let req = try await authorizedRequest("shots/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    #if canImport(UIKit)
    func uploadShotImage(shotId: String, image: UIImage) async throws -> Shot {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw APIError.network(URLError(.cannotCreateFile))
        }
        var req = try await authorizedRequest("shots/\(shotId)/image", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"shot.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        return try await send(req)
    }

    func fetchImage(path: String) async throws -> UIImage {
        let req = try await authorizedRequest(path)
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Image fetch failed")
        }
        guard let image = UIImage(data: data) else {
            throw APIError.decoding(URLError(.cannotDecodeContentData))
        }
        return image
    }
    #endif

    // MARK: - Push notifications

    /// Called once SubshotApp's AppDelegate gets a device token back from
    /// didRegisterForRemoteNotificationsWithDeviceToken — see app/push.py for
    /// what still needs setting up server-side (and the Xcode "Push
    /// Notifications" capability, without which registration itself never
    /// succeeds on-device) before APNs actually delivers anything.
    func registerDeviceToken(_ token: String) async throws {
        var req = try await authorizedRequest("me/device-token", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let token: String; let platform: String }
        req.httpBody = try encoder.encode(Body(token: token, platform: "ios"))
        try await sendNoContent(req)
    }

    // MARK: - Notion import

    func setNotionToken(_ token: String) async throws {
        var req = try await authorizedRequest("me/notion-token", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["token": token])
        try await sendNoContent(req)
    }

    func notionDatabases() async throws -> [NotionDatabase] {
        let req = try await authorizedRequest("me/notion-databases")
        return try await send(req)
    }

    struct NotionImportResult: Decodable { let imported: Int }

    func importNotionScenes(projectId: String, databaseId: String) async throws -> Int {
        var req = try await authorizedRequest("projects/\(projectId)/import-notion", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["database_id": databaseId])
        let result: NotionImportResult = try await send(req)
        return result.imported
    }

    // MARK: - Team

    func members(projectId: String) async throws -> [Member] {
        let req = try await authorizedRequest("projects/\(projectId)/members")
        return try await send(req)
    }

    func invite(projectId: String, email: String, role: String) async throws -> Invite {
        var req = try await authorizedRequest("projects/\(projectId)/invite", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["email": email, "role": role])
        return try await send(req)
    }

    func removeMember(projectId: String, userId: String) async throws {
        let req = try await authorizedRequest("projects/\(projectId)/members/\(userId)", method: "DELETE")
        try await sendNoContent(req)
    }

    // MARK: - Todo lists

    func createTodoList(projectId: String, name: String, sortOrder: Int) async throws -> TodoList {
        var req = try await authorizedRequest("projects/\(projectId)/todo-lists", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(name: name, sort_order: sortOrder))
        return try await send(req)
    }

    /// Same shape as createTodoList above, but scoped to a section's own
    /// project-info box (multi-day shoots) instead of the project-level one
    /// — see POST /sections/{id}/todo-lists on the backend.
    func createSectionTodoList(sectionId: String, name: String, sortOrder: Int) async throws -> TodoList {
        var req = try await authorizedRequest("sections/\(sectionId)/todo-lists", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(name: name, sort_order: sortOrder))
        return try await send(req)
    }

    /// Same shape as createTodoList/createSectionTodoList above, but scoped
    /// to a "Projektinfo" scene tile's own todo section — see
    /// POST /scenes/{id}/todo-lists on the backend.
    func createSceneTodoList(sceneId: String, name: String, sortOrder: Int) async throws -> TodoList {
        var req = try await authorizedRequest("scenes/\(sceneId)/todo-lists", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(name: name, sort_order: sortOrder))
        return try await send(req)
    }

    func patchTodoList(_ id: String, name: String) async throws -> TodoList {
        var req = try await authorizedRequest("todo-lists/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["name": name])
        return try await send(req)
    }

    func deleteTodoList(_ id: String) async throws {
        let req = try await authorizedRequest("todo-lists/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    func createTodoItem(todoListId: String, text: String, assigneeId: String? = nil, sortOrder: Int) async throws -> TodoItem {
        var req = try await authorizedRequest("todo-lists/\(todoListId)/items", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let text: String; let assignee_id: String?; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(text: text, assignee_id: assigneeId, sort_order: sortOrder))
        return try await send(req)
    }

    /// Partial update, same "only non-nil is sent" convention as patchScene —
    /// `clearAssignee` is the explicit escape hatch to unassign (mirrors the
    /// backend's ScenePatch.clear_assignee), since a plain nil assigneeId here
    /// means "don't touch it", not "remove it".
    func patchTodoItem(
        _ id: String, text: String? = nil, done: Bool? = nil,
        assigneeId: String? = nil, clearAssignee: Bool = false, sortOrder: Int? = nil
    ) async throws -> TodoItem {
        var req = try await authorizedRequest("todo-items/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let text: String?; let done: Bool?; let assignee_id: String?
            let clear_assignee: Bool; let sort_order: Int?
        }
        req.httpBody = try encoder.encode(Body(
            text: text, done: done, assignee_id: assigneeId,
            clear_assignee: clearAssignee, sort_order: sortOrder
        ))
        return try await send(req)
    }

    func deleteTodoItem(_ id: String) async throws {
        let req = try await authorizedRequest("todo-items/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    // MARK: - Sections

    func createSection(projectId: String, name: String, sortOrder: Int) async throws -> SceneSection {
        var req = try await authorizedRequest("projects/\(projectId)/sections", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(name: name, sort_order: sortOrder))
        return try await send(req)
    }

    func patchSection(
        _ id: String, name: String? = nil, sortOrder: Int? = nil,
        shootDate: Date? = nil, locationAddress: String? = nil, locationLat: Double? = nil, locationLng: Double? = nil,
        clearLocation: Bool = false,
        clientName: String? = nil,
        addProjectInfo: Bool = false, removeProjectInfo: Bool = false
    ) async throws -> SceneSection {
        var req = try await authorizedRequest("sections/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let name: String?; let sort_order: Int?
            let shoot_date: Date?; let location_address: String?; let location_lat: Double?; let location_lng: Double?
            let clear_location: Bool
            let client_name: String?
            let add_project_info: Bool; let remove_project_info: Bool
        }
        req.httpBody = try encoder.encode(Body(
            name: name, sort_order: sortOrder,
            shoot_date: shootDate, location_address: locationAddress, location_lat: locationLat, location_lng: locationLng,
            clear_location: clearLocation,
            client_name: clientName,
            add_project_info: addProjectInfo, remove_project_info: removeProjectInfo
        ))
        return try await send(req)
    }

    func deleteSection(_ id: String) async throws {
        let req = try await authorizedRequest("sections/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    // MARK: - Geocoding

    struct GeocodeSuggestion: Decodable {
        let display_name: String
        let lat: Double?
        let lng: Double?
        let place_id: String?
    }

    struct GeocodeResolved: Decodable {
        let display_name: String
        let lat: Double
        let lng: Double
    }

    /// Same Google-Places-backed (Nominatim-fallback) search the web app
    /// uses, see app/mapping.py's geocode_search doc comment — replaces the
    /// iOS app's old on-device MKLocalSearchCompleter (Apple Maps data has
    /// near-zero business/POI coverage, the actual "Adresssuche funktioniert
    /// nicht" complaint). `sessionToken` should be one UUID reused across
    /// every keystroke of a single search and passed again to
    /// geocodeResolve on pick, then replaced — see LocationSearchCompleter.
    func geocodeSearch(query: String, sessionToken: String) async throws -> [GeocodeSuggestion] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let token = sessionToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionToken
        let req = try await authorizedRequest("geocode/search?q=\(q)&session_token=\(token)")
        return try await send(req)
    }

    /// Resolves a Google Autocomplete suggestion's place_id into an address +
    /// coordinates (the Nominatim path already carries coordinates inline,
    /// see LocationSearch.resolve — this is only called for a Google pick).
    func geocodeResolve(placeId: String, sessionToken: String) async throws -> GeocodeResolved {
        let id = placeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? placeId
        let token = sessionToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionToken
        let req = try await authorizedRequest("geocode/resolve?place_id=\(id)&session_token=\(token)")
        return try await send(req)
    }

    // MARK: - Notifications

    func notifications(unreadOnly: Bool = true) async throws -> [AppNotification] {
        let req = try await authorizedRequest("me/notifications?unread_only=\(unreadOnly)")
        return try await send(req)
    }

    func markNotificationRead(_ id: String) async throws -> AppNotification {
        let req = try await authorizedRequest("me/notifications/\(id)/read", method: "POST")
        return try await send(req)
    }

    func markAllNotificationsRead() async throws {
        let req = try await authorizedRequest("me/notifications/read-all", method: "POST")
        try await sendNoContent(req)
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    /// The backend emits e.g. "2026-07-07T17:04:43.435429Z" — standard
    /// `.iso8601` can't parse the fractional seconds, so use a formatter that can.
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
    }
}
