import Foundation

/// 2026-11-17 (b113, web parity) — 1:1 port of web's lib/postproFilter.ts (server: app/postpro_filter.py).
/// Lino's hard rule: «Filter und Zähler müssen zu 100 Prozent stimmen» — ONE function for counting
/// and filtering. Faceted rule: the counter of a chip = the number of videos that match the OTHER
/// two active filters AND this chip, so tapping a chip shows exactly the number it showed.
/// «none» = no language / no platform icon; «other» = any format outside the five categories.
struct PostproFilter: Equatable {
    var lang: String = "all"
    var fmt: String = "all"
    var plat: String = "all"

    var isActive: Bool { lang != "all" || fmt != "all" || plat != "all" }

    static let platformKeys = ["youtube", "instagram", "meta", "tiktok"]
    static let formatKeys = ["9:16", "16:9", "1:1", "4:5", "5:4"]

    struct Context {
        var assignments: [String: String]
        var formats: [String: String]
    }

    struct FacetCounts {
        var lang: [String: Int] = ["all": 0]
        var fmt: [String: Int] = ["all": 0]
        var plat: [String: Int] = ["all": 0]
        /// every format / platform that occurs in the whole list (chips stay visible with 0)
        var presentFmt: [String] = []
        var presentPlat: [String] = []
    }

    /// all platform icons of a video, fixed order (web: platformsOf)
    static func platforms(of v: Video) -> [String] {
        let ps = (v.platforms?.isEmpty == false ? v.platforms! : nil) ?? v.platform.map { [$0] } ?? []
        return platformKeys.filter { ps.contains($0) }
    }

    static func langKey(of v: Video, _ ctx: Context) -> String {
        if let l = ctx.assignments[v.id], !l.isEmpty { return l }
        return "none"
    }

    static func fmtKey(of v: Video, _ ctx: Context) -> String {
        if let f = ctx.formats[v.id], formatKeys.contains(f) { return f }
        return "other"
    }

    private func langOk(_ v: Video, _ ctx: Context) -> Bool { lang == "all" || Self.langKey(of: v, ctx) == lang }
    private func fmtOk(_ v: Video, _ ctx: Context) -> Bool { fmt == "all" || Self.fmtKey(of: v, ctx) == fmt }
    private func platOk(_ v: Video) -> Bool {
        if plat == "all" { return true }
        let ps = Self.platforms(of: v)
        return plat == "none" ? ps.isEmpty : ps.contains(plat)
    }

    func matches(_ v: Video, _ ctx: Context) -> Bool { langOk(v, ctx) && fmtOk(v, ctx) && platOk(v) }

    func filter(_ videos: [Video], _ ctx: Context) -> [Video] { videos.filter { matches($0, ctx) } }

    /// counters for every chip; key «all» = the «Alle» chip of that row
    func facetCounts(_ videos: [Video], _ ctx: Context) -> FacetCounts {
        var c = FacetCounts()
        var pf = Set<String>(), pp = Set<String>()
        for v in videos {
            pf.insert(Self.fmtKey(of: v, ctx))
            let ps = Self.platforms(of: v)
            if ps.isEmpty { pp.insert("none") }
            ps.forEach { pp.insert($0) }
            let l = langOk(v, ctx), fo = fmtOk(v, ctx), p = platOk(v)
            if fo && p {
                c.lang["all", default: 0] += 1
                c.lang[Self.langKey(of: v, ctx), default: 0] += 1
            }
            if l && p {
                c.fmt["all", default: 0] += 1
                c.fmt[Self.fmtKey(of: v, ctx), default: 0] += 1
            }
            if l && fo {
                c.plat["all", default: 0] += 1
                if ps.isEmpty { c.plat["none", default: 0] += 1 }
                for k in ps { c.plat[k, default: 0] += 1 }
            }
        }
        c.presentFmt = Self.formatKeys.filter { pf.contains($0) } + (pf.contains("other") ? ["other"] : [])
        c.presentPlat = Self.platformKeys.filter { pp.contains($0) } + (pp.contains("none") ? ["none"] : [])
        return c
    }
}

extension VideoVersion {
    /// lenient: with or without fractional seconds / zone (no zone = UTC, like the server)
    var processingStartedDate: Date? {
        guard let raw = processingStartedAt, !raw.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            f.formatOptions = opts
            if let d = f.date(from: raw) { return d }
        }
        let noZone = raw.contains("Z") || raw.contains("+") ? raw : raw + "Z"
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            f.formatOptions = opts
            if let d = f.date(from: noZone) { return d }
        }
        return nil
    }
}

/// `GET /projects/{id}/languages` (app/postpro_languages.overview) — same shape as web's LanguagesOverview
struct PostproLanguagesOverview: Codable, Equatable {
    struct Language: Codable, Equatable, Identifiable, Hashable {
        let id: String
        var name: String
        var flag: String
        var sortOrder: Int
        var count: Int
        enum CodingKeys: String, CodingKey {
            case id, name, flag, count
            case sortOrder = "sort_order"
        }
    }
    var languages: [Language] = []
    var assignments: [String: String] = [:]
    var unassigned: Int = 0
    var formats: [String: String]? = nil

    static let empty = PostproLanguagesOverview()
}

/// `PATCH /projects/{id}/videos/bulk` answer
struct BulkUpdateResult: Decodable {
    struct Failure: Decodable { let video_id: String; let error: String }
    let updated: [String]
    let failed: [Failure]
}

/// `POST /projects/{id}/videos/bulk-delete` answer
struct BulkDeleteResult: Decodable {
    struct Deleted: Decodable { let video_id: String; let title: String? }
    struct Failure: Decodable { let video_id: String; let error: String }
    let deleted: [Deleted]
    let failed: [Failure]
}

/// 2026-11-17 — the language list of web's PostproLanguages.tsx (LANGUAGE_LIST): the language is
/// picked, its flag comes with it (the server sets the flag from the name anyway).
enum PostproLanguageCatalog {
    struct Entry: Hashable { let code: String; let name: String; let flag: String }
    static let list: [Entry] = raw.map { Entry(code: $0.0, name: $0.1, flag: $0.2) }
    private static let raw: [(String, String, String)] = [
        ("de", "Deutsch", "🇩🇪"), ("gsw", "Schweizerdeutsch", "🇨🇭"), ("de-AT", "Deutsch (Österreich)", "🇦🇹"),
        ("fr", "Französisch", "🇫🇷"), ("it", "Italienisch", "🇮🇹"), ("rm", "Rätoromanisch", "🇨🇭"),
        ("en", "Englisch", "🇬🇧"), ("en-US", "Englisch (US)", "🇺🇸"), ("es", "Spanisch", "🇪🇸"),
        ("pt", "Portugiesisch", "🇵🇹"), ("nl", "Niederländisch", "🇳🇱"), ("pl", "Polnisch", "🇵🇱"),
        ("tr", "Türkisch", "🇹🇷"), ("sq", "Albanisch", "🇦🇱"), ("hr", "Kroatisch", "🇭🇷"),
        ("sr", "Serbisch", "🇷🇸"), ("uk", "Ukrainisch", "🇺🇦"), ("ru", "Russisch", "🇷🇺"),
        ("el", "Griechisch", "🇬🇷"), ("sv", "Schwedisch", "🇸🇪"), ("da", "Dänisch", "🇩🇰"),
        ("no", "Norwegisch", "🇳🇴"), ("fi", "Finnisch", "🇫🇮"), ("zh", "Chinesisch", "🇨🇳"),
        ("ja", "Japanisch", "🇯🇵"), ("ko", "Koreanisch", "🇰🇷"), ("ar", "Arabisch", "🇸🇦"), ("hi", "Hindi", "🇮🇳"),
    ]

    private static let codes: [String: String] = [
        "deutsch (österreich)": "AT", "englisch (us)": "US", "englisch (usa)": "US", "amerikanisch": "US", "schwiizerdütsch": "CH",
        "deutsch": "DE", "hochdeutsch": "DE", "german": "DE", "schweizerdeutsch": "CH", "mundart": "CH", "swiss german": "CH",
        "französisch": "FR", "franzoesisch": "FR", "french": "FR", "italienisch": "IT", "italian": "IT", "englisch": "EN",
        "english": "EN", "rätoromanisch": "RM", "romanisch": "RM", "spanisch": "ES", "portugiesisch": "PT",
        "niederländisch": "NL", "polnisch": "PL", "türkisch": "TR", "albanisch": "SQ", "kroatisch": "HR", "serbisch": "SR",
        "ukrainisch": "UK", "russisch": "RU",
    ]

    /// «DE» — the short code of a language name (web: langCode)
    static func code(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let c = codes[n] { return c }
        let letters = n.filter { ("a"..."z").contains(String($0)) || "äöü".contains($0) }
        return String(letters.prefix(2)).uppercased()
    }
}

/// 2026-11-19 (Lino: «in der shotlist noch super viele andere shotlisten … die nicht da sein sollten») — the same
/// rule as the website's shot list (subshot-web app/projects/[id]/page.tsx:1813, since 2026-11-18): a section is a
/// shot list unless it is «unplanned» (one uploaded video) or sits in post-production without any scene (the
/// DaVinci plugin's / upload's video groups). Those stay visible in Post-production; they are never deleted.
enum ShotlistFilter {
    static func isShotlist(_ section: SceneSection, sectionIdsWithScenes: Set<String>) -> Bool {
        if section.isUnplanned == true { return false }
        if section.inPostproduction && !sectionIdsWithScenes.contains(section.id) { return false }
        return true
    }

    static func visible(_ sections: [SceneSection], sectionIdsWithScenes: Set<String>) -> [SceneSection] {
        sections.filter { isShotlist($0, sectionIdsWithScenes: sectionIdsWithScenes) }
    }
}
