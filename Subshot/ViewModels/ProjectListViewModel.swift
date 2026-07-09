import Foundation
import SwiftUI
import Combine

@MainActor
final class ProjectListViewModel: ObservableObject {
    /// nil = root screen. One ViewModel instance per screen level (root and
    /// each opened folder push a fresh ProjectListView / VM), same pattern
    /// as ShotListViewModel being per-project.
    let folderId: String?

    @Published var projects: [Project] = []
    /// Only populated at the root level — folders don't nest.
    @Published var folders: [ProjectFolder] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Batched notifications (currently just todo-item assignments — see the
    /// backend Notification model docstring for the collapsing logic).
    @Published var notifications: [AppNotification] = []

    init(folderId: String? = nil) {
        self.folderId = folderId
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await APIClient.shared.listProjects(folderId: folderId)
            if folderId == nil {
                folders = try await APIClient.shared.listFolders()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createFolder(name: String, color: String? = nil, emoji: String? = nil) async -> ProjectFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let sortOrder = (folders.map(\.sortOrder).max() ?? -1) + 1
            let folder = try await APIClient.shared.createFolder(name: trimmed, color: color, emoji: emoji, sortOrder: sortOrder)
            folders.append(folder)
            return folder
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateFolder(_ folder: ProjectFolder, name: String, color: String, emoji: String?) async {
        do {
            let updated = try await APIClient.shared.patchFolder(
                folder.id, name: name, color: color,
                emoji: emoji, clearEmoji: emoji == nil
            )
            if let index = folders.firstIndex(where: { $0.id == updated.id }) {
                folders[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: ProjectFolder) async {
        folders.removeAll { $0.id == folder.id }
        do {
            try await APIClient.shared.deleteFolder(folder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drag & drop: moves a project tile onto a folder tile.
    func moveProject(_ project: Project, toFolder targetFolderId: String?) async {
        do {
            let updated: Project
            if let targetFolderId {
                updated = try await APIClient.shared.patchProject(project.id, folderId: targetFolderId)
            } else {
                updated = try await APIClient.shared.patchProject(project.id, clearFolder: true)
            }
            // Moved out of this screen's scope (into/out of a folder) — drop
            // it from the visible list instead of leaving a stale entry.
            projects.removeAll { $0.id == updated.id }
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
            let project = try await APIClient.shared.createProject(name: trimmed, color: color, folderId: folderId)
            projects.insert(project, at: 0)
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func update(_ project: Project, name: String, color: String, emoji: String?) async {
        do {
            let updated = try await APIClient.shared.patchProject(
                project.id, name: name, color: color,
                emoji: emoji, clearEmoji: emoji == nil
            )
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
