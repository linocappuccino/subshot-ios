import SwiftUI
import ClerkKit

/// 2026-07-21, Lino: "oben soll man auf seinen avatar klicken koennen dann
/// geht ein dialog auf bei dem man sich von der app ausloggen kann, und die
/// sprache der app aendern kann" — iOS had NO sign-out affordance anywhere
/// before this (confirmed via a repo-wide search), so unlike the web side
/// (which just adds one action to Clerk's already-existing UserButton
/// dropdown) this is genuinely new UI on this platform. A native SwiftUI
/// `Menu` with a nested `Menu` for Sprache reads closest to "tap avatar →
/// dialog with these options" without hand-building a custom popover.
/// UNVERIFIED — no compiler here, please build+test on device.
struct AvatarMenu: View {
    // SubshotApp.swift already injects BackendAuth.shared via
    // .environmentObject() at the app root — matching that established
    // convention here instead of a second direct @ObservedObject binding
    // to the same singleton. AppLanguage is new (this feature only, not
    // yet part of that injection point) so it stays a direct binding.
    @EnvironmentObject private var auth: BackendAuth
    @ObservedObject private var language = AppLanguage.shared
    @State private var signingOut = false

    var body: some View {
        Menu {
            Menu {
                Button {
                    Task { await pick("de") }
                } label: {
                    if language.current == "de" {
                        Label(language.t("language.german"), systemImage: "checkmark")
                    } else {
                        Text(language.t("language.german"))
                    }
                }
                Button {
                    Task { await pick("en") }
                } label: {
                    if language.current == "en" {
                        Label(language.t("language.english"), systemImage: "checkmark")
                    } else {
                        Text(language.t("language.english"))
                    }
                }
            } label: {
                Label(language.t("avatar.language"), systemImage: "globe")
            }

            // 2026-07-22 — mirrors the web app's avatar-menu UserButton.Link
            // to the same URL (see AppShell.tsx); these pages live on the
            // backend (subshot.ch), no reason to duplicate their content
            // natively here.
            Link(destination: URL(string: "https://subshot.ch/impressum")!) {
                Label(language.t("avatar.legal"), systemImage: "doc.text")
            }

            Button(role: .destructive) {
                Task { await signOut() }
            } label: {
                Label(language.t("avatar.signOut"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            MemberAvatar(
                name: auth.currentUser?.name,
                email: auth.currentUser?.email ?? "",
                userId: auth.currentUser?.id ?? "",
                avatarUrl: auth.currentUser?.avatarUrl,
                size: 30
            )
        }
        .disabled(signingOut)
    }

    private func pick(_ lang: String) async {
        guard lang != language.current else { return }
        language.set(lang)
        // Same split-responsibility shape as web's LanguageDialog: set
        // locally first for instant feedback, persist to the backend after
        // (source of truth so web+iOS agree — see AppLanguage.reconcile).
        _ = try? await APIClient.shared.patchMe(language: lang)
    }

    private func signOut() async {
        signingOut = true
        // NOTE: exact Clerk iOS SDK method unverified against real source
        // (no local copy of the ClerkKit package on this machine) — matches
        // the documented `Clerk.shared.signOut()` convention shared across
        // Clerk's web/iOS/React SDKs, mirrors this file's existing
        // `Clerk.shared.session?.getToken()` usage. If the real method name
        // differs, this is the one line to fix.
        try? await Clerk.shared.signOut()
        auth.clear()
        signingOut = false
    }
}
