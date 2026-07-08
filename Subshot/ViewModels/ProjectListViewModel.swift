import Foundation
import SwiftUI
import Combine

@MainActor
final class ProjectListViewModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Batched notifications (currently just todo-item assignments — see the
    /// backend Notification model docstring for the collapsing logic).
    @Published var notifications: [AppNotification] = []

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await APIClient.shared.listProjects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadNotifications() async {
        // Best-effort — a failed fetch just means no bell badge, not worth
        // surfacing as an error banner over the whole project list.
        notifications = (try? await APIClient.shared.notifications(unreadOnly: true)) ?? notifications
    }

    func markNotificationRead(_ notification: AppNotification) async {
        notifications.removeAll { $0.id == notification.id }
        do {
            _ = try await APIClient.shared.markNotificationRead(notification.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markAllNotificationsRead() async {
        let previous = notifications
        notifications = []
        do {
            try await APIClient.shared.markAllNotificationsRead()
        } catch {
            notifications = previous
            errorMessage = error.localizedDescription
        }
    }

    /// Returns the newly created project so the caller can navigate straight
    /// into it (Reminders-style: name it, hit return, you're in the list).
    /// Color rotates through the shared palette by current project count, so
    /// a fresh list of projects reads as visually distinct without asking the
    /// user to pick a color up front (they can still recolor via `update`).
    func create(name: String) async -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let color = Color.subshotPalette[projects.count % Color.subshotPalette.count]
        do {
            let project = try await APIClient.shared.createProject(name: trimmed, color: color)
            projects.insert(project, at: 0)
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func update(_ project: Project, name: String, color: String) async {
        do {
            let updated = try await APIClient.shared.patchProject(project.id, name: name, color: color)
            if let index = projects.firstIndex(where: { $0.id == updated.id }) {
                projects[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ project: Project) async {
        do {
            try await APIClient.shared.deleteProject(project.id)
            projects.removeAll { $0.id == project.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
