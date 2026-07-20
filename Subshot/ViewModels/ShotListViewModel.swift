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
    /// Bumped on every load() call (2026-07-15, Lino: "wenn man die seite
    /// öffnet oder refreshed... sollen die info und projektinfo kacheln
    /// immer geschlossen sein"). ProjectInfoBox/SceneProjectInfoTile/
    /// SectionInfoBox each keep their own expand/collapse as a plain
    /// @State — that's per-VIEW-INSTANCE, and pull-to-refresh reuses the
    /// same instances (only the underlying data changes), so it never
    /// reset on its own. ShotListView applies .id(loadGeneration) to each
    /// of those views so SwiftUI treats them as brand-new instances on
    /// every load()/refresh — the standard way to force @State back to
    /// its default without threading a reset call through 3 separate
    /// view structs.
    @Published var loadGeneration = 0
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
    /// Client the shoot is for (2026-07-13, Lino) — project-level Projektinfo tile only.
    @Published var clientName: String?
    @Published var members: [Member] = []
    @Published var todoLists: [TodoList] = []
    @Published var sections: [SceneSection] = []
    /// #96 Pipeline-Module-Checkbox — gates the Postproduction-Tab (#11
    /// Schritt 5+6) on/off per Projekt.
    @Published var modulePostproduction: Bool = true
    /// Planungssektor (2026-07-17 iOS port — see web app's IdeaGrid.tsx) —
    /// not part of ProjectDetail server-side, always its own round trip
    /// (see load() below), same "independent of the main load, a failure
    /// here shouldn't block anything else" pattern as `members`.
    @Published var ideas: [Idea] = []

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

    /// General undo history, max 5 entries (2026-07-14, Lino: "falls man was
    /// gelöscht oder gemacht hat was man rückgängig machen will. man kann nur
    /// die letzten 5 schritte rückgängig machen") — separate from
    /// pendingUndoShot/deleteWithUndo above, which is its own proven,
    /// time-boxed (5s) mechanism specifically for shots and deliberately
    /// left untouched here. This stack currently only covers scene deletion
    /// (which had NO undo at all before this), each entry a closure that
    /// reverses one action; oldest entries fall off past 5. Extend to more
    /// action types the same way if wanted later.
    @Published private(set) var undoStack: [(label: String, undo: () async -> Void)] = []

    private func pushUndo(_ label: String, undo: @escaping () async -> Void) {
        undoStack.append((label, undo))
        if undoStack.count > 5 { undoStack.removeFirst(undoStack.count - 5) }
    }

    /// Called by the toolbar's undo button — pops and runs the most recent
    /// entry. Shot deletion's own 5s toast/undoDelete() takes priority since
    /// it's time-sensitive (silently commits once the window expires).
    func performUndo() async {
        if pendingUndoShot != nil {
            undoDelete()
            return
        }
        guard let last = undoStack.popLast() else { return }
        await last.undo()
    }

    init(projectId: String) {
        self.projectId = projectId
    }

    /// `resetGeneration` (2026-07-15): the 12s silent background poll (see
    /// ShotListView's own `.task` loop) used to call this with the default,
    /// bumping loadGeneration on EVERY tick — which, via .id(loadGeneration)
    /// on ProjectInfoBox/SectionInfoBox/SceneProjectInfoTile (see
    /// loadGeneration's own doc comment), tore down and rebuilt fresh
    /// instances of exactly those three views every 12 seconds, snapping
    /// any of them back to their default COLLAPSED @State the instant a
    /// user had expanded one — mid-interaction, unprompted, no way to avoid
    /// it since it kept happening every 12s for as long as the screen
    /// stayed open. That's what made "die obersten Objekte" read as
    /// completely unusable ("kann man gar nichts mit den oberen 2 Objekten
    /// machen") while every ordinary scene tile (no .id(loadGeneration) of
    /// its own) worked fine. The always-starts-closed behavior was only
    /// ever meant for a genuine reopen/pull-to-refresh (see loadGeneration's
    /// doc comment for the original ask) — the silent poll now passes
    /// false, leaving loadGeneration (and therefore those views' own
    /// expand/collapse state) untouched.
    func load(resetGeneration: Bool = true) async {
        isLoading = true
        if resetGeneration { loadGeneration += 1 }
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
            clientName = detail.clientName
            todoLists = detail.todoLists.sorted { $0.sortOrder < $1.sortOrder }
            sections = detail.sections.sorted { $0.sortOrder < $1.sortOrder }
            modulePostproduction = detail.modulePostproduction
        } catch {
            // A cancelled request (pull-to-refresh released mid-flight, or
            // the view disappearing) isn't a real failure — see
            // APIError.isCancellation's own comment. Root cause of "Fehler:
            // Verbindungsfehler: cancelled" on swipe-to-refresh.
            if !APIError.isCancellation(error) { errorMessage = error.localizedDescription }
        }
        // Independent of the main load — a failure here shouldn't block the
        // scene/shot list from showing.
        do {
            members = try await APIClient.shared.members(projectId: projectId)
        } catch {
            // Silent: the info box just shows an empty people list; the user
            // can still open "Team" from the toolbar, which surfaces errors.
        }
        // Same "independent, silent on failure" treatment — an Ideas-section
        // outage shouldn't take the scene/shot list down with it.
        do {
            ideas = try await APIClient.shared.listIdeas(projectId: projectId).sorted { $0.sortOrder < $1.sortOrder }
        } catch {
            // Silent, same reasoning as members above.
        }
    }

    // MARK: - Ideas (Planungssektor)

    func createIdea(title: String = "Neue Idee", text: String = "") async -> Idea? {
        do {
            let sortOrder = (ideas.map(\.sortOrder).max() ?? -1) + 1
            let idea = try await APIClient.shared.createIdea(projectId: projectId, title: title, text: text, sortOrder: sortOrder)
            ideas.append(idea)
            return idea
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func patchIdea(_ idea: Idea, title: String? = nil, text: String? = nil) async {
        do {
            let updated = try await APIClient.shared.patchIdea(idea.id, title: title, text: text)
            if let index = ideas.firstIndex(where: { $0.id == updated.id }) { ideas[index] = updated }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteIdea(_ idea: Idea) async {
        do {
            try await APIClient.shared.deleteIdea(idea.id)
            ideas.removeAll { $0.id == idea.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveIdea(_ idea: Idea, beforeIdeaId: String?) async {
        do {
            _ = try await APIClient.shared.moveIdea(idea.id, beforeIdeaId: beforeIdeaId)
            // Server-authoritative reorder (mirrors moveScene) — re-fetch
            // the whole list rather than trying to reconstruct every
            // sibling's new sortOrder locally.
            ideas = try await APIClient.shared.listIdeas(projectId: projectId).sorted { $0.sortOrder < $1.sortOrder }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Abgenommen" — creates a new Section + Scene server-side (see
    /// APIClient.approveIdea's own doc comment). Reloads the whole project
    /// (not just `ideas`) so the new Section/Scene shows up in the
    /// Scripting-Tool list immediately, same screen, no extra navigation.
    func approveIdea(_ idea: Idea) async {
        do {
            let updated = try await APIClient.shared.approveIdea(idea.id)
            if let index = ideas.firstIndex(where: { $0.id == updated.id }) { ideas[index] = updated }
            await load(resetGeneration: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if canImport(UIKit)
    func uploadIdeaImage(_ idea: Idea, image: UIImage) async {
        do {
            _ = try await APIClient.shared.uploadIdeaImage(ideaId: idea.id, image: image)
            await refreshIdea(idea.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func deleteIdeaImage(_ idea: Idea, imageId: String) async {
        do {
            try await APIClient.shared.deleteIdeaImage(ideaId: idea.id, imageId: imageId)
            await refreshIdea(idea.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reorderIdeaImages(_ idea: Idea, orderedImageIds: [String]) async {
        do {
            let updated = try await APIClient.shared.reorderIdeaImages(ideaId: idea.id, orderedImageIds: orderedImageIds)
            if let index = ideas.firstIndex(where: { $0.id == updated.id }) { ideas[index] = updated }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// AI generation itself is NOT wrapped here — same split as Scenes
    /// (see SceneEditSheet.generateAIImage): it calls
    /// APIClient.shared.generateIdeaImage directly so it can show its own
    /// sheet-local 402-insufficient-credits alert instead of the generic
    /// errorMessage banner, then calls this to pick up the result. No
    /// single-idea GET server-side (mirrors the web app's own
    /// IdeaFloatingCard.refreshImages workaround) — cheapest way to pick up
    /// one idea's freshly changed `images` is its own project list.
    func refreshIdea(_ ideaId: String) async {
        do {
            let list = try await APIClient.shared.listIdeas(projectId: projectId)
            if let fresh = list.first(where: { $0.id == ideaId }), let index = ideas.firstIndex(where: { $0.id == ideaId }) {
                ideas[index] = fresh
            }
        } catch {
            // Silent — the next 12s poll's full load() will catch it up anyway.
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

    /// 2026-07-14, Lino: "in der projektinfo-kachel muss man die adresse
    /// auch wieder rauslöschen können" — mirrors clearSceneLocation below,
    /// which already existed but had no UI hookup either.
    func clearProjectLocation() async {
        do {
            let updated = try await APIClient.shared.patchProject(projectId, clearLocation: true)
            locationAddress = updated.locationAddress
            locationLat = updated.locationLat
            locationLng = updated.locationLng
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateClientName(_ name: String) async {
        do {
            let updated = try await APIClient.shared.patchProject(projectId, clientName: name)
            clientName = updated.clientName
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
    /// no longer sorts first either (2026-07-11, Lino: "die Info-Kachel
    /// kann man jetzt überall platzieren... wie eine normale Szenenkachel
    /// von der Platzierung her") — plain sort_order for everything, same
    /// as the web app's scenesIn.
    func scenes(in section: SceneSection?) -> [Scene] {
        scenes.filter { $0.sectionId == section?.id }
            .sorted { $0.sortOrder < $1.sortOrder }
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

    /// #11 Schritt 5 — die bestaetigte Aktion hinter "Alle Szenen im Kasten?
    /// Ab in die Postproduction?".
    func sendSectionToPostproduction(_ section: SceneSection) async {
        do {
            let updated = try await APIClient.shared.sendSectionToPostproduction(section.id)
            if let index = sections.firstIndex(where: { $0.id == updated.id }) { sections[index] = updated }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// #11 Schritt 6 — Status/Deadline im Postproduction-Tracking aendern;
    /// Rollen-Gate (Status jede Rolle, Deadline ab "projektleiter") ist
    /// serverseitig durchgesetzt, siehe APIClient.patchSectionPostproduction.
    func patchSectionPostproduction(
        _ section: SceneSection, status: PostproductionStatus? = nil, deadline: Date? = nil, clearDeadline: Bool = false
    ) async {
        do {
            let updated = try await APIClient.shared.patchSectionPostproduction(
                section.id, status: status, deadline: deadline, clearDeadline: clearDeadline
            )
            if let index = sections.firstIndex(where: { $0.id == updated.id }) { sections[index] = updated }
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
        // reorderScene) — purely a visual preview now, not what gets
        // persisted (see below).
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            sections = list
        }
        // Single server-authoritative move (2026-07-13) — targetId IS
        // already exactly "insert before this section id", so no local
        // recomputation is needed to derive it; replaces what used to be a
        // per-changed-section patchSection loop (see move_section in the
        // backend for why: one shared computation instead of two
        // independently-implemented, potentially divergent ones — this is
        // the same shared endpoint the web app now calls too).
        do {
            let updated = try await APIClient.shared.moveSection(sectionId, beforeSectionId: targetId)
            if let i = sections.firstIndex(where: { $0.id == updated.id }) {
                sections[i] = updated
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
    /// isProjectInfo set, no name.
    ///
    /// sectionId (2026-07-12 addition): previously always nil, landing in
    /// "Ohne Abschnitt" and requiring a manual drag afterward — Lino asked
    /// for every "+"-menu creation (Szene/Zwischenschritt/Info) to instead
    /// land at the end of whichever section is currently open, see
    /// ShotListView's lastOpenedSectionKey/targetSectionIdForNewScene.
    @discardableResult
    func createProjectInfoScene(sectionId: String? = nil) async -> Scene? {
        do {
            let sortOrder = (scenes.map(\.sortOrder).max() ?? -1) + 1
            let scene = try await APIClient.shared.createScene(
                projectId: projectId, name: nil, color: "#3875bd",
                sectionId: sectionId, sortOrder: sortOrder, isProjectInfo: true
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

    func updateSceneClientName(_ scene: Scene, name: String) async {
        do {
            let updated = try await APIClient.shared.patchScene(scene.id, clientName: name)
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

    /// Set when a scene's start time was just changed AND other same-day
    /// scenes further along already have their own start time — the view
    /// shows a confirmation sheet/alert off this, never cascades silently
    /// (2026-07-11, Lino: "dies soll aber per Dialog gefragt und bestätigt
    /// werden"). sceneId/deltaSeconds are exactly what applyTimeCascade
    /// sends to the server — see its doc comment for why the actual
    /// shifting moved server-side (2026-07-13).
    @Published var pendingTimeCascade: (sceneId: String, deltaSeconds: TimeInterval)?

    func renameScene(_ scene: Scene, name: String, color: String, description: String, dialogue: String, scheduledAt: Date?, durationMinutes: Int?, priority: ShotPriority?) async {
        let previousScheduledAt = scene.scheduledAt
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

            // "Timing der App" (2026-07-11, Spec-Korrektur 2026-07-13) —
            // matches the web app's handleSceneUpdated: only offers to
            // cascade when an EXISTING start time actually changed (not on
            // first-time set), to every same-day scene ("getimte Szenen" —
            // just needs its OWN start, not also a duration) that's
            // chronologically after the new start. Projektinfo-Kacheln
            // ausgeschlossen (Spec nennt nur "Szenen und Zwischenszenen").
            // This is only the cheap client-side "is there anything to ask
            // about" check now — the server re-derives the same set itself
            // when applyTimeCascade actually asks it to shift anything.
            if let previousScheduledAt, let newStart = updated.scheduledAt, previousScheduledAt != newStart {
                let calendar = Calendar.current
                let hasAffected = scenes.contains { s in
                    guard s.id != updated.id, !s.isProjectInfo, let sStart = s.scheduledAt else { return false }
                    return calendar.isDate(sStart, inSameDayAs: newStart) && sStart > newStart
                }
                if hasAffected {
                    pendingTimeCascade = (updated.id, newStart.timeIntervalSince(previousScheduledAt))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Single server round-trip (2026-07-13) — was a client-side loop that
    /// chain-recomputed each affected scene's start as "previous scene's
    /// new start + its own duration", which silently collapsed any gap
    /// between originally non-contiguous scenes to zero, AND duplicated
    /// the exact same date math the web app separately implemented (and
    /// had the identical bug in). The backend's cascade_shift_seconds now
    /// does the actual uniform-delta shift once, authoritatively, so both
    /// clients always land on the exact same result — see patch_scene in
    /// the backend for the full reasoning.
    func applyTimeCascade() async {
        guard let (sceneId, deltaSeconds) = pendingTimeCascade else { return }
        pendingTimeCascade = nil
        do {
            _ = try await APIClient.shared.patchScene(sceneId, cascadeShiftSeconds: deltaSeconds)
            await load()
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

    /// Corrects a dialogue line's text (2026-07-11, Lino: "Dialoge muss man
    /// bearbeiten können / korrigieren können") — long-press → Bearbeiten on
    /// the row (see dialogueRow's .contextMenu in ShotListView), matches the
    /// web app's inline-edit-on-click in SceneEditModal.
    func updateDialogue(_ dialogue: SceneDialogue, in scene: Scene, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != dialogue.text,
              let sceneIndex = scenes.firstIndex(where: { $0.id == scene.id }),
              let dialogueIndex = scenes[sceneIndex].dialogues.firstIndex(where: { $0.id == dialogue.id }) else { return }
        let previousText = dialogue.text
        scenes[sceneIndex].dialogues[dialogueIndex].text = trimmed
        do {
            let updated = try await APIClient.shared.patchSceneDialogue(dialogue.id, text: trimmed)
            if let sIndex = scenes.firstIndex(where: { $0.id == scene.id }),
               let dIndex = scenes[sIndex].dialogues.firstIndex(where: { $0.id == updated.id }) {
                scenes[sIndex].dialogues[dIndex] = updated
            }
        } catch {
            if let sIndex = scenes.firstIndex(where: { $0.id == scene.id }),
               let dIndex = scenes[sIndex].dialogues.firstIndex(where: { $0.id == dialogue.id }) {
                scenes[sIndex].dialogues[dIndex].text = previousText
            }
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
        // Captured BEFORE removal/delete for the undo closure below — the
        // scene row itself is a hard delete on the backend (no trash), so
        // "undo" means recreating it from this snapshot and re-filing
        // whatever shots were in it (deleting a scene only unfiles its
        // shots, see the loop below, it doesn't delete them).
        let orphanedShotIds = shots.filter { $0.sceneId == scene.id }.map(\.id)
        scenes.removeAll { $0.id == scene.id }
        for index in shots.indices where shots[index].sceneId == scene.id {
            shots[index].sceneId = nil
        }
        do {
            try await APIClient.shared.deleteScene(scene.id)
            pushUndo("Szene „\(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")“ gelöscht") { [weak self] in
                guard let self else { return }
                guard let recreated = await self.createScene(
                    name: scene.name ?? "",
                    color: scene.color,
                    description: scene.description,
                    dialogue: scene.dialogue,
                    scheduledAt: scene.scheduledAt,
                    durationMinutes: scene.durationMinutes,
                    sectionId: scene.sectionId,
                    priority: scene.priority,
                    isIntermediateStep: scene.isIntermediateStep
                ) else { return }
                for shotId in orphanedShotIds {
                    _ = try? await APIClient.shared.patchShot(shotId, sceneId: recreated.id)
                }
                await self.load()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Duplicates a scene (2026-07-11, matches the web app's
    /// handleDuplicateScene) — full `load()` afterward rather than patching
    /// `scenes` locally, same reasoning as the web version: the backend
    /// shifts every sibling's sortOrder from the insertion point onward to
    /// make room right next to the original, and re-deriving that shift
    /// client-side is exactly the kind of drift-prone logic the drag-reorder
    /// bugs earlier this project came from.
    func duplicateScene(_ scene: Scene) async {
        do {
            _ = try await APIClient.shared.duplicateScene(scene.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 2026-07-14, Lino: "mehrere Personen auswählen können und auch wieder
    /// entfernen können" — toggles one id in/out of assigneeIds, mirrors
    /// web's toggleAssignee in SceneCard.tsx exactly (same reasoning:
    /// present-vs-absent on the wire, not null-vs-omitted, so an empty
    /// array is a real "nobody assigned" value, no separate clear flag).
    func toggleSceneAssignee(_ scene: Scene, userId: String) async {
        var next = scene.assigneeIds
        if let idx = next.firstIndex(of: userId) {
            next.remove(at: idx)
        } else {
            next.append(userId)
        }
        do {
            let updated = try await APIClient.shared.patchScene(scene.id, assigneeIds: next)
            if let index = scenes.firstIndex(where: { $0.id == updated.id }) {
                scenes[index] = updated
            }
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
        // is_project_info no longer skips positioning (2026-07-11, matches
        // scenes(in:)'s own removal of "Info tile always sorts first") — it
        // reorders exactly like any other scene now.
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
    /// Two-step server-authoritative move (2026-07-13) — was a client-
    /// computed loop that PATCHed scene_id+sort_order for EVERY shot in the
    /// destination list (redundantly re-sending the same target scene_id
    /// for shots that never actually changed scene, just to nudge their
    /// sort_order). Replaced with: (1) reassign scene_id on just the moved
    /// shot, if it changed, then (2) a single call to the new
    /// /shots/{id}/move endpoint for the authoritative position — same
    /// two-step pattern scenes already use for cross-section moves, and
    /// the same shared move endpoint the web app now calls too.
    func moveShot(_ shotId: String, toScene sceneId: String?, before targetId: String? = nil) async {
        guard let shot = shots.first(where: { $0.id == shotId }) else { return }
        do {
            if shot.sceneId != sceneId {
                // sortOrder here is a throwaway placeholder — step 2 below
                // immediately computes the real, authoritative position.
                let reassigned = try await APIClient.shared.moveShot(shotId, sceneId: sceneId, sortOrder: 0)
                replace(reassigned)
            }
            let moved = try await APIClient.shared.moveShot(shotId, beforeShotId: targetId)
            replace(moved)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Scene reordering (up/down menu): a single server-side move — see
    /// APIClient.moveScene. The server renumbers just the moved scene
    /// (screenplay-style) and reassigns every sibling's sort_order in one
    /// transaction; locally we just optimistically relocate it in `scenes`
    /// and then reconcile with whatever the server returns.
    /// Deliberately the simplest correct version, after several rounds of
    /// trying to also make "drag onto the immediate next neighbor" produce
    /// a visible move (inserting AFTER the target for downward drags) —
    /// that required knowing drag direction, which needed tracking WHICH
    /// scene is being dragged during an active hover, which turned out to
    /// have no reliable signal (.draggable() has no drag-started callback;
    /// approximating it via onAppear/onDisappear on the drag-lift preview
    /// view was NOT reliable in practice — the indicator ended up always
    /// showing "before" regardless of actual direction, and the extra
    /// state churn made the pick-up animation itself feel broken, reported
    /// live 2026-07-11). Reverted that whole layer. This version ALWAYS
    /// inserts before the literal drop target, using the target's index in
    /// the POST-removal sibling list — the one thing this can't do is move
    /// a scene to be right after its own immediate current neighbor
    /// (removing it and reinserting "before" that neighbor cancels out to
    /// the same position, a no-op) — accepted as a known, narrow
    /// limitation in exchange for the indicator ALWAYS being correct and
    /// nothing about this depending on unreliable state.
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
        // referencing a scene in a totally different section. Found live,
        // 2026-07-11 ("kann Projektinfo nicht in einen Abschnitt mit
        // Szenen verschieben").
        var siblings = scenes.filter { $0.sectionId == scene.sectionId }.sorted { $0.sortOrder < $1.sortOrder }
        siblings.removeAll { $0.id == sceneId }
        let insertIndex = targetId.flatMap { id in siblings.firstIndex(where: { $0.id == id }) } ?? siblings.count
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

    enum SceneSortCriterion {
        case number, time, location, priority
    }

    /// must < should < optional < none — used by .priority sorting below.
    private func priorityRank(_ p: ShotPriority?) -> Int {
        switch p {
        case .must: return 0
        case .should: return 1
        case .optional: return 2
        case nil: return 3
        }
    }

    /// Auto-sort button (2026-07-13, Lino: "ein Button um die Kacheln
    /// automatisch nach Identifikationsnummer/Zeit/Ort zu sortieren") —
    /// sorts one section's (or the unsectioned bucket's, sectionId nil)
    /// scenes locally by the chosen key, then persists the whole new order
    /// in a single request (see reorderScenes) instead of one move call per
    /// scene. Scenes missing the sort key sort to the end.
    func sortScenes(sectionId: String?, by criterion: SceneSortCriterion) async {
        let group = scenes.filter { $0.sectionId == sectionId }
        let sorted = group.sorted { a, b in
            switch criterion {
            case .number:
                let av = a.number * 1000 + Int(a.letter?.unicodeScalars.first?.value ?? 0)
                let bv = b.number * 1000 + Int(b.letter?.unicodeScalars.first?.value ?? 0)
                return av < bv
            case .time:
                switch (a.scheduledAt, b.scheduledAt) {
                case let (av?, bv?): return av < bv
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                }
            case .location:
                switch (a.locationAddress, b.locationAddress) {
                case let (av?, bv?): return av.localizedCaseInsensitiveCompare(bv) == .orderedAscending
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                }
            case .priority:
                // must < should < optional < none, scheduledAt breaks ties
                // within the same priority (2026-07-14, Lino: "bei prio
                // evtl. auch die zeitreihenfolge beachten").
                let ar = priorityRank(a.priority), br = priorityRank(b.priority)
                if ar != br { return ar < br }
                switch (a.scheduledAt, b.scheduledAt) {
                case let (av?, bv?): return av < bv
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        }
        let orderedIds = sorted.map(\.id)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            for (index, id) in orderedIds.enumerated() {
                if let i = scenes.firstIndex(where: { $0.id == id }), scenes[i].sortOrder != index {
                    scenes[i].sortOrder = index
                }
            }
        }
        do {
            _ = try await APIClient.shared.reorderScenes(projectId: projectId, sectionId: sectionId, orderedSceneIds: orderedIds)
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

    /// Mirrors clearProjectLocation/clearSceneLocation — same missing UI
    /// hookup, same fix (2026-07-14).
    func clearSectionLocation(_ section: SceneSection) async {
        do {
            let updated = try await APIClient.shared.patchSection(section.id, clearLocation: true)
            if let index = sections.firstIndex(where: { $0.id == updated.id }) {
                sections[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSectionClientName(_ section: SceneSection, name: String) async {
        do {
            let updated = try await APIClient.shared.patchSection(section.id, clientName: name)
            if let index = sections.firstIndex(where: { $0.id == updated.id }) {
                sections[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
