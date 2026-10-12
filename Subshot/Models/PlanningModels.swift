import Foundation
import SwiftUI

// 2026-10-12 — web parity for the shot-list "am Set" features (weather per scene, Drehorte, live
// schedule, callsheet, Drehreihenfolge optimieren). Shapes mirror the backend JSON exactly; every
// field the backend may omit is Optional (the shared decoder has no default-value handling).

// MARK: - Weather per scene (GET /projects/{id}/scene-weather → [sceneId: SceneWeather])

struct SceneWeather: Codable, Equatable {
    let emoji: String
    let temp: Double
    let rainProb: Int?
    let wind: Double?
    let text: String

    enum CodingKeys: String, CodingKey {
        case emoji, temp, wind, text
        case rainProb = "rain_prob"
    }

    /// "🌤 14° · 10 %"
    var label: String {
        "\(emoji) \(Int(temp.rounded()))°" + (rainProb.map { " · \($0) %" } ?? "")
    }
}

// MARK: - Live schedule (GET /projects/{id}/live-schedule?date=)

struct LiveSchedule: Codable, Equatable {
    let date: String
    let now: String?
    let state: String               // empty | not_started | running | wrapped
    let delayMin: Int
    let plannedEnd: String?
    let projectedEnd: String?
    let current: String?
    let done: Int?
    let total: Int?
    let rows: [Row]
    let suggestions: [Suggestion]?
    let shorten: Shorten?
    let days: [String]?

    enum CodingKeys: String, CodingKey {
        case date, now, state, current, done, total, rows, suggestions, shorten, days
        case delayMin = "delay_min"
        case plannedEnd = "planned_end"
        case projectedEnd = "projected_end"
    }

    struct Row: Codable, Equatable, Identifiable {
        var id: String { sceneId }
        let sceneId: String
        let number: Int?
        let letter: String?
        let title: String
        let intermediate: Bool
        let priority: String?
        let minutes: Int?
        let plannedStart: String
        let plannedEnd: String
        let status: String          // done | not_shot | current | upcoming
        let doneAt: String?
        let newStart: String?

        enum CodingKeys: String, CodingKey {
            case number, letter, title, intermediate, priority, minutes, status
            case sceneId = "scene_id"
            case plannedStart = "planned_start"
            case plannedEnd = "planned_end"
            case doneAt = "done_at"
            case newStart = "new_start"
        }
    }

    struct Suggestion: Codable, Equatable, Identifiable {
        var id: String { sceneId }
        let sceneId: String
        let title: String
        let number: Int?
        let minutes: Int?
        let priority: String?
        enum CodingKeys: String, CodingKey {
            case title, number, minutes, priority
            case sceneId = "scene_id"
        }
    }

    struct Shorten: Codable, Equatable {
        let scenes: Int
        let minutesEach: Int
        enum CodingKeys: String, CodingKey {
            case scenes
            case minutesEach = "minutes_each"
        }
    }
}

// MARK: - Callsheet (GET /projects/{id}/callsheet/days, /callsheet?date=, /callsheet.pdf?date=)

struct CallsheetDay: Codable, Equatable, Identifiable {
    var id: String { date }
    let date: String
    let scenes: Int
    let start: String?
    let end: String?
    let locations: [String]?
}

struct CallsheetDaysResponse: Codable {
    let days: [CallsheetDay]
}

struct Callsheet: Codable, Equatable {
    let date: String
    let project: String
    let client: String?
    let start: String?
    let end: String?
    let rows: [Row]
    let locations: [Location]
    let crew: [Person]
    let team: [Person]
    let forecastFrom: String?

    enum CodingKeys: String, CodingKey {
        case date, project, client, start, end, rows, locations, crew, team
        case forecastFrom = "forecast_from"
    }

    struct Row: Codable, Equatable {
        let start: String?
        let end: String?
        let minutes: Int?
        let number: Int?
        let letter: String?
        let title: String
        let intermediate: Bool
        let location: Int?
        let assignees: [String]
        let weather: HourWeather?
    }

    struct HourWeather: Codable, Equatable {
        let temp: Double
        let rainProb: Int?
        let text: String
        let symbol: String
        enum CodingKeys: String, CodingKey {
            case temp, text, symbol
            case rainProb = "rain_prob"
        }
    }

    struct Location: Codable, Equatable, Identifiable {
        var id: Int { no }
        let no: Int
        let address: String?
        let lat: Double?
        let lng: Double?
        let maps: String?
        let weather: DayWeather?
        let sun: Sun?
    }

    struct DayWeather: Codable, Equatable {
        let tMin: Double?
        let tMax: Double?
        let rainProb: Int?
        let wind: Double?
        let text: String
        let symbol: String
        enum CodingKeys: String, CodingKey {
            case wind, text, symbol
            case tMin = "t_min"
            case tMax = "t_max"
            case rainProb = "rain_prob"
        }
    }

    struct Sun: Codable, Equatable {
        let sunrise: String?
        let sunset: String?
        let goldenMorning: String?
        let goldenEvening: String?
        let blueMorning: String?
        let blueEvening: String?
        enum CodingKeys: String, CodingKey {
            case sunrise, sunset
            case goldenMorning = "golden_morning"
            case goldenEvening = "golden_evening"
            case blueMorning = "blue_morning"
            case blueEvening = "blue_evening"
        }
    }

    struct Person: Codable, Equatable {
        let name: String?
        let email: String?
        let role: String?
    }
}

// MARK: - Drehreihenfolge optimieren (GET /sections/{id}/shooting-order/suggest)

struct ShootingOrderSuggestion: Codable, Equatable {
    let current: [String]
    let order: [String]
    let changed: Bool
    let reasons: [String: [String]]
    let before: Stats
    let after: Stats
    let scenes: [String: SceneInfo]

    struct Stats: Codable, Equatable {
        let locationChanges: Int
        let km: Double
        let rigChanges: Int
        let lensChanges: Int
        enum CodingKeys: String, CodingKey {
            case km
            case locationChanges = "location_changes"
            case rigChanges = "rig_changes"
            case lensChanges = "lens_changes"
        }
    }

    struct SceneInfo: Codable, Equatable {
        let light: String
        let place: String
        let rig: String
        let lenses: [String]
        let location: String?
    }
}

// MARK: - Drehorte (places of a shotlist, one colour each — same palette/order as the web app)

struct ShotlistPlace: Equatable, Identifiable {
    var id: String { address }
    let address: String
    let lat: Double?
    let lng: Double?
    let color: Color
    let isDefault: Bool

    /// "Bahnhofstrasse 1" of "Bahnhofstrasse 1, 8001 Zürich"
    var short: String { ShotlistPlace.short(address) }
    static func short(_ address: String) -> String {
        address.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? address
    }

    static let palette: [Color] = ["#0a84ff", "#30d158", "#ff9f0a", "#bf5af2", "#ff375f", "#64d2ff", "#ffd60a", "#ac8e68"].map { Color(hex: $0) }

    /// default place first, then the scenes' own places in Szenen-Reihenfolge (+ extra ones)
    static func build(section: SceneSection?, scenes: [Scene], extra: [(String, Double?, Double?)] = []) -> [ShotlistPlace] {
        var list: [ShotlistPlace] = []
        func push(_ address: String?, _ lat: Double?, _ lng: Double?) {
            guard let address, !address.isEmpty, !list.contains(where: { $0.address == address }) else { return }
            list.append(ShotlistPlace(address: address, lat: lat, lng: lng,
                                      color: palette[list.count % palette.count],
                                      isDefault: section?.locationAddress == address))
        }
        push(section?.locationAddress, section?.locationLat, section?.locationLng)
        for s in scenes where !s.isProjectInfo && !s.isIntermediateStep {
            push(s.locationAddress, s.locationLat, s.locationLng)
        }
        for e in extra { push(e.0, e.1, e.2) }
        return list
    }

    static func mapsURL(_ address: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/maps/search/")
        c?.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: address)]
        return c?.url
    }
}
