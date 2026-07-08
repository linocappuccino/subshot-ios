import Foundation
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ShotListViewModel: ObservableObject {
    let projectId: String

    @Published var scenes: [Scene] = []
    // shots(in:) used to re-filter this whole array from scratch on every
    // call — and it's called twice per scene per render (once for the shot
    // list, once for the header count) — so a big project re-scanned every
    // shot for every scene on every single re-render. Grouped once here
    // instead, whenever the array actually changes.
    @Published var shots: [Shot] = [] {
        didSet { shotsBySceneId = Dictionary(grouping: shots, by: \.sceneId) }
    }
    private var shotsBySceneId: [String?: [Shot]] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Project-level info shown in the collapsible box at the top of the
    // scene overview — separate from `scenes`/`shots` since it belongs to
    // the project, not any single scene.
    @Published var shootDate: Date?
    /// Deletion cron (scripts/deletion_job.py) deletes at 30 days of
    /// inactivity — see Project.daysUntilDeletion for the same computation
    /// on the project-list side.
    @Published var lastOpenedAt: Date?
    @Published var locationAddress: String?
    @Published var locationLat: Double?
    @Published var locationLng: Double?
    @Published var members: [Member] = []
    @Published var todoLists: [TodoList] = []
    @Published var sections: [SceneSection] = []

    /// Owned here, not as a @StateObject inside LocationSection — that view
    /// lives inside the scrolling LazyVStack and gets torn down/rebuilt
    /// constantly while scrolling, which was recreating the underlying
    /// MKLocalSearchCompleter (and tearing it down) on every pass. That
    /// churn was the actual cause of the CPU-pegged freeze (confirmed via
    /// a paused stack sitting in swift_bridgeObjectRelease with an active
    /// NSURLConnection thread). One instance for the whole screen visit fixes it.
    let locationCompleter = LocationSearchCompleter()

    /// Holds a just-deleted shot for the 5s undo window (spec §7, ShotListView).
    @Published var pendingUndoShot: Shot?
    private var undoTask: Task<Void, Never>?

    init(projectId: String) {
        self.projectId = projectId
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await APIClient.shared.getProject(projectId)
            scenes = detail.scenes.sorted { $0.sortOrder < $1.sortOrder }
            shots = detail.shots
                .filter { $0.status != .deleted }
                .sorted { $0.sortOrder < $1.sortOrder }
            shootDate = detail.shootDate
            lastOpenedAt = detail.lastOpenedAt
            locationAddress = detail.locationAddress
            locationLat = detail.locationLat
            locationLng = detail.locationLng
            todoLists = detail.todoLists.sorted { $0.sortOrder < $1.sortOrder }
            sections = detail.sections.sorted { $0.sortOrder < $1.sortOrder }
        } catch {
            errorMessage = error.localizedDescription
        }
        // Independent of the main load — a failure here shouldn't block the
        // scene/shot list from showing.
        do {
            members = try await APIClient.shared.members(projectId: projectId)
        } catch {
            // Silent: the info box just shows an empty people list; the user
            // can still open "Team" from the toolbar, which surfaces errors.
        }
    }

    func updateShootDate(_ date: Date?) async {
        do {
            let updated = try await APIClient.shared.patchProject(projectId, shootDate: date)
            shootDate = updated.shootDate
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateLocation(address: String, lat: Double, lng: Double) async {
        do {
            let updated = try await APIClient.shared.patchProject(
                projectId, locationAddress: address, locationLat: lat, locationLng: lng
            )
            locationAddress = updated.locationAddress
            locationLat = updated.locationLat
            locationLng = updated.locationLng
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshMembers() async {
        do {
            members = try await APIClient.shared.members(projectId: projectId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shots(in scene: Scene?) -> [Shot] {
        shotsBySceneId[scene?.id] ?? []
    }

    /// Scenes belonging to a section, in order — nil means the "no section"
    /// group. Plain filter (not cached like shotsBySceneId): scene counts
    /// per project are small enough that re-scanning per render is cheap.
    func scenes(in section: SceneSection?) -> [Scene] {
        scenes.filter { $0.sectionId == section?.id }
    }

    // MARK: - Sections

    @discardableResult
    func createSection(name: String) async -> SceneSection? {
        do {
            let sortOrder = (sections.map(\.sortOrder).max() ?? -1) + 1
            let section = try await APIClient.shared.createSection(projectId: projectId, name: name, sortOrder: sortOrder)
            sections.append(section)
            return section
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameSection(_ section: SceneSection, name: String) async {
        do {
            let updated = try await APIClient.shared.patchSection(section.id, name: name)
            if let index = sections.firstIndex(where: { $0.id == updated.id }) {
                sections[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Scenes in a deleted section fall back to "no section" server-side
    /// (ON DELETE SET NULL) — mirrored locally so the scene tiles don't
    /// vanish from the list.
    func deleteSection(_ section: SceneSection) async {
        sections.removeAll { $0.id == section.id }
        for index in scenes.indices where scenes[index].sectionId == section.id {
            scenes[index].sectionId = nil
        }
        do {
            try await APIClient.shared.deleteSection(section.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reorderSection(_ sectionId: String, before targetId: String?) async {
        var list = sections
        guard let section = list.first(where: { $0.id == sectionId }) else { return }
        list.removeAll { $0.id == sectionId }
        if let targetId, let idx = list.firstIndex(where: { $0.id == targetId }) {
            list.insert(section, at: idx)
        } else {
            list.append(section)
        }
        do {
            for (index, sec) in list.enumerated() where sec.sortOrder != index {
                let updated = try await APIClient.shared.patchSection(sec.id, sortOrder: index)
                if let i = sections.firstIndex(where: { $0.id == updated.id }) {
                    sections[i] = updated
                }
            }
            sections.sort { $0.sortOrder < $1.sortOrder }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createShot(description: String, sceneId: String?) async -> Shot? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            var body = APIClient.ShotCreateBody()
            body.description = trimmed
            body.scene_id = sceneId
            body.sort_order = (shots(in: scenes.first { $0.id == sceneId }).map(\.sortOrder).max() ?? -1) + 1
            let shot = try await APIClient.shared.createShot(projectId: projectId, body: body)
            shots.append(shot)
            return shot
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createScene(name: String, color: String, description: String? = nil, dialogue: String? = nil, focalLengthMm: Int? = nil, scheduledAt: Date? = nil, durationMinutes: Int? = nil, sectionId: String? = nil) async -> Scene? {
        do {
            let sortOrder = (scenes.map(\.sortOrder).max() ?? -1) + 1
            let scene = try await APIClient.shared.createScene(
                projectId: projectId, name: name, color: color,
                description: description, dialogue: dialogue, focalLengthMm: focalLengthMm,
                scheduledAt: scheduledAt, durationMinutes: durationMinutes,
                sectionId: sectionId, sortOrder: sortOrder
            )
            scenes.append(scene)
            return scene
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Scene location has its own dedicated update call — same reasoning as
    /// the project-level LocationSection in ProjectInfoBox: it's edited via
    /// its own address-autocomplete flow, not bundled into the general
    /// rename/save, and (like the scene image) only applies to a scene that
    /// already exists.
    func updateSceneLocation(_ scene: Scene, address: String, lat: Double, lng: Double) async {
        do {
            let updated = try await APIClient.shared.patchScene(scene.id, locationAddress: address, locationLat: lat, locationLng: lng)
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSceneLocation(_ scene: Scene) async {
        do {
            let updated = try await APIClient.shared.patchScene(scene.id, clearLocation: true)
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Same "own dedicated call, existing scenes only" reasoning as location.
    func updateScenePriority(_ scene: Scene, priority: ShotPriority?) async {
        do {
            let updated: Scene
            if let priority {
                updated = try await APIClient.shared.patchScene(scene.id, priority: priority)
            } else {
                updated = try await APIClient.shared.patchScene(scene.id, clearPriority: true)
            }
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameScene(_ scene: Scene, name: String, color: String, description: String, dialogue: String, focalLengthMm: Int?, scheduledAt: Date?, durationMinutes: Int?) async {
        do {
            let updated = try await APIClient.shared.patchScene(
                scene.id, name: name, color: color,
                description: description, dialogue: dialogue, focalLengthMm: focalLengthMm,
                scheduledAt: scheduledAt, durationMinutes: durationMinutes
            )
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Im Kasten" toggle: flips `completed` and — only when turning it ON —
    /// moves the scene to the very end of the list. Mutates `scenes` locally
    /// first (wrapped in `withAnimation`) so the color change and reorder
    /// animate immediately instead of waiting on the network round-trip;
    /// the server calls afterward reconcile/persist the same result.
    func setSceneCompleted(_ scene: Scene, completed: Bool) async {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(completed ? .success : .warning)
        #endif
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            scenes[index].completed = completed
            if completed {
                let moved = scenes.remove(at: index)
                scenes.append(moved)
            }
        }
        do {
            let updated = try await APIClient.shared.patchScene(scene.id, completed: completed)
            if let i = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[i] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if completed {
            await reorderScene(scene.id, before: nil)
        }
    }

    /// Quick assignment straight from the scene tile's header menu — same
    /// "responsible person" idea as todo item assignment, no need to open the
    /// full edit sheet just to set/clear this one field.
    func assignScene(_ scene: Scene, to userId: String?) async {
        do {
            let updated: Scene
            if let userId {
                updated = try await APIClient.shared.patchScene(scene.id, assigneeId: userId)
            } else {
                updated = try await APIClient.shared.patchScene(scene.id, clearAssignee: true)
            }
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Same quick-menu idea as assignScene, for putting a scene into a
    /// section from the tile itself rather than needing the full edit sheet.
    func assignSceneToSection(_ scene: Scene, sectionId: String?) async {
        do {
            let updated: Scene
            if let sectionId {
                updated = try await APIClient.shared.patchScene(scene.id, sectionId: sectionId)
            } else {
                updated = try await APIClient.shared.patchScene(scene.id, clearSection: true)
            }
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if canImport(UIKit)
    func uploadSceneImage(_ scene: Scene, image: UIImage) async {
        do {
            let updated = try await APIClient.shared.uploadSceneImage(sceneId: scene.id, image: image)
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    /// Drag & drop, cross-scene case: moves `shotId` into `sceneId` (nil =
    /// unassigned), inserted right before `targetId` if given, else appended
    /// at the end of that scene. Also covers same-scene reordering (pass the
    /// shot's current sceneId back in) since both are really "recompute this
    /// scene's shot order" — reassigns every sort_order in the destination
    /// list sequentially afterward; there's no bulk-reorder endpoint yet, so
    /// this is one PATCH per shot in that list.
    func moveShot(_ shotId: String, toScene sceneId: String?, before targetId: String? = nil) async {
        guard let shot = shots.first(where: { $0.id == shotId }) else { return }
        var destination = shots(in: scenes.first { $0.id == sceneId })
        destination.removeAll { $0.id == shotId }
        if let targetId, let idx = destination.firstIndex(where: { $0.id == targetId }) {
            destination.insert(shot, at: idx)
        } else {
            destination.append(shot)
        }
        do {
            for (index, s) in destination.enumerated() {
                let updated = try await APIClient.shared.moveShot(s.id, sceneId: sceneId, sortOrder: index)
                replace(updated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Scene reordering (up/down menu): a single server-side move — see
    /// APIClient.moveScene. The server renumbers just the moved scene
    /// (screenplay-style) and reassigns every sibling's sort_order in one
    /// transaction; locally we just optimistically relocate it in `scenes`
    /// and then reconcile with whatever the server returns.
    func reorderScene(_ sceneId: String, before targetId: String?) async {
        var list = scenes
        guard let scene = list.first(where: { $0.id == sceneId }) else { return }
        list.removeAll { $0.id == sceneId }
        if let targetId, let idx = list.firstIndex(where: { $0.id == targetId }) {
            list.insert(scene, at: idx)
        } else {
            list.append(scene)
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            scenes = list
        }
        do {
            let updated = try await APIClient.shared.moveScene(sceneId, beforeSceneId: targetId)
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleDone(_ shot: Shot) async {
        let newStatus: ShotStatus = shot.status == .done ? .open : .done
        do {
            let updated = try await APIClient.shared.patchShot(shot.id, status: newStatus.rawValue)
            replace(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Optimistically removes the shot from the visible list and starts a 5s
    /// undo window (spec: "Swipe links → löschen (mit Undo-Toast, 5 Sek.)").
    /// Only actually deletes on the backend once the window expires.
    func deleteWithUndo(_ shot: Shot) {
        shots.removeAll { $0.id == shot.id }
        pendingUndoShot = shot
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            pendingUndoShot = nil
            try? await APIClient.shared.deleteShot(shot.id)
        }
    }

    func undoDelete() {
        undoTask?.cancel()
        if let shot = pendingUndoShot {
            shots.append(shot)
        }
        pendingUndoShot = nil
    }

    func replace(_ shot: Shot) {
        if let index = shots.firstIndex(where: { $0.id == shot.id }) {
            shots[index] = shot
        }
    }

    // MARK: - Todo lists

    static let maxTodoLists = 5

    @discardableResult
    func createTodoList(name: String) async -> TodoList? {
        guard todoLists.count < Self.maxTodoLists else { return nil }
        do {
            let sortOrder = (todoLists.map(\.sortOrder).max() ?? -1) + 1
            let list = try await APIClient.shared.createTodoList(projectId: projectId, name: name, sortOrder: sortOrder)
            todoLists.append(list)
            return list
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameTodoList(_ list: TodoList, name: String) async {
        do {
            let updated = try await APIClient.shared.patchTodoList(list.id, name: name)
            if let index = todoLists.firstIndex(where: { $0.id == updated.id }) {
                todoLists[index].name = updated.name
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTodoList(_ list: TodoList) async {
        todoLists.removeAll { $0.id == list.id }
        do {
            try await APIClient.shared.deleteTodoList(list.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createTodoItem(in list: TodoList, text: String) async -> TodoItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let listIndex = todoLists.firstIndex(where: { $0.id == list.id }) else { return nil }
        do {
            let sortOrder = (todoLists[listIndex].items.map(\.sortOrder).max() ?? -1) + 1
            let item = try await APIClient.shared.createTodoItem(todoListId: list.id, text: trimmed, sortOrder: sortOrder)
            todoLists[listIndex].items.append(item)
            return item
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func toggleTodoItemDone(_ item: TodoItem) async {
        guard let listIndex = todoLists.firstIndex(where: { $0.id == item.todoListId }),
              let itemIndex = todoLists[listIndex].items.firstIndex(where: { $0.id == item.id }) else { return }
        do {
            let updated = try await APIClient.shared.patchTodoItem(item.id, done: !item.done)
            todoLists[listIndex].items[itemIndex] = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func assignTodoItem(_ item: TodoItem, to userId: String?) async {
        guard let listIndex = todoLists.firstIndex(where: { $0.id == item.todoListId }),
              let itemIndex = todoLists[listIndex].items.firstIndex(where: { $0.id == item.id }) else { return }
        do {
            let updated: TodoItem
            if let userId {
                updated = try await APIClient.shared.patchTodoItem(item.id, assigneeId: userId)
            } else {
                updated = try await APIClient.shared.patchTodoItem(item.id, clearAssignee: true)
            }
            todoLists[listIndex].items[itemIndex] = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTodoItem(_ item: TodoItem) async {
        guard let listIndex = todoLists.firstIndex(where: { $0.id == item.todoListId }) else { return }
        todoLists[listIndex].items.removeAll { $0.id == item.id }
        do {
            try await APIClient.shared.deleteTodoItem(item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
