import SwiftUI
import ClerkKit

@main
struct SubshotApp: App {
    @State private var clerkLoaded = false

    init() {
        // Publishable key from the Subshot Clerk application (dashboard.clerk.com) —
        // same value used server-side as CLERK_PUBLISHABLE_KEY in /opt/subshot/.env.
        Clerk.configure(publishableKey: "pk_test_YmlnLXNuYWtlLTY2LmNsZXJrLmFjY291bnRzLmRldiQ")
        // NOTE: this is the TEST-mode key (pk_test_...) — fine for development,
        // but swap to a pk_live_... key from a production Clerk instance before
        // App Store submission (test instances have usage limits, see the
        // "Development mode" banner already seen on the web test page).
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Clerk.shared)
                .task {
                    try? await Clerk.shared.load()
                    clerkLoaded = true
                }
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
