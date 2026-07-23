import SwiftUI

/// Shows batched notifications (currently just "todo item assigned to you" —
/// collapsed server-side into one row per unread batch, see the backend
/// Notification model docstring). Tapping one marks it read and jumps
/// straight to the project it's about — and, 2026-07-23 (#324), to the
/// exact idea/scene/video tile the notification is actually about, via
/// entityKind/entityId, same as web's NotificationBell.tsx click-through.
struct NotificationsSheet: View {
    @ObservedObject var viewModel: ProjectListViewModel
    var onSelectProject: (Project, String?, String?) -> Void
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if viewModel.notifications.isEmpty {
                    ContentUnavailableView(
                        language.t("notificationsSheet.empty"),
                        systemImage: "bell.slash"
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(viewModel.notifications) { notification in
                        Button {
                            Task { await select(notification) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notification.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(notification.body)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text(notification.updatedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.primary)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(language.t("notificationsSheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("notificationsSheet.doneButton")) { dismiss() }
                }
                if !viewModel.notifications.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(language.t("notificationsSheet.markAllRead")) {
                            Task { await viewModel.markAllNotificationsRead() }
                        }
                    }
                }
            }
        }
    }

    /// Marks read first, then only navigates if the project is still one the
    /// caller can see (it's always resolvable in practice — the backend
    /// notification is only ever created for actual project members — but a
    /// removed member later shouldn't crash into a dead navigation target).
    private func select(_ notification: AppNotification) async {
        await viewModel.markNotificationRead(notification)
        if let project = viewModel.projects.first(where: { $0.id == notification.projectId }) {
            dismiss()
            onSelectProject(project, notification.entityKind, notification.entityId)
        }
    }
}
