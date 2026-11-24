import Foundation

// 2026-11-17 (b113) — Post-production catch-up with the web: languages, bulk edit / delete,
// reprocess, upload progress. Same endpoints the web page uses (lib/api.ts).

extension APIClient {
    /// `GET /projects/{id}/videos` — every video of the project in one call (web: listProjectVideos)
    func listProjectVideos(projectId: String) async throws -> [Video] {
        let req = try await authorizedRequest("projects/\(projectId)/videos")
        return try await send(req)
    }

    // MARK: Languages

    func projectLanguages(projectId: String) async throws -> PostproLanguagesOverview {
        let req = try await authorizedRequest("projects/\(projectId)/languages")
        return try await send(req)
    }

    func createProjectLanguage(projectId: String, name: String, flag: String) async throws -> PostproLanguagesOverview {
        var req = try await authorizedRequest("projects/\(projectId)/languages", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let flag: String }
        req.httpBody = try encoder.encode(Body(name: name, flag: flag))
        return try await send(req)
    }

    func updateProjectLanguage(_ id: String, name: String, flag: String) async throws -> PostproLanguagesOverview {
        var req = try await authorizedRequest("project-languages/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String; let flag: String }
        req.httpBody = try encoder.encode(Body(name: name, flag: flag))
        return try await send(req)
    }

    func deleteProjectLanguage(_ id: String) async throws -> PostproLanguagesOverview {
        let req = try await authorizedRequest("project-languages/\(id)", method: "DELETE")
        return try await send(req)
    }

    /// `PUT /projects/{id}/video-languages` — `languageId: nil` = «Nicht zugeordnet»
    func assignVideoLanguages(projectId: String, videoIds: [String], languageId: String?) async throws -> PostproLanguagesOverview {
        var req = try await authorizedRequest("projects/\(projectId)/video-languages", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let video_ids: [String]
            let language_id: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(video_ids, forKey: .video_ids)
                try c.encode(language_id, forKey: .language_id) // explicit null
            }
            enum CodingKeys: String, CodingKey { case video_ids, language_id }
        }
        req.httpBody = try encoder.encode(Body(video_ids: videoIds, language_id: languageId))
        return try await send(req)
    }

    // MARK: Bulk

    enum BulkChange {
        /// nil = «Kein Editor»
        case editor(String?)
        case status(PostproductionStatus)
        /// mode "add" keeps the existing icons, "replace" sets exactly these ([] = no icon)
        case platforms([String], mode: String)
    }

    /// `PATCH /projects/{id}/videos/bulk` — same rules as the single tile changes (server side)
    func bulkUpdateVideos(projectId: String, videoIds: [String], change: BulkChange) async throws -> BulkUpdateResult {
        var req = try await authorizedRequest("projects/\(projectId)/videos/bulk", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["video_ids": videoIds]
        switch change {
        case .editor(let id): body["editor_id"] = id ?? NSNull() // explicit null = no editor
        case .status(let s): body["status"] = s.rawValue
        case .platforms(let ps, let mode):
            body["platforms"] = ps
            body["platforms_mode"] = mode
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    /// `POST /projects/{id}/videos/bulk-delete` — the server also removes the R2 files
    func bulkDeleteVideos(projectId: String, videoIds: [String]) async throws -> BulkDeleteResult {
        var req = try await authorizedRequest("projects/\(projectId)/videos/bulk-delete", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let video_ids: [String] }
        req.httpBody = try encoder.encode(Body(video_ids: videoIds))
        return try await send(req)
    }

    /// `POST /video-versions/{id}/reprocess` — «Erneut versuchen» on a tile whose processing failed
    func reprocessVersion(_ id: String) async throws {
        let req = try await authorizedRequest("video-versions/\(id)/reprocess", method: "POST")
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Direct device → R2 PUT with progress (0…1), streamed from disk.
    func uploadVideoFile(to presignedURL: URL, fileURL: URL, contentType: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        var req = URLRequest(url: presignedURL)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // exactly the size announced with size_bytes (the presigned URL is signed for it)
        if let size = UploadLimitProblem.fileSize(fileURL) { req.setValue(String(size), forHTTPHeaderField: "Content-Length") }
        let delegate = UploadProgressDelegate(onProgress: progress)
        let (_, response) = try await URLSession.shared.upload(for: req, fromFile: fileURL, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "R2 upload failed")
        }
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated let onProgress: @Sendable (Double) -> Void
    nonisolated init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

extension APIClient {
    struct SubmitFeedbackResult: Decodable {
        let ok: Bool
        let feedback_locked: Bool?
        let already_locked: Bool?
        let comments_notified: Int?
    }

    /// 2026-11-17 (b113) — «Feedback abschliessen» for signed-in editors+:
    /// `POST /video-versions/{id}/submit-feedback` (no body; idempotent; 409 = a newer ready version
    /// exists → the server's detail text is shown).
    func submitVideoFeedback(versionId: String) async throws -> SubmitFeedbackResult {
        let req = try await authorizedRequest("video-versions/\(versionId)/submit-feedback", method: "POST")
        return try await send(req)
    }
}
