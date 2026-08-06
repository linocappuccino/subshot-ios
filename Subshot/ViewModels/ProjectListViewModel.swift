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
    /// This screen's DIRECT subfolders — root when `folderId` is nil, this
    /// folder's own children otherwise (2026-07-20: folders can nest, see
    /// ProjectFolder.folderCount's doc comment — used to just be root-only,
    /// which made anything nested two levels deep completely unreachable).
    @Published var folders: [ProjectFolder] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Batched notifications (currently just todo-item assignments — see the
    /// backend Notification model docstring for the collapsing logic).
    @Published var notifications: [AppNotification] = []
    /// Powers TodoSidebarSheet (#412) — cross-project open todos + postproduction
    /// deadlines, same feed as web's TodoSidebar. nil until the first load resolves.
    @Published var todoSidebarData: TodoSidebarData?

    init(folderId: String? = nil) {
        self.folderId = folderId
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await APIClient.shared.listProjects(folderId: folderId)
            folders = try await APIClient.shared.listFolders(parentFolderId: folderId)
        } catch {
            // See APIError.isCancellation — a cancelled request (e.g. this
            // same load() still running from the initial .task when
            // .refreshable fires it again) isn't a real failure and
            // shouldn't surface as "Fehler: Verbindungsfehler: cancelled".
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func createFolder(name: String, color: String? = nil, emoji: String? = nil, image: UIImage? = nil) async -> ProjectFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let sortOrder = (folders.map(\.sortOrder).max() ?? -1) + 1
            var folder = try await APIClient.shared.createFolder(name: trimmed, color: color, emoji: emoji, sortOrder: sortOrder, parentFolderId: folderId)
            if let image {
                folder = try await APIClient.shared.uploadFolderImage(folderId: folder.id, image: image)
            }
            folders.append(folder)
            return folder
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateFolder(_ folder: ProjectFolder, name: String, color: String, emoji: String?, image: UIImage? = nil, clearImage: Bool = false) async {
        do {
            var updated = try await APIClient.shared.patchFolder(
                folder.id, name: name, color: color,
                emoji: emoji, clearEmoji: emoji == nil,
                clearBackgroundImage: clearImage
            )
            if let image {
                updated = try await APIClient.shared.uploadFolderImage(folderId: folder.id, image: image)
            }
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

    func loadTodoSidebar() async {
        // Best-effort, same reasoning as loadNotifications — a failed fetch
        // just means a stale/empty sheet next time it's opened, not worth an
        // error banner over the whole project list.
        todoSidebarData = (try? await APIClient.shared.todoSidebar()) ?? todoSidebarData
    }

    /// Mirrors web's TodoSidebar.completeTodo — the sidebar only ever shows
    /// OPEN todos (backend filters done=false), so checking one off here is a
    /// one-way action: it just drops out of the list, same as it would on the
    /// next poll anyway. Reverts (re-adds it) if the PATCH fails.
    ///
    /// 2026-08-06, Lino: "soll mit einer Animation ... verschwinden" — the
    /// actual array removal (called by ReminderCheckbox only after its own
    /// strikethrough delay) is wrapped in withAnimation so the row fades/
    /// collapses out of the List instead of just snapping away; ditto the
    /// revert-on-failure re-insertion.
    func completeTodo(_ todo: MyTodo) async {
        guard var data = todoSidebarData else { return }
        data.todos.removeAll { $0.id == todo.id }
        withAnimation(.easeInOut(duration: 0.25)) {
            todoSidebarData = data
        }
        do {
            _ = try await APIClient.shared.patchTodoItem(todo.id, done: true)
        } catch {
            guard var reverted = todoSidebarData else { return }
            reverted.todos.append(todo)
            withAnimation(.easeInOut(duration: 0.25)) {
                todoSidebarData = reverted
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Suggested color for the next new project, rotated through the shared
    /// palette by current project count — shown pre-selected in
    /// ProjectEditSheet's creation mode (2026-07-13: Emoji/Farbe are now
    /// choosable right at creation, not just afterward via `update`), but
    /// the user can still pick a different one before hitting "Fertig".
    var nextDefaultColor: String {
        Color.subshotPalette[projects.count % Color.subshotPalette.count]
    }

    /// Returns the newly created project so the caller can navigate straight
    /// into it (Reminders-style: name it, hit return, you're in the list).
    func create(
        name: String, color: String? = nil, emoji: String? = nil, clientName: String? = nil,
        moduleConcept: Bool = true, moduleScripting: Bool = true,
        modulePostproduction: Bool = true
    ) async -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            // Below the current minimum (not appended at the max+1 like
            // scenes/sections/folders) — this view inserts new projects at
            // the very TOP of the grid (see the local .insert(at: 0) below),
            // so the sort_order needs to sort BEFORE everything already
            // there, not after.
            let sortOrder = (projects.map(\.sortOrder).min() ?? 0) - 1
            let project = try await APIClient.shared.createProject(
                name: trimmed, color: color ?? nextDefaultColor, emoji: emoji, clientName: clientName, folderId: folderId, sortOrder: sortOrder,
                moduleConcept: moduleConcept, moduleScripting: moduleScripting,
                modulePostproduction: modulePostproduction
            )
            projects.insert(project, at: 0)
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 2026-08-06, Lino (web session): "sortieren soll man nicht können,
    /// aber man soll projekte in ordner ziehen können und ordner in ordner
    /// ziehen können" — manual drag-to-reorder removed entirely, ported
    /// from the same fix on web. Root cause there (identical backend, so
    /// equally true here): list_projects/list_folders always sort by "most
    /// recently opened", never by sort_order at all, so the old
    /// reorderProject/reorderFolder pair (and their APIClient.moveProject/
    /// moveFolder calls, both removed) had been a silent no-op for weeks —
    /// a reorder drag "succeeded" but reverted on the next app relaunch,
    /// nobody had noticed since it never actually did anything.
    ///
    /// Drag & drop: nests a folder tile onto another folder tile — new
    /// (2026-08-06), folders could previously only nest via explicit
    /// create/edit (parentFolderId), never by dragging one onto another.
    /// Mirrors moveProject's optimistic shape exactly; the backend
    /// (patch_folder) already has the cycle guard (can't nest a folder into
    /// its own descendant).
    func moveFolder(_ folder: ProjectFolder, toParent targetFolderId: String) async {
        guard folder.id != targetFolderId else { return }
        folders.removeAll { $0.id == folder.id }
        if let i = folders.firstIndex(where: { $0.id == targetFolderId }) {
            folders[i].folderCount += 1
        }
        do {
            _ = try await APIClient.shared.patchFolder(folder.id, parentFolderId: targetFolderId)
        } catch {
            folders.append(folder)
            if let i = folders.firstIndex(where: { $0.id == targetFolderId }) {
                folders[i].folderCount -= 1
            }
            errorMessage = error.localizedDescription
        }
    }

    func update(
        _ project: Project, name: String, color: String, emoji: String?, clientName: String? = nil,
        moduleConcept: Bool, moduleScripting: Bool, modulePostproduction: Bool
    ) async {
        do {
            let updated = try await APIClient.shared.patchProject(
                project.id, name: name, color: color,
                emoji: emoji, clearEmoji: emoji == nil,
                clientName: clientName,
                moduleConcept: moduleConcept, moduleScripting: moduleScripting,
                modulePostproduction: modulePostproduction
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
