import SwiftUI
import ClerkKit
import Sentry
import UserNotifications

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
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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

    var body: some View {
        Group {
            if clerk.isLoaded {
                if clerk.user != nil {
                    ProjectListView()
                        .environmentObject(backendAuth)
                        .task { await backendAuth.refreshMe() }
                } else {
                    LoginView()
                }
            } else {
                ProgressView()
            }
        }
    }
}
