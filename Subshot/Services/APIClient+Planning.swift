import Foundation

// 2026-10-12 — endpoints for the shot-list "am Set" features (web parity): weather per scene,
// Drehorte bulk assignment, live schedule, callsheet (+ PDF), Drehreihenfolge optimieren.

extension APIClient {
    // MARK: Weather

    func sceneWeather(projectId: String) async throws -> [String: SceneWeather] {
        let req = try await authorizedRequest("projects/\(projectId)/scene-weather")
        return try await send(req)
    }

    // MARK: Drehorte

    /// one place for many scenes of a shotlist; `address == nil` removes their own place
    /// (they follow the shotlist's default place again)
    func assignSceneLocation(sectionId: String, sceneIds: [String], address: String?, lat: Double?, lng: Double?) async throws -> [Scene] {
        var req = try await authorizedRequest("sections/\(sectionId)/scenes/assign-location", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let scene_ids: [String]; let location_address: String?; let location_lat: Double?; let location_lng: Double? }
        req.httpBody = try encoder.encode(Body(scene_ids: sceneIds, location_address: address, location_lat: lat, location_lng: lng))
        return try await send(req)
    }

    // MARK: Live schedule

    func liveSchedule(projectId: String, date: String? = nil) async throws -> LiveSchedule {
        let req = try await authorizedRequest("projects/\(projectId)/live-schedule" + (date.map { "?date=\($0)" } ?? ""))
        return try await send(req)
    }

    struct AutoScheduleResult: Decodable { let updated: Int; let end: String? }

    /// the given scenes, in this order, get back-to-back start times from `start` ("HH:MM") on
    func autoSchedule(projectId: String, date: String, start: String, sceneIds: [String]) async throws -> AutoScheduleResult {
        var req = try await authorizedRequest("projects/\(projectId)/schedule/auto", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let date: String; let start: String; let scene_ids: [String] }
        req.httpBody = try encoder.encode(Body(date: date, start: start, scene_ids: sceneIds))
        return try await send(req)
    }

    // MARK: Callsheet

    func callsheetDays(projectId: String) async throws -> [CallsheetDay] {
        let req = try await authorizedRequest("projects/\(projectId)/callsheet/days")
        let r: CallsheetDaysResponse = try await send(req)
        return r.days
    }

    func callsheet(projectId: String, date: String) async throws -> Callsheet {
        let req = try await authorizedRequest("projects/\(projectId)/callsheet?date=\(date)")
        return try await send(req)
    }

    /// the PDF, saved to a temp file (for the share sheet)
    func callsheetPDF(projectId: String, date: String, filename: String) async throws -> URL {
        let req = try await authorizedRequest("projects/\(projectId)/callsheet.pdf?date=\(date)")
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: String(data: data, encoding: .utf8) ?? "")
        }
        let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Drehreihenfolge optimieren

    func suggestShootingOrder(sectionId: String) async throws -> ShootingOrderSuggestion {
        let req = try await authorizedRequest("sections/\(sectionId)/shooting-order/suggest")
        return try await send(req)
    }
}
