import Foundation
import SwiftUI
import Combine

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

    func createScene(name: String?, color: String) async {
        do {
            let sortOrder = (scenes.map(\.sortOrder).max() ?? -1) + 1
            let scene = try await APIClient.shared.createScene(projectId: projectId, name: name, color: color, sortOrder: sortOrder)
            scenes.append(scene)
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
