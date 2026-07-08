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
    @Published var shots: [Shot] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shots(in scene: Scene?) -> [Shot] {
        shots.filter { $0.sceneId == scene?.id }
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
    func createScene(name: String, color: String, description: String? = nil, dialogue: String? = nil, focalLengthMm: Int? = nil) async -> Scene? {
        do {
            let sortOrder = (scenes.map(\.sortOrder).max() ?? -1) + 1
            let scene = try await APIClient.shared.createScene(
                projectId: projectId, name: name, color: color,
                description: description, dialogue: dialogue, focalLengthMm: focalLengthMm,
                sortOrder: sortOrder
            )
            scenes.append(scene)
            return scene
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameScene(_ scene: Scene, name: String, color: String, description: String, dialogue: String, focalLengthMm: Int?) async {
        do {
            let updated = try await APIClient.shared.patchScene(
                scene.id, name: name, color: color,
                description: description, dialogue: dialogue, focalLengthMm: focalLengthMm
            )
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

    /// Drag & drop for scene headers themselves — reorders `scenes` and
    /// persists the new sort_order for every scene whose position changed.
    func reorderScene(_ sceneId: String, before targetId: String?) async {
        var list = scenes
        guard let scene = list.first(where: { $0.id == sceneId }) else { return }
        list.removeAll { $0.id == sceneId }
        if let targetId, let idx = list.firstIndex(where: { $0.id == targetId }) {
            list.insert(scene, at: idx)
        } else {
            list.append(scene)
        }
        do {
            for (index, sc) in list.enumerated() where sc.sortOrder != index {
                let updated = try await APIClient.shared.patchScene(sc.id, sortOrder: index)
                if let i = scenes.firstIndex(where: { $0.id == updated.id }) {
                    scenes[i] = updated
                }
            }
            scenes.sort { $0.sortOrder < $1.sortOrder }
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
}
