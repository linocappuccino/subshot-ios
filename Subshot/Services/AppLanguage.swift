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

    private var strings: [String: [String: String]] {
        [
            "de": [
                "avatar.language": "Sprache",
                "avatar.signOut": "Abmelden",
                "language.dialogTitle": "Sprache ändern",
                "language.german": "Deutsch",
                "language.english": "English",
            ],
            "en": [
                "avatar.language": "Language",
                "avatar.signOut": "Sign out",
                "language.dialogTitle": "Change language",
                "language.german": "Deutsch",
                "language.english": "English",
            ],
        ]
    }

    func t(_ key: String) -> String {
        strings[current]?[key] ?? strings["de"]?[key] ?? key
    }
}
