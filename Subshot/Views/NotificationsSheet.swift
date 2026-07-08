import SwiftUI

/// Shows batched notifications (currently just "todo item assigned to you" —
/// collapsed server-side into one row per unread batch, see the backend
/// Notification model docstring). Tapping one marks it read and jumps
/// straight to the project it's about.
struct NotificationsSheet: View {
    @ObservedObject var viewModel: ProjectListViewModel
    var onSelectProject: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if viewModel.notifications.isEmpty {
                    ContentUnavailableView(
                        "Keine neuen Benachrichtigungen",
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
            .navigationTitle("Benachrichtigungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                if !viewModel.notifications.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Alle gelesen") {
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
            onSelectProject(project)
        }
    }
}
