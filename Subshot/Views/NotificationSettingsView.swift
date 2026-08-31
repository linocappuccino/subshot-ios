import SwiftUI
import Combine

/// 2026-07-28, Lino: "in den account einstellungen soll man einstellen
/// koennen welche email benachrichtigungen man moechte" — iOS port of web's
/// NotificationSettingsDialog.tsx, opened from AvatarMenu.swift as a sheet
/// (a `Menu` can't host multiple stateful `Toggle`s the way the DE/EN
/// language picker above it works as one-tap actions, so this is a real
/// screen, not another nested Menu). Only these 3 kinds ever send an email
/// at all (see app/notifications.py) — project/team invite emails aren't
/// listed here on purpose, same reasoning as the web dialog's doc comment.
/// UNVERIFIED — no compiler here, please build+test on device.
struct NotificationSettingsView: View {
    @EnvironmentObject private var auth: BackendAuth
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss

    @State private var ideaFeedback = true
    @State private var videoFeedback = true
    @State private var postproductionStatus = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    toggleRow(
                        title: language.t("notificationSettings.ideaFeedback"),
                        hint: language.t("notificationSettings.ideaFeedbackHint"),
                        isOn: $ideaFeedback
                    ) { newValue in
                        await patch(emailNotifyIdeaFeedback: newValue) { self.ideaFeedback = !newValue }
                    }
                    toggleRow(
                        title: language.t("notificationSettings.videoFeedback"),
                        hint: language.t("notificationSettings.videoFeedbackHint"),
                        isOn: $videoFeedback
                    ) { newValue in
                        await patch(emailNotifyVideoFeedback: newValue) { self.videoFeedback = !newValue }
                    }
                    toggleRow(
                        title: language.t("notificationSettings.postproductionStatus"),
                        hint: language.t("notificationSettings.postproductionStatusHint"),
                        isOn: $postproductionStatus
                    ) { newValue in
                        await patch(emailNotifyPostproductionStatus: newValue) { self.postproductionStatus = !newValue }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(language.t("notificationSettings.dialogTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("language.done")) { dismiss() }
                }
            }
        }
        .onAppear {
            guard let me = auth.currentUser else { return }
            ideaFeedback = me.emailNotifyIdeaFeedback
            videoFeedback = me.emailNotifyVideoFeedback
            postproductionStatus = me.emailNotifyPostproductionStatus
        }
    }

    @ViewBuilder
    private func toggleRow(title: String, hint: String, isOn: Binding<Bool>, onChange: @escaping (Bool) async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
                .onChange(of: isOn.wrappedValue) { _, newValue in
                    Task { await onChange(newValue) }
                }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Optimistic like the web dialog: the caller already flipped the local
    /// @State before this runs (via the Toggle binding); on failure the
    /// `revert` closure flips it back and an error line is shown.
    private func patch(
        emailNotifyIdeaFeedback: Bool? = nil,
        emailNotifyVideoFeedback: Bool? = nil,
        emailNotifyPostproductionStatus: Bool? = nil,
        revert: @escaping () -> Void
    ) async {
        do {
            let updated = try await APIClient.shared.patchMe(
                emailNotifyIdeaFeedback: emailNotifyIdeaFeedback,
                emailNotifyVideoFeedback: emailNotifyVideoFeedback,
                emailNotifyPostproductionStatus: emailNotifyPostproductionStatus
            )
            auth.currentUser = updated
            errorMessage = nil
        } catch {
            revert()
            errorMessage = language.t("notificationSettings.saveError")
        }
    }
}
