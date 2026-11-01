import SwiftUI
import Combine
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
    @State private var showNotificationSettings = false
    @State private var showMcp = false

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

            // 2026-07-28 — opens NotificationSettingsView.swift as a sheet
            // rather than another nested Menu (see that file's own doc
            // comment for why: a Menu can't host several stateful Toggles).
            Button {
                showNotificationSettings = true
            } label: {
                Label(language.t("avatar.notifications"), systemImage: "bell")
            }

            // 2026-11-01 — «KI verbinden (MCP)», same info dialog as the web (McpConnectDialog.tsx)
            Button {
                showMcp = true
            } label: {
                Label(language.t("avatar.mcp"), systemImage: "powerplug")
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
        .sheet(isPresented: $showNotificationSettings) {
            NotificationSettingsView()
        }
        .sheet(isPresented: $showMcp) {
            McpConnectSheet()
        }
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
        // Verified against the real ClerkKit source (clerk/clerk-ios,
        // Sources/ClerkKit/Core/Auth.swift) — sign-out lives on the `auth`
        // facade, not directly on `Clerk`: `public func signOut(sessionId:
        // String? = nil) async throws` on `Clerk.shared.auth`.
        try? await Clerk.shared.auth.signOut()
        auth.clear()
        signingOut = false
    }
}

/// 2026-11-01, Lino: «KI verbinden (MCP)» — how to connect Claude / ChatGPT to Subshot (web: McpConnectDialog.tsx).
/// Information only: the public MCP URL (OAuth — the AI app asks to sign in and confirm), no tokens, nothing written.
/// UNVERIFIED — no compiler here, please build+test on device.
struct McpConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared
    @State private var tab = 0
    @State private var copiedKey: String?

    private static let mcpUrl = "https://subshot.ch/mcp"
    private static let claudeCodeCommand = "claude mcp add --transport http subshot https://subshot.ch/mcp"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(language.t("mcp.intro"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section(language.t("mcp.urlLabel")) {
                    copyRow(Self.mcpUrl, key: "url")
                }
                Section {
                    Picker("", selection: $tab) {
                        Text("Claude").tag(0)
                        Text("ChatGPT").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if tab == 0 {
                        Text(language.t("mcp.claudeWeb")).font(.subheadline.weight(.semibold))
                        Text(language.t("mcp.claudeSteps")).font(.subheadline)
                        Text(language.t("mcp.claudeCode")).font(.subheadline.weight(.semibold))
                        copyRow(Self.claudeCodeCommand, key: "cmd")
                        Text(language.t("mcp.claudeCodeHint")).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(language.t("mcp.gptSteps")).font(.subheadline)
                        Text(language.t("mcp.gptHint")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section(language.t("mcp.canTitle")) {
                    Text(language.t("mcp.can")).font(.subheadline)
                }
                Section {
                    Label(language.t("mcp.noApprove"), systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Label(language.t("mcp.noSecrets"), systemImage: "lock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(language.t("mcp.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("common.done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func copyRow(_ value: String, key: String) -> some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                UIPasteboard.general.string = value
                copiedKey = key
                Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    if copiedKey == key { copiedKey = nil }
                }
            } label: {
                Text(copiedKey == key ? language.t("mcp.copied") : language.t("mcp.copy"))
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }
}
