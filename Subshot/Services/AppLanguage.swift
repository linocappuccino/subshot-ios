import Foundation
import Combine

/// 2026-07-21, Lino: Avatar-Dialog mit Logout + Sprachumschalter (Web+iOS,
/// "grosser umbau" — explicitly scoped to just this dialog for now, not the
/// whole app, matching the same scoping decision made on the web side).
/// UNVERIFIED — no compiler here, see LanguageMenu.swift for the UI.
///
/// Mirrors lib/i18n.tsx's translation keys exactly so both platforms stay
/// in sync as more of the app gets migrated later. `current` is backed by
/// @AppStorage for an instant, offline-safe first render, then reconciled
/// against the backend (source of truth, so web+iOS always agree) the same
/// way BackendAuth.refreshMe() already re-fetches /me on launch.
@MainActor
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()

    @Published var current: String {
        didSet { UserDefaults.standard.set(current, forKey: Self.storageKey) }
    }

    private static let storageKey = "subshot.language"

    private init() {
        current = UserDefaults.standard.string(forKey: Self.storageKey) ?? "de"
    }

    /// Called from BackendAuth.refreshMe() once /me resolves — reconciles
    /// the locally-cached language against the DB-stored one (e.g. after
    /// switching on the web app, or a fresh install on a second device).
    func reconcile(fromBackend language: String) {
        guard language == "de" || language == "en" else { return }
        if language != current { current = language }
    }

    /// Sets locally FIRST (instant UI feedback, matches web's setLanguage
    /// writing the cookie before the PATCH resolves) — the caller is
    /// responsible for also calling APIClient.shared.patchMe(language:) to
    /// persist it, same split-responsibility shape as the web LanguageDialog.
    func set(_ language: String) {
        current = language
    }

    /// 2026-07-22 — the actual key/value pairs live in separate
    /// `AppLanguageStrings+*.swift` extension files (one per feature area:
    /// Core, ProjectCore, Ideas, Postproduction, Support, ...), each just a
    /// single `static let xStrings: [String: [String: String]]` constant.
    /// Listed explicitly here (NOT auto-registered via some global-
    /// initializer side-effect trick — too fragile to trust without a
    /// compiler to verify timing/dead-code-elimination behavior) so adding
    /// a new domain file means adding ONE line here, deliberately the only
    /// shared edit point, done once after every domain file already exists
    /// rather than something concurrent translation work has to coordinate
    /// on. Split out specifically so a big translation pass touching many
    /// features at once (mirroring the web app's ~330-key dictionary in
    /// lib/i18n.tsx) can be done as several independent files instead of
    /// everyone editing one giant literal — concurrent edits to a single
    /// huge dictionary caused real, repeated merge conflicts on the web
    /// side of this exact effort earlier the same day (see
    /// project_subshot_i18n_language_switcher memory).
    private static var allTables: [[String: [String: String]]] {
        [
            coreStrings,
            projectCoreStrings,
            ideasStrings,
            supportStrings,
        ]
    }

    private var strings: [String: [String: String]] {
        var merged: [String: [String: String]] = ["de": [:], "en": [:]]
        for table in Self.allTables {
            for (lang, dict) in table {
                merged[lang, default: [:]].merge(dict) { _, new in new }
            }
        }
        return merged
    }

    func t(_ key: String) -> String {
        strings[current]?[key] ?? strings["de"]?[key] ?? key
    }
}

extension AppLanguage {
    /// Base keys (avatar menu, language dialog itself) — kept here rather
    /// than in its own extension file since this is the smallest, most
    /// foundational set and predates the AppLanguageStrings+*.swift split.
    static let coreStrings: [String: [String: String]] = [
        "de": [
            "avatar.language": "Sprache",
            "avatar.legal": "Impressum & Datenschutz",
            "avatar.signOut": "Abmelden",
            "language.dialogTitle": "Sprache ändern",
            "language.german": "Deutsch",
            "language.english": "English",
        ],
        "en": [
            "avatar.language": "Language",
            "avatar.legal": "Legal & Privacy",
            "avatar.signOut": "Sign out",
            "language.dialogTitle": "Change language",
            "language.german": "Deutsch",
            "language.english": "English",
        ],
    ]
}
