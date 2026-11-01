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
            planningStrings,
            overviewStrings,
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
            "avatar.notifications": "Benachrichtigungen",
            // McpConnectSheet (AvatarMenu.swift, 2026-11-01) — same wording as web's mcp.* keys
            "avatar.mcp": "KI verbinden (MCP)",
            "mcp.title": "Subshot mit deiner KI verbinden",
            "mcp.intro": "Über MCP arbeitet dein KI-Chat (Claude oder ChatGPT) direkt mit deinen Subshot-Projekten. Beim Verbinden meldest du dich mit deinem Subshot-Konto an und bestätigst den Zugriff.",
            "mcp.urlLabel": "MCP-Server-URL",
            "mcp.copy": "Kopieren",
            "mcp.copied": "Kopiert",
            "mcp.claudeWeb": "claude.ai und Claude Desktop",
            "mcp.claudeSteps": "1. Öffne in Claude Einstellungen → Connectors.\n2. Tippe auf «Eigenen Connector hinzufügen».\n3. Name: Subshot, URL: https://subshot.ch/mcp – dann «Verbinden».\n4. Melde dich mit deinem Subshot-Konto an und bestätige den Zugriff.",
            "mcp.claudeCode": "Claude Code (Terminal)",
            "mcp.claudeCodeHint": "Danach in Claude Code /mcp öffnen und die Anmeldung bei Subshot bestätigen.",
            "mcp.gptSteps": "1. Öffne in ChatGPT Einstellungen → Apps & Connectors → Erweitert und aktiviere den Entwicklermodus.\n2. Lege einen neuen Connector (MCP-Server) an, Name: Subshot.\n3. URL: https://subshot.ch/mcp, Authentifizierung: OAuth.\n4. Melde dich mit deinem Subshot-Konto an und bestätige den Zugriff.",
            "mcp.gptHint": "Eigene Connectors brauchen in ChatGPT den Entwicklermodus; ob er verfügbar ist, hängt von deinem Tarif ab. Die Menünamen können sich ändern.",
            "mcp.canTitle": "Was deine KI damit kann",
            "mcp.can": "• Projekte anzeigen, anlegen und bearbeiten\n• Ideen schreiben und überarbeiten\n• Szenen, Shots und Karten auf dem Idee-Board erstellen\n• Drehplan (Timetable) lesen und planen\n• Bilder generieren oder hochladen und To-dos ergänzen",
            "mcp.noApprove": "Ideen können über MCP nicht abgenommen oder abgelehnt werden – das machst nur du in der App.",
            "mcp.noSecrets": "Es werden nie Zugangsdaten angezeigt. Die Verbindung läuft über eine sichere Anmeldung und lässt sich jederzeit trennen.",
            "language.dialogTitle": "Sprache ändern",
            "language.german": "Deutsch",
            "language.english": "English",
            // NotificationSettingsView.swift (2026-07-28) — mirrors web's
            // lib/i18n.tsx notificationSettings.* keys exactly.
            "notificationSettings.dialogTitle": "E-Mail-Benachrichtigungen",
            "notificationSettings.ideaFeedback": "Feedback zu Ideen",
            "notificationSettings.ideaFeedbackHint": "Wenn ein Kunde Feedback zu einer Idee abgibt",
            "notificationSettings.videoFeedback": "Feedback zu Videos",
            "notificationSettings.videoFeedbackHint": "Wenn ein Kunde Feedback zu einem Video abgibt",
            "notificationSettings.postproductionStatus": "Postproduction-Status",
            "notificationSettings.postproductionStatusHint": "Wenn sich der Status eines Abschnitts ändert",
            "notificationSettings.saveError": "Einstellung konnte nicht gespeichert werden.",
        ],
        "en": [
            "avatar.language": "Language",
            "avatar.legal": "Legal & Privacy",
            "avatar.signOut": "Sign out",
            "avatar.notifications": "Notifications",
            "avatar.mcp": "Connect AI (MCP)",
            "mcp.title": "Connect Subshot to your AI",
            "mcp.intro": "With MCP your AI chat (Claude or ChatGPT) works directly with your Subshot projects. When connecting, you sign in with your Subshot account and confirm access.",
            "mcp.urlLabel": "MCP server URL",
            "mcp.copy": "Copy",
            "mcp.copied": "Copied",
            "mcp.claudeWeb": "claude.ai and Claude Desktop",
            "mcp.claudeSteps": "1. In Claude, open Settings → Connectors.\n2. Tap «Add custom connector».\n3. Name: Subshot, URL: https://subshot.ch/mcp – then «Connect».\n4. Sign in with your Subshot account and confirm access.",
            "mcp.claudeCode": "Claude Code (terminal)",
            "mcp.claudeCodeHint": "Then open /mcp in Claude Code and confirm the Subshot sign-in.",
            "mcp.gptSteps": "1. In ChatGPT, open Settings → Apps & Connectors → Advanced and turn on developer mode.\n2. Create a new connector (MCP server), name: Subshot.\n3. URL: https://subshot.ch/mcp, authentication: OAuth.\n4. Sign in with your Subshot account and confirm access.",
            "mcp.gptHint": "Custom connectors in ChatGPT require developer mode; availability depends on your plan. Menu names may change.",
            "mcp.canTitle": "What your AI can do",
            "mcp.can": "• View, create and edit projects\n• Write and revise ideas\n• Create scenes, shots and cards on the idea board\n• Read and plan the shooting schedule (timetable)\n• Generate or upload images and add to-dos",
            "mcp.noApprove": "Ideas cannot be approved or rejected via MCP – only you do that in the app.",
            "mcp.noSecrets": "Credentials are never shown. The connection uses a secure sign-in and can be disconnected at any time.",
            "language.dialogTitle": "Change language",
            "language.german": "Deutsch",
            "language.english": "English",
            "notificationSettings.dialogTitle": "Email notifications",
            "notificationSettings.ideaFeedback": "Idea feedback",
            "notificationSettings.ideaFeedbackHint": "When a client leaves feedback on an idea",
            "notificationSettings.videoFeedback": "Video feedback",
            "notificationSettings.videoFeedbackHint": "When a client leaves feedback on a video",
            "notificationSettings.postproductionStatus": "Postproduction status",
            "notificationSettings.postproductionStatusHint": "When a section's status changes",
            "notificationSettings.saveError": "Couldn't save this setting.",
        ],
    ]
}
