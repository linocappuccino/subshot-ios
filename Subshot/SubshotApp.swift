import SwiftUI
import ClerkKit
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
        // Publishable key from the Subshot Clerk application (dashboard.clerk.com) —
        // same value used server-side as CLERK_PUBLISHABLE_KEY in /opt/subshot/.env.
        // SDK v1: Clerk.configure(...) alone is enough — no separate .load() call
        // (that was the v0 API and no longer exists; caused a build error here
        // on 2026-07-07 when the installed package turned out to be v1).
        Clerk.configure(publishableKey: "pk_test_YmlnLXNuYWtlLTY2LmNsZXJrLmFjY291bnRzLmRldiQ")
        // NOTE: this is the TEST-mode key (pk_test_...) — fine for development,
        // but swap to a pk_live_... key from a production Clerk instance before
        // App Store submission (test instances have usage limits, see the
        // "Development mode" banner already seen on the web test page).
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
