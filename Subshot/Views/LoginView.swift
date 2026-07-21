import SwiftUI
import ClerkKit
import ClerkKitUI

/// Login screen (2026-07-21, #273 overhaul — Lino: "muss viel polierter
/// wirken, runde/interaktive Formen, Eintritts- + Idle-Animation"). Clerk's
/// own AuthView (sheet) still handles the actual sign-in/sign-up form,
/// Google, etc. — this screen is purely the branded entry point in front
/// of it, no custom form fields.
///
/// No exact visual spec was given beyond "tasteful, modern, matches the
/// app's dark aesthetic" — design judgment call made here: three softly
/// blurred, slow-drifting accent-color circles behind the wordmark (the
/// "round/interactive shapes" ask — "interactive" read as "feels alive",
/// via the continuous idle drift, not literal touch handling; a login
/// screen's background shouldn't compete with the real button tap in
/// front of it). Entrance = wordmark/subtitle/button spring+fade+slide in
/// together on appear; idle = the orbs keep gently drifting and the
/// wordmark/button keep a slow breathing glow/scale forever afterward,
/// started ~0.9s after the entrance spring so the two don't visually
/// fight each other right at launch (see idlePulse's own doc comment).
struct LoginView: View {
    @State private var authIsPresented = false
    /// Entrance — false at launch, springs true once in onAppear; every
    /// element's own .opacity/.offset/.scale keys off this.
    @State private var appeared = false
    /// Idle loop — only starts (repeatForever) once the entrance itself
    /// has mostly settled. Starting both at the exact same instant reads
    /// as the entrance getting interrupted mid-motion rather than
    /// finishing and THEN the screen "coming alive".
    @State private var idlePulse = false

    var body: some View {
        ZStack {
            backgroundOrbs

            VStack(spacing: 12) {
                Spacer()
                VStack(spacing: 10) {
                    // 2026-07-17, Lino: erst "der Thunderfont soll auch so
                    // in der iOS uebernommen werden", dann noch am selben
                    // Tag "wir wechseln da auf den Font ANTON" — mirrors
                    // the web app's logo wordmark (AppShell.tsx,
                    // font-anton). PostScript name "Anton-Regular" read
                    // directly out of the .ttf's name table (fontTools).
                    // Font.custom silently falls back to the system font
                    // if the name doesn't resolve — cannot be verified
                    // from this environment (no Xcode project here), Lino
                    // needs to confirm on his Mac.
                    // 2026-07-17, Lino: "Subshot als Logo Text immer alles
                    // gross schreiben" — .textCase(.uppercase) keeps the
                    // underlying string "Subshot" (same non-destructive
                    // reasoning as the web app's CSS text-transform).
                    Text("Subshot")
                        .font(.custom("Anton-Regular", size: 46))
                        .textCase(.uppercase)
                        .shadow(color: Color.accentColor.opacity(idlePulse ? 0.55 : 0.25), radius: idlePulse ? 24 : 10)
                    Text("Shots planen. Am Set abhaken.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .scaleEffect(appeared ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)

                Spacer()

                Button {
                    authIsPresented = true
                } label: {
                    Text("Anmelden")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                // Round/pill button (part of the "runde Formen" ask) —
                // clipShape after buttonStyle overrides the default
                // rounded-rect background shape with a true capsule.
                .clipShape(Capsule())
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
                .scaleEffect(appeared ? (idlePulse ? 1.015 : 1.0) : 0.9)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) {
                appeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    idlePulse = true
                }
            }
        }
        .sheet(isPresented: $authIsPresented) {
            AuthView()
        }
    }

    /// Three softly blurred, slow-drifting accent-color circles behind
    /// everything — see this file's own top-of-file doc comment for the
    /// design reasoning.
    private var backgroundOrbs: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: geo.size.width * 0.7)
                    .blur(radius: 60)
                    .offset(x: -geo.size.width * 0.3, y: idlePulse ? -geo.size.height * 0.32 : -geo.size.height * 0.38)
                Circle()
                    .fill(Color.purple.opacity(0.28))
                    .frame(width: geo.size.width * 0.6)
                    .blur(radius: 70)
                    .offset(x: geo.size.width * 0.35, y: idlePulse ? geo.size.height * 0.42 : geo.size.height * 0.36)
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: geo.size.width * 0.5)
                    .blur(radius: 50)
                    .offset(x: idlePulse ? geo.size.width * 0.05 : -geo.size.width * 0.05, y: 0)
            }
            .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
    }
}

#Preview {
    LoginView()
}
