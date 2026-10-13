import Foundation
import SwiftUI

// 2026-10-13 — Projektübersicht (web parity): search + step filter across every folder, pipeline
// rings / next date / client logo / storage on the tiles, the archive, the month calendar. Shapes
// mirror GET /projects/overview-meta and GET /me/calendar exactly.

struct OverviewStep: Codable, Equatable {
    let key: String          // ideas | scenes | postproduction | deliver
    let total: Int
    let decided: Int
    let done: Bool

    var ratio: Double { done ? 1 : (total > 0 ? Double(decided) / Double(total) : 0) }
}

struct OverviewNextEvent: Codable, Equatable {
    let kind: String         // shoot | deadline | deliver_expiry
    let at: String           // ISO date-time
    let overdue: Bool
    let label: String?

    var date: Date? { OverviewDates.parse(at) }
}

struct ProjectMeta: Codable, Equatable {
    let id: String
    let name: String
    let clientName: String?
    let folderId: String?
    let steps: [OverviewStep]
    let currentStep: String  // ideas | scenes | postproduction | deliver | done
    let nextEvent: OverviewNextEvent?
    let clientLogoUrl: String?
    let archived: Bool
    let storageBytes: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, steps, archived
        case clientName = "client_name"
        case folderId = "folder_id"
        case currentStep = "current_step"
        case nextEvent = "next_event"
        case clientLogoUrl = "client_logo_url"
        case storageBytes = "storage_bytes"
    }
}

struct CalendarEvent: Codable, Equatable, Identifiable {
    let kind: String         // shoot | deadline | deliver_expiry
    let date: String         // YYYY-MM-DD
    let start: String?
    let end: String?
    let scenes: Int?
    let label: String?
    let done: Bool?
    let projectId: String
    let sectionId: String?
    let projectName: String
    let clientName: String?
    let color: String?
    let emoji: String?
    let archived: Bool?

    var id: String { "\(kind)-\(projectId)-\(sectionId ?? "")-\(date)" }

    enum CodingKeys: String, CodingKey {
        case kind, date, start, end, scenes, label, done, color, emoji, archived
        case projectId = "project_id"
        case sectionId = "section_id"
        case projectName = "project_name"
        case clientName = "client_name"
    }
}

struct CalendarResponse: Codable {
    let events: [CalendarEvent]
}

enum OverviewDates {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }

    /// whole calendar days from today (negative = past)
    static func daysFromToday(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension APIClient {
    func overviewMeta() async throws -> [String: ProjectMeta] {
        let req = try await authorizedRequest("projects/overview-meta")
        return try await send(req)
    }

    /// every visible project of every folder — `archived: true` = only the archived ones
    func listAllProjects(archived: Bool) async throws -> [Project] {
        let req = try await authorizedRequest(archived ? "projects?archived=true" : "projects?all_folders=true")
        return try await send(req)
    }

    struct ArchiveResult: Decodable { let archived: Bool }

    func setProjectArchived(projectId: String, archived: Bool) async throws -> ArchiveResult {
        var req = try await authorizedRequest("projects/\(projectId)/archive", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let archived: Bool }
        req.httpBody = try encoder.encode(Body(archived: archived))
        return try await send(req)
    }

    func calendarEvents(from: String, to: String) async throws -> [CalendarEvent] {
        let req = try await authorizedRequest("me/calendar?from=\(from)&to=\(to)")
        let r: CalendarResponse = try await send(req)
        return r.events
    }
}
