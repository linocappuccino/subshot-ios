import Foundation

// 2026-10-12 — Postproduction endpoints (web parity): Fassungen + licences, technical check,
// feedback rounds.

extension APIClient {
    // MARK: Fassungen

    func videoExtras(projectId: String) async throws -> [String: VideoExtras] {
        let req = try await authorizedRequest("projects/\(projectId)/video-extras")
        return try await send(req)
    }

    func createDeliverable(videoId: String, label: String) async throws -> VideoDeliverable {
        var req = try await authorizedRequest("videos/\(videoId)/deliverables", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let label: String }
        req.httpBody = try encoder.encode(Body(label: label))
        return try await send(req)
    }

    func deleteDeliverable(_ id: String) async throws {
        let req = try await authorizedRequest("video-deliverables/\(id)", method: "DELETE")
        try await sendNoContent(req)
    }

    struct UploadTicket: Decodable { let id: String; let upload_url: String }

    /// upload a (new) file for a Fassung: presigned PUT, then "complete"
    func uploadDeliverable(_ id: String, fileURL: URL) async throws -> VideoDeliverable {
        let ext = fileURL.pathExtension.lowercased()
        let contentType = ext == "mov" ? "video/quicktime" : ext == "mp4" || ext == "m4v" ? "video/mp4" : "application/octet-stream"
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        var req = try await authorizedRequest("video-deliverables/\(id)/upload", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let filename: String; let content_type: String; let file_size_bytes: Int? }
        req.httpBody = try encoder.encode(Body(filename: fileURL.lastPathComponent, content_type: contentType, file_size_bytes: size))
        let ticket: UploadTicket = try await send(req)
        guard let url = URL(string: ticket.upload_url) else { throw APIError.network(URLError(.badURL)) }
        try await uploadVideoFile(to: url, fileURL: fileURL, contentType: contentType)
        let done = try await authorizedRequest("video-deliverables/\(id)/complete", method: "POST")
        return try await send(done)
    }

    struct DownloadURL: Decodable { let url: String }

    func deliverableDownloadURL(_ id: String) async throws -> URL {
        let req = try await authorizedRequest("video-deliverables/\(id)/download-url")
        let r: DownloadURL = try await send(req)
        guard let url = URL(string: r.url) else { throw APIError.network(URLError(.badURL)) }
        return url
    }

    // MARK: Technischer Check

    func videoQC(projectId: String, target: Double) async throws -> [String: VideoQC] {
        let req = try await authorizedRequest("projects/\(projectId)/video-qc?target=\(Int(target))")
        return try await send(req)
    }

    func rerunVideoQC(versionId: String) async throws {
        let req = try await authorizedRequest("video-versions/\(versionId)/qc", method: "POST")
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: Feedback-Runden

    func feedbackRounds(projectId: String) async throws -> FeedbackRounds {
        let req = try await authorizedRequest("projects/\(projectId)/feedback-rounds")
        return try await send(req)
    }

    func setVideoRoundLimit(videoId: String, limit: Int?) async throws {
        var req = try await authorizedRequest("videos/\(videoId)/round-limit", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let round_limit: Int? }
        req.httpBody = try encoder.encode(Body(round_limit: limit))
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
