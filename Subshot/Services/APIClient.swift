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
}

/// Thin async/await wrapper around the Subshot backend. Every call attaches the
/// current Clerk session token as a Bearer header via `tokenProvider` — injected
/// rather than imported directly so this file has no hard Clerk SDK dependency.
final class APIClient {
    static let shared = APIClient()

    // TODO: point this at the real production domain once Subshot has its own
    // (subshot.app / subshot.ch, see project spec §1). Using the temporary
    // dev.subli.ch path-proxy for now, same one used for backend validation.
    var baseURL = URL(string: "https://dev.subli.ch/subshot-test")!

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

    func createProject(name: String, color: String, folderId: String? = nil) async throws -> Project {
        var req = try await authorizedRequest("projects", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["name": name, "color": color])
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
        shootDate: Date? = nil, locationAddress: String? = nil,
        locationLat: Double? = nil, locationLng: Double? = nil,
        folderId: String? = nil, clearFolder: Bool = false
    ) async throws -> Project {
        var req = try await authorizedRequest("projects/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let name: String?; let color: String?; let shoot_date: Date?
            let location_address: String?; let location_lat: Double?; let location_lng: Double?
            let folder_id: String?; let clear_folder: Bool
        }
        req.httpBody = try encoder.encode(Body(
            name: name, color: color, shoot_date: shootDate,
            location_address: locationAddress, location_lat: locationLat, location_lng: locationLng,
            folder_id: folderId, clear_folder: clearFolder
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

    func createFolder(name: String, sortOrder: Int) async throws -> ProjectFolder {
        var req = try await authorizedRequest("folders", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let sort_order: Int }
        req.httpBody = try encoder.encode(Body(name: name, sort_order: sortOrder))
        return try await send(req)
    }

    func patchFolder(_ id: String, name: String? = nil, sortOrder: Int? = nil) async throws -> ProjectFolder {
        var req = try await authorizedRequest("folders/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String?; let sort_order: Int? }
        req.httpBody = try encoder.encode(Body(name: name, sort_order: sortOrder))
        return try await send(req)
    }

    func deleteFolder(_ id: String) async throws {
        let req = try await authorizedRequest("folders/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    func projectPdf(_ id: String) async throws -> Data {
        let req = try await authorizedRequest("projects/\(id)/pdf")
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
        description: String? = nil, dialogue: String? = nil, focalLengthMm: Int? = nil,
        scheduledAt: Date? = nil, durationMinutes: Int? = nil,
        assigneeId: String? = nil, sectionId: String? = nil, sortOrder: Int = 0,
        locationAddress: String? = nil, locationLat: Double? = nil, locationLng: Double? = nil,
        priority: ShotPriority? = nil
    ) async throws -> Scene {
        var req = try await authorizedRequest("projects/\(projectId)/scenes", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let name: String?; let color: String; let description: String?
            let dialogue: String?; let focal_length_mm: Int?; let scheduled_at: Date?
            let duration_minutes: Int?; let assignee_id: String?; let section_id: String?
            let sort_order: Int
            let location_address: String?; let location_lat: Double?; let location_lng: Double?
            let priority: String?
        }
        req.httpBody = try encoder.encode(Body(
            name: name, color: color, description: description,
            dialogue: dialogue, focal_length_mm: focalLengthMm, scheduled_at: scheduledAt,
            duration_minutes: durationMinutes, assignee_id: assigneeId, section_id: sectionId,
            sort_order: sortOrder,
            location_address: locationAddress, location_lat: locationLat, location_lng: locationLng,
            priority: priority?.rawValue
        ))
        return try await send(req)
    }

    /// `clearAssignee`/`clearSection`/`clearLocation` mirror the backend's
    /// ScenePatch escape hatches — a plain nil assigneeId/sectionId/location
    /// here means "don't touch it", not "remove it" (same convention as
    /// patchTodoItem).
    func patchScene(
        _ id: String, name: String? = nil, color: String? = nil,
        description: String? = nil, dialogue: String? = nil, focalLengthMm: Int? = nil,
        scheduledAt: Date? = nil, durationMinutes: Int? = nil, completed: Bool? = nil,
        assigneeId: String? = nil, clearAssignee: Bool = false,
        sectionId: String? = nil, clearSection: Bool = false, sortOrder: Int? = nil,
        locationAddress: String? = nil, locationLat: Double? = nil, locationLng: Double? = nil,
        clearLocation: Bool = false,
        priority: ShotPriority? = nil, clearPriority: Bool = false
    ) async throws -> Scene {
        var req = try await authorizedRequest("scenes/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let name: String?; let color: String?; let description: String?
            let dialogue: String?; let focal_length_mm: Int?; let scheduled_at: Date?
            let duration_minutes: Int?; let completed: Bool?
            let assignee_id: String?; let clear_assignee: Bool
            let section_id: String?; let clear_section: Bool
            let sort_order: Int?
            let location_address: String?; let location_lat: Double?; let location_lng: Double?
            let clear_location: Bool
            let priority: String?; let clear_priority: Bool
        }
        req.httpBody = try encoder.encode(Body(
            name: name, color: color, description: description,
            dialogue: dialogue, focal_length_mm: focalLengthMm, scheduled_at: scheduledAt,
            duration_minutes: durationMinutes, completed: completed,
            assignee_id: assigneeId, clear_assignee: clearAssignee,
            section_id: sectionId, clear_section: clearSection,
            sort_order: sortOrder,
            location_address: locationAddress, location_lat: locationLat, location_lng: locationLng,
            clear_location: clearLocation,
            priority: priority?.rawValue, clear_priority: clearPriority
        ))
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

    func deleteScene(_ id: String) async throws {
        let req = try await authorizedRequest("scenes/\(id)", method: "DELETE")
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
        goodTakeFilename: String?
    ) async throws -> Shot {
        var req = try await authorizedRequest("shots/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "description": description ?? NSNull(),
            "duration_seconds": durationSeconds ?? NSNull(),
            "camera_angle": cameraAngle ?? NSNull(),
            "priority": priority ?? NSNull(),
            "good_take_filename": goodTakeFilename ?? NSNull(),
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

    func patchSection(_ id: String, name: String? = nil, sortOrder: Int? = nil) async throws -> SceneSection {
        var req = try await authorizedRequest("sections/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String?; let sort_order: Int? }
        req.httpBody = try encoder.encode(Body(name: name, sort_order: sortOrder))
        return try await send(req)
    }

    func deleteSection(_ id: String) async throws {
        let req = try await authorizedRequest("sections/\(id)", method: "DELETE")
        try await sendNoContent(req)
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
