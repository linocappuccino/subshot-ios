import Foundation

/// 2026-11-24 (audit #2 / #3) — what the board's web view may load as its page and whose messages it accepts.
/// Pure functions so they are unit-tested (SubshotTests/BoardWebPolicyTests).
enum BoardWebPolicy {
    /// hosts the board page itself may navigate to: Subshot (app, accounts, clerk), Clerk's own domains, the R2
    /// file storage (downloads). Everything else opens in Safari.
    nonisolated static func isAllowedPage(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "about" || scheme == "blob" || scheme == "data" { return true }
        guard scheme == "https", let host = url.host?.lowercased() else { return false }
        if host == "subshot.ch" || host.hasSuffix(".subshot.ch") { return true }
        if host.hasSuffix(".clerk.accounts.dev") || host.hasSuffix(".clerk.com") || host == "clerk.com" { return true }
        if host.hasSuffix(".r2.cloudflarestorage.com") { return true }
        return false
    }

    /// links that may be handed to the system (Safari, Mail, Phone) when they don't belong in the board
    nonisolated static func isExternalOpenable(_ url: URL) -> Bool {
        ["http", "https", "mailto", "tel"].contains((url.scheme ?? "").lowercased())
    }

    /// the «subshot» bridge only takes messages from the board page itself — main frame on app.subshot.ch,
    /// never from embedded iframes (YouTube, link previews …) or a foreign page
    nonisolated static func acceptsMessage(isMainFrame: Bool, host: String?) -> Bool {
        isMainFrame && host?.lowercased() == "app.subshot.ch"
    }
}
