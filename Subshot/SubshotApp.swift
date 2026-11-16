import SwiftUI
import Combine
import ClerkKit
import Sentry
import UserNotifications

/// Small, permanent build-freshness indicator (mirrors Subtime's own
/// `Config.buildTag` — see that repo's Core/Config.swift and
/// [[feedback_ios_build_tag]]), added here rather than as a new file since
/// no .xcodeproj lives in this repo (see AppDelegate's doc comment below) —
/// a new Swift file would need Lino to hand-wire it into the Xcode project
/// before it could even compile. Bump this by one on every commit that
/// touches Subshot iOS source, so a glance at the Projects screen settles
/// whether a `git pull` + rebuild actually picked up the latest commit.
enum Config {
    static let buildTag = "b111"
}

/// Registers for remote notifications so a scene-timer push (see
/// scripts/scene_timer_notifications.py) can actually reach this device.
/// Requesting permission + calling registerForRemoteNotifications() here is
/// necessary but NOT sufficient on its own — this device token registration
/// will keep failing (didFailToRegisterForRemoteNotificationsWithError)
/// until the "Push Notifications" capability is added to the Subshot target
/// in Xcode's Signing & Capabilities tab (can't be done from this repo, no
/// .xcodeproj lives here — see also app/push.py's setup notes on the
/// server-side APNs key that's needed too).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// iPhone stays portrait-only — the whole UI (storyboard cards, tiles)
    /// is designed around a phone-width column and never adapted for a
    /// rotated/wide layout, so a stray landscape flip just looked broken.
    /// iPad keeps rotating freely (it already has an adjustable-column grid
    /// that's meant to use the extra width either orientation gives it).
    ///
    /// 2026-09-13 — tried an OrientationLock escape hatch here (flip this
    /// mask to landscape only while ReferenceVideoLightboxView is on
    /// screen) for "video soll beim Drehen fullscreen gehen", TWICE (b69's
    /// gesture-conflict theory, then reconfirmed still broken) — Lino kept
    /// seeing the lightbox itself close the instant the phone rotated.
    /// Suspected but unconfirmed cause: actually changing the INTERFACE
    /// orientation while a `.fullScreenCover` is on screen risks its
    /// hosting view controller (and the presenting one behind it) going
    /// through real trait-collection/size-class churn mid-rotation, which
    /// can tear down SwiftUI state that depends on stable view identity —
    /// unverifiable from here without a device, but reverted rather than
    /// risk it again: this mask is unconditional portrait now, same as
    /// before any of that, and ReferenceVideoLightboxView instead fakes
    /// the rotation purely visually (rotationEffect + swapped frame) while
    /// the real interface orientation never leaves portrait at all — see
    /// that file's own doc comment.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // UI tests (devlog screenshots): -UITestNoAnimations YES switches UIKit animations off —
        // the scene timers' endless pulse kept the slow CI runner from ever going idle, so its
        // screenshot requests timed out.
        if UserDefaults.standard.bool(forKey: "UITestNoAnimations") {
            UIView.setAnimationsEnabled(false)
        }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            try? await APIClient.shared.registerDeviceToken(token)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] Remote notification registration failed (expected until the Xcode Push Notifications capability + server APNs key are set up): \(error)")
    }

    /// Show the alert even while the app is open — otherwise a scene-timer
    /// push would silently do nothing for whoever currently has Subshot in
    /// the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}

@main
struct SubshotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 2026-07-22 — crash/error monitoring (backend+web already have
        // this, see project_subshot_public_launch_prep_2026-07-22 memory —
        // iOS had NONE at all before this, a crash was only ever found out
        // about if Lino noticed himself or a user reported it). Real DSN
        // (Sentry org "subli", project "apple-ios") — set up on Lino's own
        // Mac via `sentry-wizard -i ios --saas --org subli --project
        // apple-ios`, which also handles the Swift Package addition and
        // dSYM-upload build phase this repo's missing .xcodeproj can't do
        // from here. IF THE WIZARD ALSO INSERTED ITS OWN SentrySDK.start(...)
        // call somewhere (it usually does, right here in SubshotApp.swift's
        // init), remove one of the two before building — don't call
        // SentrySDK.start twice.
        //
        // includeLocalVariables is NOT a Cocoa SDK option (that's a
        // Python/Node-specific default this session had to explicitly turn
        // off on backend+web, see the same memory) — sentry-cocoa doesn't
        // snapshot local variables into stack traces by default, so no
        // equivalent fix is needed here.
        SentrySDK.start { options in
            options.dsn = "https://5dbc688a3296bc2b728aa8863111145d@o4511594358112256.ingest.de.sentry.io/4511779207512144"
            options.sendDefaultPii = false
            options.tracesSampleRate = 0.1
        }

        // Publishable key from the Subshot Clerk application (dashboard.clerk.com) —
        // same value used server-side as CLERK_PUBLISHABLE_KEY in /opt/subshot/.env.
        // SDK v1: Clerk.configure(...) alone is enough — no separate .load() call
        // (that was the v0 API and no longer exists; caused a build error here
        // on 2026-07-07 when the installed package turned out to be v1).
        // 2026-07-17 — switched to the production Clerk instance (clerk.subshot.ch),
        // same key now used server-side as CLERK_PUBLISHABLE_KEY in /opt/subshot/.env
        // and NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY in the web app.
        Clerk.configure(publishableKey: "pk_live_Y2xlcmsuc3Vic2hvdC5jaCQ")
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView()
                .environment(Clerk.shared)
                // App is dark-mode-only by design (matches the Reminders-app
                // look this whole UI follows) — not just "supports" dark mode.
                .preferredColorScheme(.dark)
        }
    }
}

/// Top-level router: login vs. signed-in app, based on Clerk's own session state.
struct RootView: View {
    @Environment(Clerk.self) private var clerk
    @StateObject private var backendAuth = BackendAuth.shared
    @StateObject private var sessionGuard = SessionGuard.shared
    #if DEBUG
    @StateObject private var debugLogin = DebugTestLogin.shared
    #endif

    var body: some View {
        Group {
            if clerk.isLoaded {
                #if DEBUG
                let debugLoginPending = DebugTestLogin.ticket != nil && !debugLogin.ready
                #else
                let debugLoginPending = false
                #endif
                // a session the server revoked (seat protection) counts as signed out at once,
                // even while Clerk's local state still holds it
                if clerk.user != nil && !debugLoginPending && clerk.session?.id != sessionGuard.endedSessionId {
                    ProjectListView()
                        .environmentObject(backendAuth)
                        .task { await backendAuth.refreshMe() }
                } else {
                    #if DEBUG
                    if debugLoginPending {
                        DebugTestLoginView()
                    } else {
                        LoginView()
                    }
                    #else
                    LoginView()
                    #endif
                }
            } else {
                ProgressView()
            }
        }
        .onChange(of: clerk.session?.id) { oldId, newId in
            sessionGuard.signedIn(sessionId: newId)
            // Clerk can drop a revoked session on its own (client refresh on foreground) before
            // any request of ours fails — still ask whether another device took the seat.
            if let oldId, newId == nil {
                Task { await sessionGuard.sessionDisappeared(sessionId: oldId) }
            }
        }
    }
}

#if DEBUG
/// 2026-11-15 — debug-only test login for simulator screenshots (devlog): with the launch argument
/// `-SubshotTestTicket <ticket>` the app signs in to Clerk with that one-time sign-in token
/// (Backend API sign_in_tokens, minted by the backend's POST /debug/test-ticket for the test
/// account) and never shows Clerk's AuthView. Lives entirely inside #if DEBUG, so Release builds
/// (TestFlight/App Store) contain none of it.
///
/// RootView keeps showing DebugTestLoginView until a session TOKEN can actually be fetched — a
/// session that Clerk reports as active but whose token call fails ("signed_out") would otherwise
/// open an empty Projects screen with no request ever reaching the API (seen 2026-11-15).
///
/// Usage: `xcrun simctl launch booted <bundle-id> -SubshotTestTicket <ticket>`
/// (or Scheme → Run → Arguments in Xcode; the UI test passes it from SUBSHOT_TEST_TICKET).
@MainActor
final class DebugTestLogin: ObservableObject {
    static let shared = DebugTestLogin()

    @Published private(set) var ready = false
    @Published private(set) var error: String?
    private var started = false

    /// `-Key value` launch arguments land in UserDefaults' argument domain.
    nonisolated static var ticket: String? {
        guard let t = UserDefaults.standard.string(forKey: "SubshotTestTicket"), !t.isEmpty else { return nil }
        return t
    }

    func run() async {
        guard !started, let ticket = Self.ticket else { return }
        started = true
        do {
            // A session from an earlier run (simulator keeps the Clerk client) may be stale — start clean.
            if Clerk.shared.session != nil { try? await Clerk.shared.auth.signOut() }
            try await Clerk.shared.auth.signInWithTicket(ticket)
            var lastError: Error?
            for _ in 1...5 {
                do {
                    if let token = try await Clerk.shared.session?.getToken(.init(skipCache: true)), !token.isEmpty {
                        print("[TestLogin] signed in, token ok")
                        ready = true
                        return
                    }
                } catch { lastError = error }
                try? await Task.sleep(for: .seconds(1))
            }
            throw lastError ?? URLError(.userAuthenticationRequired)
        } catch {
            print("[TestLogin] failed: \(error)")
            self.error = String(describing: error)
        }
    }
}

/// Shown instead of LoginView while the ticket sign-in runs (and with the Clerk error if it fails).
private struct DebugTestLoginView: View {
    @ObservedObject private var login = DebugTestLogin.shared

    var body: some View {
        VStack(spacing: 14) {
            if let error = login.error {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Test login failed")
                    .font(.headline)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                ProgressView()
                Text("Test login …")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await login.run() }
    }
}
#endif
