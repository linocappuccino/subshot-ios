import Foundation
import Combine
import ClerkKit

/// Thin bridge between Clerk (handles sign-in/session/token) and our own
/// backend's `/me` (our own User row — Clerk only knows about ITS user object,
/// not ours). Clerk.shared itself is @Observable and injected into the SwiftUI
/// environment directly in SubshotApp.swift — this class only holds the extra
/// state our backend adds on top.
///
/// One-time Xcode setup:
/// 1. File > Add Package Dependencies... > https://github.com/clerk/clerk-ios
///    Add both products: ClerkKit and ClerkKitUI.
/// 2. See SubshotApp.swift for `Clerk.configure(publishableKey:)`.
@MainActor
final class BackendAuth: ObservableObject {
    static let shared = BackendAuth()

    @Published var currentUser: Me?

    private init() {
        // NOTE (2026-07-07): getToken() returns the JWT String directly in
        // the installed SDK version — a `.jwt` was assumed from docs/older
        // examples and didn't compile ("Value of type 'String' has no
        // member 'jwt'").
        APIClient.shared.tokenProvider = {
            let sessionId = Clerk.shared.session?.id
            do {
                let token = try await Clerk.shared.session?.getToken()
                if token != nil, let sessionId { await SessionGuard.shared.noteAlive(sessionId) }
                return token
            } catch {
                // 2026-11-16 (seat protection): a session revoked server-side (same account signed
                // in on another device) answers "signed_out" here — Clerk.shared.user stays set,
                // so without this the app sat on empty lists. Hand over to the sign-in screen.
                if SessionGuard.isSessionGone(error) {
                    await SessionGuard.shared.sessionEnded(sessionId: sessionId)
                    throw APIError.notAuthenticated
                }
                throw error
            }
        }
    }

    func refreshMe() async {
        currentUser = try? await APIClient.shared.me()
        // 2026-07-21 — reconcile the locally-cached language against the
        // DB-stored one (source of truth) every time /me is refetched, same
        // shape as AppShell.tsx's own effect on web.
        if let language = currentUser?.language {
            AppLanguage.shared.reconcile(fromBackend: language)
        }
    }

    func clear() {
        currentUser = nil
    }
}

/// 2026-11-16 — seat protection (backend: 1 web + 1 app session per account, the newest login
/// wins). When this device's Clerk session is revoked, the app must go cleanly to the sign-in
/// screen: no error alerts, no empty lists. Detected in two places — Clerk's getToken answering
/// "signed_out" (BackendAuth's token provider) and a 401 from our own API (APIClient.send*).
/// RootView treats the dead session as signed out right away (`endedSessionId`), Clerk's local
/// state is cleared in the background, and GET /auth/kicked?sid= tells whether another device
/// took the seat → LoginView shows `loginView.kicked`.
@MainActor
final class SessionGuard: ObservableObject {
    static let shared = SessionGuard()

    /// Session id that is known to be dead — RootView shows LoginView while Clerk still holds it.
    @Published private(set) var endedSessionId: String?
    /// Set when the backend says the session was ended because the account signed in elsewhere.
    @Published var kickedNotice = false
    private var lastAliveSessionId: String?
    private var handling = false

    nonisolated static func isSessionGone(_ error: Error) -> Bool {
        if let clerk = error as? ClerkAPIError {
            return ["signed_out", "session_not_found", "authentication_invalid"].contains(clerk.code)
        }
        return false
    }

    func noteAlive(_ sessionId: String) {
        lastAliveSessionId = sessionId
    }

    /// A new sign-in (different session) clears the "ended" state; the kicked notice stays until then.
    func signedIn(sessionId: String?) {
        guard let sessionId, sessionId != endedSessionId else { return }
        endedSessionId = nil
        kickedNotice = false
    }

    /// Set by the account menu's own «Sign out» so that one isn't mistaken for a kick.
    var userSignedOut = false

    /// Clerk removed the session by itself (no failed request of ours) — unless the user signed
    /// out, check whether it was a kick.
    func sessionDisappeared(sessionId: String) async {
        if userSignedOut { userSignedOut = false; return }
        guard sessionId != endedSessionId else { return }
        endedSessionId = sessionId
        BackendAuth.shared.clear()
        if await APIClient.shared.wasKicked(sessionId: sessionId) {
            kickedNotice = true
        }
    }

    func sessionEnded(sessionId: String?) async {
        guard !handling else { return }
        let sid = sessionId ?? Clerk.shared.session?.id ?? lastAliveSessionId
        guard let sid, sid != endedSessionId else { return }
        handling = true
        defer { handling = false }
        endedSessionId = sid
        BackendAuth.shared.clear()
        // local cleanup only — the server already ended the session, errors don't matter
        try? await Clerk.shared.auth.signOut(sessionId: sid)
        if await APIClient.shared.wasKicked(sessionId: sid) {
            kickedNotice = true
        }
    }
}

extension APIClient {
    /// GET /auth/kicked?sid=… → {"kicked": bool}; unauthenticated (the session is already gone).
    func wasKicked(sessionId: String) async -> Bool {
        var components = URLComponents(url: baseURL.appendingPathComponent("auth/kicked"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "sid", value: sessionId)]
        guard let url = components?.url else { return false }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        struct Answer: Decodable { let kicked: Bool }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return false }
        return answer.kicked
    }
}
