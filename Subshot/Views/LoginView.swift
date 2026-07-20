import SwiftUI
import ClerkKit
import ClerkKitUI

/// Minimalist login screen — logo + one button, matching the Reminders-app
/// aesthetic the whole app follows (see project spec §9). Clerk's own AuthView
/// (sheet) handles the actual sign-in/sign-up form, Google, etc. — no custom
/// form fields to build or keep in sync with whatever auth methods are enabled
/// in the Clerk dashboard.
struct LoginView: View {
    @State private var authIsPresented = false

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            // 2026-07-17, Lino: erst "der Thunderfont soll auch so in der
            // iOS uebernommen werden", dann noch am selben Tag "wir
            // wechseln da auf den Font ANTON" — mirrors the web app's logo
            // wordmark (AppShell.tsx, font-anton). PostScript name "Anton-
            // Regular" read directly out of the .ttf's name table
            // (fontTools), not guessed from the filename — fetched from
            // Google's own official OFL-licensed fonts repo (unlike
            // Thunder, an unambiguous source). Font.custom silently falls
            // back to the system font if the name doesn't resolve (e.g.
            // before the .ttf is actually added to the Xcode target +
            // Info.plist's UIAppFonts — see Fonts/Anton-Regular.ttf's own
            // placement comment) — cannot be verified from this environment
            // (no Xcode project here), Lino needs to confirm on his Mac.
            // 2026-07-17, Lino: "Subshot als Logo Text immer alles gross
            // schreiben" — .textCase(.uppercase) keeps the underlying
            // string "Subshot" (same non-destructive reasoning as the web
            // app's CSS text-transform), just renders it uppercase.
            Text("Subshot")
                .font(.custom("Anton-Regular", size: 34))
                .textCase(.uppercase)
            Text("Shots planen. Am Set abhaken.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                authIsPresented = true
            } label: {
                Text("Anmelden")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
        .sheet(isPresented: $authIsPresented) {
            AuthView()
        }
    }
}

#Preview {
    LoginView()
}
