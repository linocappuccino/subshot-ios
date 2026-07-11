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
    /// Set right after marking a scene "Im Kasten" turns out to have been the
    /// last still-open scheduled ("getimte") scene in the project — see
    /// setSceneCompleted. ShotListView shows a one-button confirmation alert
    /// off this, then resets it to nil.
    @Published var showAllTimedScenesDoneConfirmation = false

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
    /// No longer sorts completed scenes to the end — "im Kasten" now
    /// collapses a scene in place instead of moving it, see
    /// setSceneCompleted's doc comment. A Projektinfo scene (isProjectInfo)
    /// always sorts first within its bucket, mirroring the web app's
    /// scenesIn (Lino: "die Projektinfo ist immer die erste Kachel in einem
    /// Abschnitt") — everything else keeps its natural sort_order.
    func scenes(in section: SceneSection?) -> [Scene] {
        scenes.filter { $0.sectionId == section?.id }
            .sorted { a, b in
                if a.isProjectInfo != b.isProjectInfo { return a.isProjectInfo }
                return a.sortOrder < b.sortOrder
            }
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
        // Contained scenes (and their shots) are deleted along with the
        // section now, not bumped to "Ohne Abschnitt" — matches the backend,
        // which does the same real deletion (2026-07-11).
        let removedSceneIds = Set(scenes.filter { $0.sectionId == section.id }.map(\.id))
        sections.removeAll { $0.id == section.id }
        scenes.removeAll { removedSceneIds.contains($0.id) }
        shots.removeAll { shot in
            guard let sceneId = shot.sceneId else { return false }
            return removedSceneIds.contains(sceneId)
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
        // Target's position is read from `sections` (the ORIGINAL,
        // pre-removal array) — same fix as reorderScene/moveShot below.
        // Finding it in `list` AFTER removing the dragged section made
        // "insert before target" a silent no-op for the most common drag
        // (onto the very next section down): reported as "man sieht die
        // blaue Linie aber es geht wieder zurück zur Ursprungsposition" —
        // the drop DID fire, it just computed the same order it started
        // with, so applying it below was a no-op.
        let targetIndex = targetId.flatMap { id in sections.firstIndex(where: { $0.id == id }) }
        list.removeAll { $0.id == sectionId }
        if let targetIndex {
            list.insert(section, at: min(targetIndex, list.count))
        } else {
            list.append(section)
        }
        // Apply the reordered list locally FIRST (same pattern as
        // reorderScene) — an earlier version only ever mutated `sections`
        // by id as each per-item PATCH response trickled in, so the visible
        // order didn't change until every request in the loop had round-
        // tripped, and a single slow/failed request left it stuck exactly
        // where it started.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            sections = list
        }
        do {
            for (index, sec) in list.enumerated() where sec.sortOrder != index {
                let updated = try await APIClient.shared.patchSection(sec.id, sortOrder: index)
                if let i = sections.firstIndex(where: { $0.id == updated.id }) {
                    sections[i] = updated
                }
            }
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
    func createScene(name: String, color: String, description: String? = nil, dialogue: String? = nil, scheduledAt: Date? = nil, durationMinutes: Int? = nil, sectionId: String? = nil, priority: ShotPriority? = nil, isIntermediateStep: Bool = false) async -> Scene? {
        do {
            let sortOrder = (scenes.map(\.sortOrder).max() ?? -1) + 1
            let scene = try await APIClient.shared.createScene(
                projectId: projectId, name: name, color: color,
                description: description, dialogue: dialogue,
                scheduledAt: scheduledAt, durationMinutes: durationMinutes,
                sectionId: sectionId, sortOrder: sortOrder, priority: priority,
                isIntermediateStep: isIntermediateStep
            )
            scenes.append(scene)
            return scene
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// "Projektinfo" from the "+" menu (2026-07-11: was wrongly creating a
    /// Section before, see addSceneButton in ShotListView) — NEVER auto-
    /// creates a section, matches the web app exactly. Just a scene with
    /// isProjectInfo set, no name, no section (lands in "Ohne Abschnitt");
    /// from there it's dragged into whichever section it belongs to using
    /// the ordinary scene drag mechanism, same as any other tile.
    @discardableResult
    func createProjectInfoScene() async -> Scene? {
        do {
            let sortOrder = (scenes.map(\.sortOrder).max() ?? -1) + 1
            let scene = try await APIClient.shared.createScene(
                projectId: projectId, name: nil, color: "#3875bd",
                sortOrder: sortOrder, isProjectInfo: true
            )
            scenes.append(scene)
            return scene
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Same idea as updateSectionShootDate, for a Projektinfo scene — just a
    /// plain scheduledAt patch on the scene itself (no separate endpoint,
    /// unlike Section which has its own dedicated shoot_date field).
    func updateSceneShootDate(_ scene: Scene, date: Date?) async {
        do {
            let updated = try await APIClient.shared.patchScene(scene.id, scheduledAt: date)
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
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

    func renameScene(_ scene: Scene, name: String, color: String, description: String, dialogue: String, scheduledAt: Date?, durationMinutes: Int?, priority: ShotPriority?) async {
        do {
            let updated = try await APIClient.shared.patchScene(
                scene.id, name: name, color: color,
                description: description, dialogue: dialogue,
                scheduledAt: scheduledAt, durationMinutes: durationMinutes,
                priority: priority, clearPriority: priority == nil
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
    /// Deliberately does NOT reorder the scene to the end anymore (used to,
    /// via a local array move + reorderScene(before: nil) server call) — a
    /// scene "im Kasten" now collapses in place instead (see ShotListView's
    /// sceneCollapsedRow/expandedCompletedSceneIds) so the shot list doesn't
    /// jump around mid-scroll while checking things off on set, and the
    /// original scene order stays intact as a reference.
    func setSceneCompleted(_ scene: Scene, completed: Bool) async {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(completed ? .success : .warning)
        #endif
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            scenes[index].completed = completed
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
            // Only a scheduled ("getimte") scene finishing off the very last
            // still-open scheduled scene in the project triggers the
            // reminder — completing an untimed scene, or one that still
            // leaves other scheduled scenes open, shouldn't nag.
            let timedScenes = scenes.filter { $0.scheduledAt != nil }
            if scene.scheduledAt != nil, !timedScenes.isEmpty, timedScenes.allSatisfy(\.completed) {
                showAllTimedScenesDoneConfirmation = true
            }
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
    /// "+ Dialog" on the scene tile — appends a new individually-checkable
    /// line. Optimistic local append first (same reasoning as everywhere
    /// else in this file: instant feedback, server call reconciles after).
    func addDialogue(to scene: Scene, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let created = try await APIClient.shared.createSceneDialogue(sceneId: scene.id, text: trimmed)
            if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
                scenes[index].dialogues.append(created)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Checking a dialogue line off strikes it through on the tile — "this
    /// line has actually been recorded", same idea as a shot's done status
    /// but per spoken line instead of per shot.
    func toggleDialogue(_ dialogue: SceneDialogue, in scene: Scene) async {
        guard let sceneIndex = scenes.firstIndex(where: { $0.id == scene.id }),
              let dialogueIndex = scenes[sceneIndex].dialogues.firstIndex(where: { $0.id == dialogue.id }) else { return }
        let newDone = !dialogue.done
        withAnimation(.easeInOut(duration: 0.2)) {
            scenes[sceneIndex].dialogues[dialogueIndex].done = newDone
        }
        do {
            let updated = try await APIClient.shared.patchSceneDialogue(dialogue.id, done: newDone)
            if let sIndex = scenes.firstIndex(where: { $0.id == scene.id }),
               let dIndex = scenes[sIndex].dialogues.firstIndex(where: { $0.id == updated.id }) {
                scenes[sIndex].dialogues[dIndex] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteDialogue(_ dialogue: SceneDialogue, in scene: Scene) async {
        guard let sceneIndex = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[sceneIndex].dialogues.removeAll { $0.id == dialogue.id }
        do {
            try await APIClient.shared.deleteSceneDialogue(dialogue.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Scenes in a deleted section fall back to "no section" server-side
    /// (see deleteSection above) — a deleted SCENE's own shots follow the
    /// same pattern (Shot.scene_id is ON DELETE SET NULL), landing in the
    /// unassigned shot list instead of vanishing. There was previously no
    /// way to delete a scene at all from the UI (see ShotListView's
    /// sceneMenuTarget) even though the backend endpoint already existed.
    func deleteScene(_ scene: Scene) async {
        scenes.removeAll { $0.id == scene.id }
        for index in shots.indices where shots[index].sceneId == scene.id {
            shots[index].sceneId = nil
        }
        do {
            try await APIClient.shared.deleteScene(scene.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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

    /// Shared by every "scene tile dropped onto another tile" drop target
    /// (sceneTile, sceneCompactTile, projectInfoSceneCard) — was duplicated
    /// three times almost identically before, and the duplication was
    /// itself part of the problem: refile-then-reorder for a Projektinfo
    /// scene was going through the SAME section-scoped reorderScene math
    /// as a normal scene, and that specific combination ("kann Projektinfo
    /// nicht in einen Abschnitt verschieben", 2026-07-11) was the last
    /// thing still failing after the reorder fixes for normal scenes
    /// landed. A Projektinfo scene always sorts first within its section
    /// regardless of sort_order (see scenes(in:)) — computing/sending a
    /// specific "before" position for it is pointless AND was one more
    /// place for the reorder math to go wrong; refiling the section alone
    /// is both correct and simpler ("soll sie direkt automatisch ganz oben
    /// im gewählten Abschnitt platziert werden" — that's exactly what
    /// scenes(in:)'s sort already guarantees for free).
    func handleSceneDroppedOnTile(_ draggedId: String, targetScene: Scene) async {
        guard draggedId != targetScene.id, let dragged = scenes.first(where: { $0.id == draggedId }) else { return }
        if dragged.sectionId != targetScene.sectionId {
            await assignSceneToSection(dragged, sectionId: targetScene.sectionId)
        }
        guard !dragged.isProjectInfo else { return }
        await reorderScene(draggedId, before: targetScene.id)
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
        // Target's position is read from `destination` BEFORE the dragged
        // shot is removed — see reorderScene's doc comment for why: finding
        // it AFTER removal made "insert before target" a silent no-op for
        // the most common gesture (dragging onto the very next shot below).
        let targetIndex = targetId.flatMap { id in destination.firstIndex(where: { $0.id == id }) }
        destination.removeAll { $0.id == shotId }
        if let targetIndex {
            destination.insert(shot, at: min(targetIndex, destination.count))
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
        guard let scene = scenes.first(where: { $0.id == sceneId }) else { return }
        // Scoped to the dragged scene's OWN section — by the time this runs
        // its sectionId already matches the drop target's (sceneTile's
        // dropDestination awaits assignSceneToSection first when they
        // differ). Matches the backend's own move_scene, which scopes its
        // sibling/position computation to Scene.section_id == scene.section_id.
        //
        // CRITICAL: must never operate on the raw flat `scenes` array
        // directly. sort_order is renumbered PER SECTION server-side (each
        // section's scenes are 0..N-1 independently), so scenes belonging
        // to different sections routinely share the same sort_order value —
        // sorting/indexing the flat array as if it were one ordered
        // sequence meant the computed before_scene_id could end up
        // referencing a scene in a totally different section. The
        // backend's siblings query (itself correctly section-scoped) then
        // silently couldn't find that id among the real siblings and fell
        // back to appending at the very end of the section instead of the
        // intended position. Found live, 2026-07-11 ("kann Projektinfo
        // nicht in einen Abschnitt mit Szenen verschieben", scenes still
        // not reliably movable downward even after the earlier, narrower
        // before_scene_id-direction fix below).
        var siblings = scenes.filter { $0.sectionId == scene.sectionId }.sorted { $0.sortOrder < $1.sortOrder }
        // Target's position is read from the ORIGINAL, pre-removal sibling
        // list, not after removing the dragged scene — finding it post-
        // removal made "insert before target" a silent no-op for the single
        // most common drag gesture (dragging onto the very next scene
        // below): removing the dragged scene already shifts every later
        // scene's index down by one, so re-finding the target after that
        // and inserting "before" it landed the scene right back where it
        // started ("kann Kacheln nach oben verschieben aber nicht nach
        // unten"). Same fix already applied to reorderSection below.
        let targetIndex = targetId.flatMap { id in siblings.firstIndex(where: { $0.id == id }) }
        siblings.removeAll { $0.id == sceneId }
        let insertIndex = targetIndex.map { min($0, siblings.count) } ?? siblings.count
        siblings.insert(scene, at: insertIndex)

        // Real optimistic feedback, not just an array shuffle — scenes(in:)
        // sorts by the sortOrder FIELD (see its own doc comment), not by
        // array position, so the drop only visibly moves once sortOrder
        // itself is renumbered here — exactly what the backend does, kept
        // in sync so there's no flicker/mismatch once its response lands.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            for (index, sibling) in siblings.enumerated() {
                if let i = scenes.firstIndex(where: { $0.id == sibling.id }), scenes[i].sortOrder != index {
                    scenes[i].sortOrder = index
                }
            }
        }

        // IMPORTANT: do NOT send the raw drop-target id as before_scene_id
        // — the backend's /move endpoint takes it completely literally
        // ("insert right before this id" in ITS OWN post-removal sibling
        // list), with none of the original-pre-removal-index adjustment
        // used above. For a downward drag, this view's own local math
        // effectively lands the scene right AFTER the drop target (reusing
        // the target's stale pre-removal index overshoots by exactly one
        // once the dragged scene itself is gone) — asking the server for
        // the opposite ("insert before target") is then a no-op for the
        // single most common gesture. Deriving before_scene_id from
        // whoever now sits right after the dragged scene in the already-
        // correct, section-scoped `siblings` sidesteps the mismatch
        // entirely and needs no direction detection of its own.
        let apiBeforeId = siblings.indices.contains(insertIndex + 1) ? siblings[insertIndex + 1].id : nil
        do {
            let updated = try await APIClient.shared.moveScene(sceneId, beforeSceneId: apiBeforeId)
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

    /// Quick good-take entry straight from the scene's main tile (see
    /// ShotListView.sceneGoodTakeButton) — lives on the scene itself, so it's
    /// always there regardless of how many shots the scene has.
    func setSceneGoodTake(_ scene: Scene, filename: String?) async {
        do {
            let updated = try await APIClient.shared.patchScene(
                scene.id, goodTakeFilename: filename, clearGoodTake: filename == nil
            )
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Todo lists

    static let maxTodoLists = 5

    /// Locates and mutates a TodoList by id, wherever it actually lives —
    /// the project-level `todoLists` array, or one of the sections' own
    /// arrays (multi-day shoots, 2026-07-10: a section can carry its own
    /// project-info box with its own todo lists, see SceneSection.todoLists).
    /// Every todo-list/item mutation method below goes through this instead
    /// of assuming `todoLists` is the only place a list can be.
    private func mutateTodoList(_ id: String, _ mutate: (inout TodoList) -> Void) {
        if let index = todoLists.firstIndex(where: { $0.id == id }) {
            mutate(&todoLists[index])
            return
        }
        for sectionIndex in sections.indices {
            if let listIndex = sections[sectionIndex].todoLists.firstIndex(where: { $0.id == id }) {
                mutate(&sections[sectionIndex].todoLists[listIndex])
                return
            }
        }
        // Projektinfo-scene-owned lists (see Scene.isProjectInfo) — same
        // trap as the section case above: every todo-item method funnels
        // through here, so a Projektinfo scene's lists would otherwise
        // silently no-op (item toggles/assigns/deletes doing nothing) with
        // no error, exactly like the section omission this already fixed.
        for sceneIndex in scenes.indices {
            if let listIndex = scenes[sceneIndex].todoLists.firstIndex(where: { $0.id == id }) {
                mutate(&scenes[sceneIndex].todoLists[listIndex])
                return
            }
        }
    }

    private func findTodoList(_ id: String) -> TodoList? {
        if let list = todoLists.first(where: { $0.id == id }) { return list }
        for section in sections {
            if let list = section.todoLists.first(where: { $0.id == id }) { return list }
        }
        for scene in scenes {
            if let list = scene.todoLists.first(where: { $0.id == id }) { return list }
        }
        return nil
    }

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

    /// Same as createTodoList above, but for a section's own project-info
    /// box — appended to that section's own todoLists, not the project-level
    /// array.
    @discardableResult
    func createSectionTodoList(section: SceneSection, name: String) async -> TodoList? {
        guard let sectionIndex = sections.firstIndex(where: { $0.id == section.id }),
              sections[sectionIndex].todoLists.count < Self.maxTodoLists else { return nil }
        do {
            let sortOrder = (sections[sectionIndex].todoLists.map(\.sortOrder).max() ?? -1) + 1
            let list = try await APIClient.shared.createSectionTodoList(sectionId: section.id, name: name, sortOrder: sortOrder)
            sections[sectionIndex].todoLists.append(list)
            return list
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Same as createSectionTodoList above, but for a Projektinfo scene's own
    /// todo lists (see Scene.isProjectInfo) — the current, non-legacy
    /// mechanism.
    @discardableResult
    func createSceneTodoList(scene: Scene, name: String) async -> TodoList? {
        guard let sceneIndex = scenes.firstIndex(where: { $0.id == scene.id }),
              scenes[sceneIndex].todoLists.count < Self.maxTodoLists else { return nil }
        do {
            let sortOrder = (scenes[sceneIndex].todoLists.map(\.sortOrder).max() ?? -1) + 1
            let list = try await APIClient.shared.createSceneTodoList(sceneId: scene.id, name: name, sortOrder: sortOrder)
            scenes[sceneIndex].todoLists.append(list)
            return list
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameTodoList(_ list: TodoList, name: String) async {
        do {
            let updated = try await APIClient.shared.patchTodoList(list.id, name: name)
            mutateTodoList(updated.id) { $0.name = updated.name }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTodoList(_ list: TodoList) async {
        todoLists.removeAll { $0.id == list.id }
        for sectionIndex in sections.indices {
            sections[sectionIndex].todoLists.removeAll { $0.id == list.id }
        }
        do {
            try await APIClient.shared.deleteTodoList(list.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createTodoItem(in list: TodoList, text: String) async -> TodoItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let existing = findTodoList(list.id) else { return nil }
        do {
            let sortOrder = (existing.items.map(\.sortOrder).max() ?? -1) + 1
            let item = try await APIClient.shared.createTodoItem(todoListId: list.id, text: trimmed, sortOrder: sortOrder)
            mutateTodoList(list.id) { $0.items.append(item) }
            return item
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func toggleTodoItemDone(_ item: TodoItem) async {
        do {
            let updated = try await APIClient.shared.patchTodoItem(item.id, done: !item.done)
            mutateTodoList(item.todoListId) { list in
                if let itemIndex = list.items.firstIndex(where: { $0.id == updated.id }) {
                    list.items[itemIndex] = updated
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func assignTodoItem(_ item: TodoItem, to userId: String?) async {
        do {
            let updated: TodoItem
            if let userId {
                updated = try await APIClient.shared.patchTodoItem(item.id, assigneeId: userId)
            } else {
                updated = try await APIClient.shared.patchTodoItem(item.id, clearAssignee: true)
            }
            mutateTodoList(item.todoListId) { list in
                if let itemIndex = list.items.firstIndex(where: { $0.id == updated.id }) {
                    list.items[itemIndex] = updated
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTodoItem(_ item: TodoItem) async {
        mutateTodoList(item.todoListId) { list in
            list.items.removeAll { $0.id == item.id }
        }
        do {
            try await APIClient.shared.deleteTodoItem(item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Section project-info boxes (multi-day shoots)
    // Creating new ones this way is retired (2026-07-11: the "+" menu's
    // "Projektinfo" now creates a Scene directly, see createProjectInfoScene
    // above, matching the web app) — removeSectionProjectInfo below stays,
    // existing section-owned boxes from before this redesign still need to
    // be deletable.

    /// Removes the section's info box entirely — clears its date/location
    /// and deletes its todo lists server-side (see patch_section's
    /// remove_project_info handling), not just hides it client-side.
    func removeSectionProjectInfo(_ section: SceneSection) async {
        do {
            let updated = try await APIClient.shared.patchSection(section.id, removeProjectInfo: true)
            if let index = sections.firstIndex(where: { $0.id == updated.id }) {
                sections[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSectionShootDate(_ section: SceneSection, date: Date?) async {
        do {
            let updated = try await APIClient.shared.patchSection(section.id, shootDate: date)
            if let index = sections.firstIndex(where: { $0.id == updated.id }) {
                sections[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSectionLocation(_ section: SceneSection, address: String, lat: Double, lng: Double) async {
        do {
            let updated = try await APIClient.shared.patchSection(
                section.id, locationAddress: address, locationLat: lat, locationLng: lng
            )
            if let index = sections.firstIndex(where: { $0.id == updated.id }) {
                sections[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
