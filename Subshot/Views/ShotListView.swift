import SwiftUI
import UIKit

/// ShotCard's own priority dot — must=red, should=orange, optional=gray.
private func priorityColor(_ priority: ShotPriority) -> Color {
    switch priority {
    case .must: return .red
    case .should: return .orange
    case .optional: return .gray
    }
}

/// Scenes no longer have their own manually-picked color (removed —
/// priority carries the color now instead, see SceneEditSheet) — this is
/// the scene number badge's fill. Four distinct colors, one per priority
/// including "none", so every scene reads as visually distinct by
/// importance without a separate color picker to maintain.
private func sceneAccentColor(_ priority: ShotPriority?) -> Color {
    switch priority {
    case .must: return .red
    case .should: return .orange
    case .optional: return Color(red: 0x3d / 255.0, green: 0x84 / 255.0, blue: 0xd8 / 255.0)
    case nil: return Color(.systemGray3)
    }
}

struct ShotListView: View {
    @StateObject private var viewModel: ShotListViewModel
    let projectName: String
    /// .regular (iPad, full-width Split View) gets the adjustable-column
    /// grid (see ipadColumnCount + columnCountPopover); .compact iPad
    /// (narrow Slide Over/multitasking) keeps the simple 1-vs-2 isGridMode
    /// toggle. Neither is offered on iPhone at all — a phone-width screen
    /// has no useful multi-column layout, and the toggle itself was
    /// reported as confusing clutter there.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// `.compact` alone can't tell an iPhone from an iPad in narrow Slide
    /// Over/multitasking (both report it) — the grid/column controls below
    /// need to distinguish those two, so they check the actual device idiom
    /// instead of just the size class.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @State private var addingToScene: String??  // nil = not adding; .some(nil) = "no scene"; .some(id) = that scene
    @State private var newShotText = ""
    @State private var selectedShot: Shot?
    @State private var showingTeamSheet = false
    @State private var editingScene: Scene??      // nil = sheet closed; .some(nil) = creating; .some(scene) = renaming
    /// Only meaningful while editingScene == .some(nil) (creating) — which
    /// FAB menu option was tapped. Not persisted anywhere; a reduced-field
    /// SceneEditSheet is purely a creation-time UI choice, see its own doc
    /// comment.
    @State private var creatingIntermediateStep = false
    /// Set right before opening SectionEditSheet from the "Projektinfo"
    /// entry in addSceneButton's menu (2026-07-10, Lino: wants Projektinfo
    /// reachable from the same "+" menu as Neue Szene/Zwischenschritt/
    /// Abschnitt, not only via the small per-section button once a section
    /// already exists) — creates a section AND immediately gives it a
    /// project-info box in one step, see the sheet's onSave closure below.
    @State private var creatingSectionWithProjectInfo = false
    @State private var editingSection: SceneSection??  // same nesting convention as editingScene
    @State private var sectionToDelete: SceneSection?
    /// "Ohne Abschnitt" has no SceneSection id of its own to key off of (see
    /// isSectionCollapsed/toggleSectionCollapse) — this sentinel stands in
    /// for it so the same Set can track every section's collapsed state,
    /// including the unsectioned bucket.
    private let unassignedSectionKey = "__unassigned__"
    @State private var collapsedSections: Set<String> = []
    /// Long-press target for the Bearbeiten/Löschen action sheet — replaces
    /// the old .contextMenu on scene tiles (which (a) only ever offered
    /// Bearbeiten, never Löschen — there was no way to delete a scene at all
    /// — and (b) visually enlarges/snapshots the source view for its preview,
    /// which distorted this app's custom card layout; a plain
    /// .confirmationDialog never resizes the tile it was triggered from).
    /// .contextMenu and .draggable also compete for the same long-press
    /// gesture on iOS, which is the likely reason dragging scene tiles
    /// wasn't reliably starting at all — onLongPressGesture's own
    /// maximumDistance naturally defers to .draggable once the finger
    /// actually moves, instead of the two systems fighting over the touch.
    @State private var sceneMenuTarget: Scene?
    @State private var sceneToDelete: Scene?
    @State private var sectionMenuTarget: SceneSection?
    @State private var shotMenuTarget: Shot?
    /// Which scene tile is currently hovered by an in-flight drag — drives
    /// the thin accent-color landing indicator above that tile (see
    /// sceneCard). Not "which scene is being dragged": .draggable() doesn't
    /// expose a drag-started callback, only drop-target hover does.
    @State private var dropTargetSceneId: String?
    /// Which completed ("im Kasten") scenes are temporarily expanded back to
    /// full detail — collapsed is the default for any completed scene (see
    /// sceneCard/sceneCollapsedRow), tapping one adds it here to "peek" at
    /// full detail again. Deliberately session-local UI state, not persisted
    /// — a fresh load always starts every completed scene collapsed.
    @State private var expandedCompletedSceneIds: Set<String> = []
    @State private var isExportingPdf = false
    @State private var exportedPdfURL: URL?
    @State private var showingNotionImport = false
    @State private var shareLinkURL: URL?
    @State private var isPresentingShareSheet = false
    @State private var showingShareLinkSheet = false
    /// List (current, one full-width tile per row) vs. grid (2 columns) —
    /// per-device preference, not project state, so it doesn't need a
    /// backend round trip and each person on set can pick what fits their
    /// phone/how they like to scan the board.
    @AppStorage("shotListGridMode") private var isGridMode = false
    /// Independent of isGridMode/ipadColumnCount above (those control column
    /// *count* for the same full-detail card) — this switches to an entirely
    /// different, reduced-info 2-column tile (photo + number/title/priority +
    /// timer only, no dialogues/address/good-take/assignee/description) for a
    /// fast visual overview. Available on every device, not iPad-gated like
    /// the column controls, since a phone-width quick scan is exactly the
    /// point of this mode.
    @AppStorage("sceneCompactTileMode") private var isCompactTileMode = false
    /// iPad-only column count, adjustable via a slider (see
    /// columnCountPopover) — 1...4, stored as Double since Slider needs a
    /// floating-point binding; always rounded before use as a grid column
    /// count or an array-repeat argument.
    @AppStorage("shotListIpadColumnCount") private var ipadColumnCountRaw: Double = 3
    @State private var showingColumnCountPopover = false
    private var ipadColumnCount: Int { Int(ipadColumnCountRaw.rounded()) }
    /// Quick good-take entry always available on a scene's main tile — see
    /// sceneGoodTakeButton.
    @State private var editingGoodTakeScene: Scene?
    @State private var goodTakeText = ""
    @FocusState private var newRowFocused: Bool
    private let projectId: String

    init(projectId: String, projectName: String) {
        self.projectId = projectId
        _viewModel = StateObject(wrappedValue: ShotListViewModel(projectId: projectId))
        self.projectName = projectName
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Scrolls with the rest of the content again — the earlier
                // hang/crash turned out to be the general iOS-26.5-Simulator
                // rendering bug (see project memory), not MapKit itself, so
                // scene tiles below do use a real MKMapSnapshotter thumbnail
                // (SceneMapThumbnail, cached like AsyncShotThumbnail so
                // LazyVStack recycling doesn't regenerate one per re-render).
                ProjectInfoBox(viewModel: viewModel, projectId: projectId)

                unassignedSection()

                // Sections are opt-in — a project that's never created one
                // renders exactly like before (flat scene list, no headers).
                // Only once at least one section exists does grouping (with
                // an explicit "Ohne Abschnitt" bucket for the rest) kick in.
                if viewModel.sections.isEmpty {
                    // scenes(in: nil), not the raw array — a project with no
                    // sections yet still has every scene's sectionId == nil,
                    // so this is equivalent to the unsectioned bucket below,
                    // just without its own header.
                    sceneGrid(viewModel.scenes(in: nil))
                } else {
                    ForEach(viewModel.sections) { section in
                        sectionGroup(section: section)
                    }
                    let unassigned = viewModel.scenes(in: nil)
                    if !unassigned.isEmpty {
                        sectionGroup(section: nil)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottomTrailing) {
            addSceneButton
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // Reduced-info 2-column tile overview vs. today's full-detail
                // cards — orthogonal to the iPad-only column controls below
                // (those change how many full cards fit per row; this changes
                // how much detail each tile shows at all), so it's offered on
                // every device including iPhone.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isCompactTileMode.toggle() }
                } label: {
                    Image(systemName: isCompactTileMode ? "checklist" : "square.grid.2x2")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isPad {
                    if horizontalSizeClass == .regular {
                        Button {
                            showingColumnCountPopover = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .popover(isPresented: $showingColumnCountPopover) {
                            columnCountPopover
                        }
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { isGridMode.toggle() }
                        } label: {
                            Image(systemName: isGridMode ? "rectangle.grid.1x2" : "square.grid.2x2")
                        }
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if let exportedPdfURL {
                    ShareLink(item: exportedPdfURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        Task { await exportPdf() }
                    } label: {
                        if isExportingPdf {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExportingPdf)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                // Opens the management sheet (link + optional password)
                // instead of sharing straight away — password protection
                // needs a place to live, and folding it into a quick-share
                // one-tap button would either bury it or turn every share
                // into a two-tap flow either way, so it's its own sheet now.
                Button {
                    showingShareLinkSheet = true
                } label: {
                    Image(systemName: "link")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingTeamSheet = true } label: {
                    Image(systemName: "person.2")
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        // Lightweight "live updates" (2026-07-10): polls every 12s while
        // this screen is open so a teammate's edits show up without anyone
        // pulling to refresh — deliberately NOT a websocket/real-time typing
        // sync (overkill for a shot list: people mostly toggle checkboxes/
        // add shots, not co-edit the same text field char-by-char). `load()`
        // already replaces state via whole-array assignment matched by
        // Identifiable id, which SwiftUI diffs in place with no flicker/
        // loading-spinner flash (no isLoading gate anywhere in this view) —
        // confirmed that's what makes this safe to do silently in the
        // background. Separate `.task` from the initial load above so a
        // pull-to-refresh or the first load isn't affected by this timer's
        // own lifecycle.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if Task.isCancelled { break }
                await viewModel.load()
            }
        }
        .sheet(item: $selectedShot) { shot in
            ShotDetailSheet(shot: shot, viewModel: viewModel)
        }
        .sheet(isPresented: $showingTeamSheet) {
            TeamSheet(projectId: projectId)
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            if let shareLinkURL {
                ActivityView(activityItems: [shareLinkURL])
            }
        }
        .sheet(isPresented: $showingShareLinkSheet) {
            ShareLinkSheet(projectId: projectId) { url in
                shareLinkURL = url
                isPresentingShareSheet = true
            }
        }
        .sheet(isPresented: $showingNotionImport) {
            NotionImportSheet(projectId: projectId) {
                await viewModel.load()
            }
        }
        // Every failed API call in this screen (including a scene/shot image
        // upload that didn't make it — e.g. a dropped connection mid-upload)
        // only ever set viewModel.errorMessage; nothing displayed it, so
        // those failures were completely silent — "the image just doesn't
        // show up" with no error at all. This is the single alert for all of
        // them.
        .alert("Fehler", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Good Take", isPresented: Binding(
            get: { editingGoodTakeScene != nil },
            set: { if !$0 { editingGoodTakeScene = nil } }
        )) {
            TextField("Dateiname, z.B. A003_C012", text: $goodTakeText)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                if let scene = editingGoodTakeScene {
                    let trimmed = goodTakeText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await viewModel.setSceneGoodTake(scene, filename: trimmed.isEmpty ? nil : trimmed) }
                }
            }
        } message: {
            Text("Dateiname der guten Aufnahme für diese Szene.")
        }
        .alert("Alles im Kasten?", isPresented: $viewModel.showAllTimedScenesDoneConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Alle Shots wirklich im Kasten, hast du auch wirklich keine Aussage oder Szene vergessen?")
        }
        // All 5 of these (Abschnitt/Szene-löschen alerts, Szene/Abschnitt/
        // Einstellung long-press action sheets) used to be inline modifiers
        // right here — Xcode's "unable to type-check in reasonable time" on
        // this file was this modifier chain (already long before these were
        // added: sheets, other alerts, toolbar, task, etc., all on the same
        // body expression) finally tipping over. Moved into their own
        // ViewModifier below so the compiler only has to type-check one
        // `.modifier(...)` call here instead of 5 more inline ones with
        // embedded ternaries/ViewBuilder closures.
        .modifier(TileActionDialogs(
            viewModel: viewModel,
            sectionToDelete: $sectionToDelete,
            sceneMenuTarget: $sceneMenuTarget,
            sceneToDelete: $sceneToDelete,
            sectionMenuTarget: $sectionMenuTarget,
            shotMenuTarget: $shotMenuTarget,
            editingScene: $editingScene,
            editingSection: $editingSection
        ))
        .sheet(isPresented: Binding(
            get: { editingScene != nil },
            set: { if !$0 { editingScene = nil } }
        )) {
            if case .some(let existing) = editingScene {
                SceneEditSheet(existing: existing, isIntermediateStep: creatingIntermediateStep, viewModel: viewModel) { name, color, description, dialogue, scheduledAt, durationMinutes, priority in
                    if let existing {
                        await viewModel.renameScene(existing, name: name, color: color, description: description, dialogue: dialogue, scheduledAt: scheduledAt, durationMinutes: durationMinutes, priority: priority)
                        return existing
                    } else {
                        return await viewModel.createScene(
                            name: name.isEmpty ? "Unbenannte Szene" : name, color: color,
                            description: description.isEmpty ? nil : description,
                            dialogue: dialogue.isEmpty ? nil : dialogue,
                            scheduledAt: scheduledAt,
                            durationMinutes: durationMinutes,
                            priority: priority,
                            isIntermediateStep: creatingIntermediateStep
                        )
                    }
                } onImagePicked: { scene, image in
                    await viewModel.uploadSceneImage(scene, image: image)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingSection != nil },
            set: { if !$0 { editingSection = nil; creatingSectionWithProjectInfo = false } }
        )) {
            if case .some(let existing) = editingSection {
                SectionEditSheet(existing: existing) { name in
                    if let existing {
                        await viewModel.renameSection(existing, name: name)
                    } else if let created = await viewModel.createSection(name: name) {
                        if creatingSectionWithProjectInfo {
                            await viewModel.addSectionProjectInfo(created)
                        }
                        creatingSectionWithProjectInfo = false
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let pending = viewModel.pendingUndoShot {
                undoToast(for: pending)
            }
        }
    }

    /// Always-visible floating add button, bottom-trailing — replaces the old
    /// inline "Szene hinzufügen" row at the end of the list, which meant
    /// scrolling all the way down every time. A short menu now, so the same
    /// button also creates sections instead of needing a second control.
    /// iPad-only: lets someone pick how many columns of scene tiles fit
    /// side by side — more columns naturally means smaller tiles, there's no
    /// separate "tile size" knob since the two are the same thing once the
    /// grid is fixed-width.
    private var columnCountPopover: some View {
        VStack(spacing: 12) {
            Text("\(ipadColumnCount) Spalten")
                .font(.headline)
            Slider(value: $ipadColumnCountRaw, in: 1...4, step: 1)
                .frame(width: 220)
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }

    private var addSceneButton: some View {
        Menu {
            Button {
                creatingIntermediateStep = false
                editingScene = .some(nil)
            } label: {
                Label("Neue Szene", systemImage: "film")
            }
            Button {
                creatingIntermediateStep = true
                editingScene = .some(nil)
            } label: {
                Label("Zwischenschritt", systemImage: "arrow.triangle.branch")
            }
            Button {
                editingSection = .some(nil)
            } label: {
                Label("Neuer Abschnitt", systemImage: "folder.badge.plus")
            }
            Button {
                creatingSectionWithProjectInfo = true
                editingSection = .some(nil)
            } label: {
                Label("Projektinfo", systemImage: "info.circle")
            }
            Button {
                showingNotionImport = true
            } label: {
                Label("Von Notion importieren", systemImage: "square.and.arrow.down.on.square")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Sections

    /// Renders a set of scene cards either as today's single full-width
    /// column, or as a 2-column grid — see isGridMode. Grid mode owns the
    /// horizontal padding + inter-column gap itself (sceneCard skips its own
    /// side padding in that mode, see sceneCard's modifier chain) so columns
    /// and the row spacing above/below read as one consistent gap, not a
    /// doubled-up one.
    @ViewBuilder
    private func sceneGrid(_ scenes: [Scene]) -> some View {
        if isCompactTileMode {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(scenes) { scene in
                    sceneCompactTile(scene: scene)
                }
            }
            .padding(.horizontal, 16)
        } else if horizontalSizeClass == .regular {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: ipadColumnCount), spacing: 16) {
                ForEach(scenes) { scene in
                    sceneCard(scene: scene, columnLayout: ipadColumnCount > 1)
                }
            }
            .padding(.horizontal, 16)
        } else if isPad && isGridMode {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(scenes) { scene in
                    sceneCard(scene: scene, columnLayout: true)
                }
            }
            .padding(.horizontal, 16)
        } else {
            ForEach(scenes) { scene in
                sceneCard(scene: scene, columnLayout: false)
            }
        }
    }

    /// `section == nil` renders the "Ohne Abschnitt" bucket — only shown at
    /// all once at least one real section exists (see body above). Uses
    /// unassignedSectionKey to participate in the same collapse tracking as
    /// real sections (see isSectionCollapsed/toggleSectionCollapse) even
    /// though it has no SceneSection id of its own.
    @ViewBuilder
    private func sectionGroup(section: SceneSection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section: section)
            if let section {
                sectionProjectInfoArea(section: section)
            }
            if !isSectionCollapsed(section) {
                sceneGrid(viewModel.scenes(in: section))
                // Always-present drop target INSIDE the section, below its
                // scenes — an empty (or collapsed) section previously had
                // only its thin header row to drop onto, easy to miss
                // entirely. This one's always at least 44pt tall and has an
                // explicit contentShape so the whole area (not just where
                // something happens to be drawn) accepts the drop.
                sectionDropZone(section: section)
            }
        }
    }

    private func isSectionCollapsed(_ section: SceneSection?) -> Bool {
        collapsedSections.contains(section?.id ?? unassignedSectionKey)
    }

    private func toggleSectionCollapse(_ section: SceneSection?) {
        let key = section?.id ?? unassignedSectionKey
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            if collapsedSections.contains(key) {
                collapsedSections.remove(key)
            } else {
                collapsedSections.insert(key)
            }
        }
    }

    /// Multi-day shoots (2026-07-10): shows the section's SectionInfoBox
    /// once it has one. No more per-section "+ Projektinfo hinzufügen"
    /// button (same day, Lino: it showed above every single section
    /// regardless of whether that section had one yet, which read as
    /// clutter once "Projektinfo" became its own option in the main "+"
    /// menu — that menu creates a section with project info already
    /// attached in one step, so there's no "plain section, add info later"
    /// path to support here anymore). Never shown for the unsectioned
    /// "Ohne Abschnitt" bucket (that one has no SceneSection of its own to
    /// attach an info box to, only the project-level ProjectInfoBox exists
    /// there).
    @ViewBuilder
    private func sectionProjectInfoArea(section: SceneSection) -> some View {
        if section.hasProjectInfo {
            SectionInfoBox(viewModel: viewModel, section: section, projectId: projectId)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func sectionDropZone(section: SceneSection?) -> some View {
        Color.clear
            .frame(height: 44)
            .contentShape(Rectangle())
            .overlay {
                if dropTargetSceneId == "zone:\(section?.id ?? "none")" {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                }
            }
            .padding(.horizontal, 16)
            .dropDestination(for: String.self) { ids, _ in
                guard let raw = ids.first, raw.hasPrefix("scene:") else { return false }
                let sceneId = String(raw.dropFirst("scene:".count))
                guard let dragged = viewModel.scenes.first(where: { $0.id == sceneId }) else { return false }
                Task { await viewModel.assignSceneToSection(dragged, sectionId: section?.id) }
                return true
            } isTargeted: { targeted in
                let zoneId = "zone:\(section?.id ?? "none")"
                withAnimation(.easeOut(duration: 0.15)) {
                    dropTargetSceneId = targeted ? zoneId : (dropTargetSceneId == zoneId ? nil : dropTargetSceneId)
                }
            }
    }

    @ViewBuilder
    private func sectionHeader(section: SceneSection?) -> some View {
        let row = sectionHeaderRow(section: section)
        if let section {
            // Long-press-and-hold the header row to pick the whole section
            // up and drop it on another section's header to reorder — same
            // haptic drag idiom as project/scene tiles.
            row
                .draggable("section:\(section.id)")
                .dropDestination(for: String.self) { ids, _ in
                    guard let raw = ids.first, raw.hasPrefix("section:") else { return }
                    let draggedId = String(raw.dropFirst("section:".count))
                    guard draggedId != section.id else { return }
                    Task { await viewModel.reorderSection(draggedId, before: section.id) }
                }
        } else {
            row
        }
    }

    /// Whole row (chevron + name, "Ohne Abschnitt" included) toggles
    /// collapse on tap now, not just the small chevron hit target — and
    /// long-press opens Umbenennen/Löschen instead of a separate
    /// ellipsis-icon Menu button (see sceneMenuTarget's doc comment on why
    /// icon-triggered menus were replaced project-wide). "Ohne Abschnitt"
    /// has nothing to rename/delete, so it only gets the tap-to-collapse
    /// behavior, no long-press action.
    @ViewBuilder
    private func sectionHeaderRow(section: SceneSection?) -> some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isSectionCollapsed(section) ? 0 : 90))
                .frame(width: 30, height: 30)
            Text(section?.name ?? "Ohne Abschnitt")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let section {
                let scenes = viewModel.scenes(in: section)
                let done = scenes.filter(\.completed).count
                Text("\(done)/\(scenes.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture { toggleSectionCollapse(section) }
        .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 15) {
            if let section {
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                sectionMenuTarget = section
            }
        }
    }

    /// No "Einstellung hinzufügen" row here (unlike sceneCard) — new shots
    /// only get created inside a scene now. This still shows/holds any
    /// already-unassigned shots (and stays a drop target for dragging one
    /// back out of a scene), just doesn't offer to create new ones loose.
    @ViewBuilder
    private func unassignedSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.shots(in: nil)) { shot in
                shotCardView(shot: shot, sceneId: nil)
            }
        }
        .padding(.horizontal, 16)
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first else { return }
            Task { await viewModel.moveShot(dragged, toScene: nil) }
        }
    }

    /// A completed scene that isn't currently expanded (see
    /// expandedCompletedSceneIds) — collapsed is the default state for any
    /// "im Kasten" scene.
    private func isCollapsed(_ scene: Scene) -> Bool {
        scene.completed && !expandedCompletedSceneIds.contains(scene.id)
    }

    /// `columnLayout` is true whenever this card renders inside a 2+ column
    /// grid (see sceneGrid) rather than the default single full-width
    /// column — at half (or less) width, sceneTile's normally-unlimited
    /// description/dialogue text wrapped into far more lines than in the
    /// single-column layout, and since LazyVGrid does NOT equalize row
    /// heights across cells the way a description list would, cards ended
    /// up wildly different heights depending on how much text each scene
    /// happened to have. See sceneTile's own columnLayout handling for the
    /// line-limit/fixed-height fix. The per-scene shot list + "Einstellung
    /// hinzufügen" row is hidden here too in that mode, for the same
    /// reason (an arbitrary number of shot cards would defeat any attempt
    /// at a uniform tile height) — full detail incl. shots is still one tap
    /// away via the edit sheet, same reasoning sceneCompactTile already uses.
    @ViewBuilder
    private func sceneCard(scene: Scene, columnLayout: Bool) -> some View {
        let collapsed = isCollapsed(scene)
        VStack(alignment: .leading, spacing: 14) {
            // Landing indicator: shows exactly where a dragged scene will
            // insert if dropped right now (always "before this tile" — see
            // sceneTile's dropDestination) — a plain highlighted background
            // is ambiguous about above/below, a line at the top edge isn't.
            if dropTargetSceneId == scene.id {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
            if collapsed {
                sceneCollapsedRow(scene: scene)
            } else {
                sceneTile(scene: scene, columnLayout: columnLayout)
                // Zwischenschritt: no shot list at all, not even the add-row
                // — it's a lightweight connective beat, not a shootable
                // scene. Also hidden while collapsed above, along with
                // everything else — a collapsed "im Kasten" row is meant to
                // be a one-line summary, not a partial card.
                if !scene.isIntermediateStep, !columnLayout {
                    ForEach(viewModel.shots(in: scene)) { shot in
                        shotCardView(shot: shot, sceneId: scene.id)
                    }
                    addRow(sceneId: scene.id)
                }
            }
        }
        .padding(collapsed ? 10 : 14)
        .background(scene.completed ? Color.green.opacity(0.18) : Color(.secondarySystemGroupedBackground))
        .animation(.easeInOut(duration: 0.3), value: scene.completed)
        .animation(.easeInOut(duration: 0.25), value: collapsed)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .modifier(ScenePulseOnElapse(scene: scene))
        // Grid mode owns its own outer horizontal padding + inter-column gap
        // (see sceneGrid) — a card shouldn't also pad itself in that case, or
        // the gap between the two columns would be twice as wide as the gap
        // above/below.
        .padding(.horizontal, ((isPad && isGridMode) || horizontalSizeClass == .regular) ? 0 : 16)
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first, !dragged.hasPrefix("scene:") else { return }
            Task { await viewModel.moveShot(dragged, toScene: scene.id) }
        }
    }

    /// Collapsed "im Kasten" summary — just number/title/priority plus the
    /// start date if there is one, on the same green tint as the full card's
    /// completed background. Tap expands back to the full sceneTile (see
    /// isCollapsed/expandedCompletedSceneIds); editing still needs to work
    /// without expanding first, so it's reachable via long-press here too,
    /// same as the full tile once completed (see sceneMenuTarget).
    @ViewBuilder
    private func sceneCollapsedRow(scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(scene.displayNumber)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(sceneAccentColor(scene.priority))
                    .clipShape(Capsule())
                Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !scene.isIntermediateStep, let priority = scene.priority {
                    Text(priority.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(sceneAccentColor(priority))
                        .clipShape(Capsule())
                }
            }
            if let scheduledAt = scene.scheduledAt {
                Text("Start: \(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) { _ = expandedCompletedSceneIds.insert(scene.id) }
        }
        .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 15) {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            sceneMenuTarget = scene
        }
    }

    /// Image + header + description grouped as one tappable unit — tap
    /// anywhere on it to edit the scene. `.draggable`/`.dropDestination`
    /// live specifically on this tile (not the whole sceneCard, which also
    /// hosts shot cards with their own independent `.draggable()`) — dropping
    /// one scene tile onto another inserts it right before the target and,
    /// if the target sits in a different section, refiles it there too (see
    /// the dropDestination closure below).
    ///
    /// RE-ATTEMPT NOTE: an earlier version of this exact drag setup on scene
    /// tiles was tried twice before and both times made the whole ScrollView
    /// hang/lock up while scrolling (see git history) — that was never
    /// conclusively explained, only worked around by removing it. Re-added
    /// now on explicit request. MUST be verified on a real device before
    /// trusting it; if the same hang reappears, revert to a menu-based
    /// reorder rather than debugging blind from this server.
    @ViewBuilder
    private func sceneTile(scene: Scene, columnLayout: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageUrl = scene.imageUrl {
                AsyncShotThumbnail(path: imageUrl, size: nil, lockAspectRatio: true)
                    .frame(maxWidth: .infinity)
                    // Fixed image height in column layout (same value
                    // sceneCompactTile already uses) — at half tile width the
                    // aspect-locked thumbnail would otherwise still vary in
                    // height card to card depending on the source photo's
                    // aspect ratio, working against "immer gleich gross".
                    .frame(height: columnLayout ? 100 : nil)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            sceneHeader(scene: scene)
            SceneTimerInfo(scene: scene)
            // Separates the header/timer block above from the content below —
            // always shown (not conditional on description existing) so the
            // card reads as two clearly separated zones at a glance.
            Divider().opacity(0.6)
            // Grouped into one Group so this whole block (up to 5 conditional
            // sub-views) counts as a single child of the outer VStack's
            // ViewBuilder — the outer VStack already has a header, timer, two
            // new dividers, and the bottom row as siblings, so ungrouped this
            // would push past ViewBuilder's per-block child limit.
            Group {
                // No lineLimit in the single-column layout — description/
                // dialogue show in full there, with whatever line breaks the
                // person typed. In column layout (2+ columns, see sceneCard)
                // the same amount of text wraps into far more lines at half
                // width, which is what made grid-mode cards balloon to wildly
                // different heights — capped here instead so every card in
                // that mode reaches a similar, predictable size (full detail
                // is always one tap away via the edit sheet regardless).
                if let description = scene.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(columnLayout ? 3 : nil)
                        .fixedSize(horizontal: false, vertical: !columnLayout)
                }
                if let description = scene.description, !description.isEmpty,
                   let dialogue = scene.dialogue, !dialogue.isEmpty {
                    Divider()
                }
                if let dialogue = scene.dialogue, !dialogue.isEmpty {
                    Label(dialogue, systemImage: "quote.bubble")
                        .font(.subheadline.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(columnLayout ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: !columnLayout)
                }
                // Individually-checkable dialogue lines, stacked under the
                // legacy single-dialogue field above — read-only here on
                // purpose. Adding a new line only happens in SceneEditSheet
                // (tap into the scene first) so the main tile isn't cluttered
                // with an inline text field; this list just shows what's
                // already there so it can be checked off without opening the
                // sheet. Capped to the first 2 in column layout, same
                // reasoning as description/dialogue above.
                if !scene.isIntermediateStep, !scene.dialogues.isEmpty {
                    Label("Dialog", systemImage: "quote.bubble")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(columnLayout ? Array(scene.dialogues.prefix(2)) : scene.dialogues) { dialogue in
                        dialogueRow(dialogue: dialogue, scene: scene)
                    }
                    if columnLayout && scene.dialogues.count > 2 {
                        Text("+\(scene.dialogues.count - 2) weitere")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let address = scene.locationAddress, let lat = scene.locationLat, let lng = scene.locationLng {
                    HStack(spacing: 10) {
                        SceneMapThumbnail(lat: lat, lng: lng, size: 56)
                        Text(address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            // Separates the content above from the bottom action row below —
            // reads as its own little strip (good take / assignee / im Kasten).
            Divider().opacity(0.6)
            // Good Take (left) / assignee (center) / "Im Kasten" (right) — two
            // spacers distribute the three roughly evenly instead of clumping
            // assignee+imKasten together at the trailing edge.
            HStack(spacing: 8) {
                if !scene.isIntermediateStep {
                    sceneGoodTakeButton(scene: scene)
                }
                Spacer()
                sceneAssigneeMenu(scene: scene)
                Spacer()
                imKastenButton(scene: scene)
            }
        }
        // LazyVGrid doesn't equalize cell heights across a row on its own —
        // each column sizes to its own content. A fixed height (generous
        // enough for image + header + a few lines of content + the action
        // row) is what actually guarantees "Kacheln müssen immer gleich
        // gross aussehen" instead of just making it likely most of the time.
        // May need retuning once seen on a real device — this number is a
        // reasoned estimate, not a measured one.
        .frame(height: columnLayout ? 420 : nil, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            // A completed scene shown expanded (the user tapped its
            // collapsed row to peek) taps back to collapsed instead of
            // opening the edit sheet — editing it goes through the
            // long-press menu below instead, same as the collapsed row.
            if scene.completed {
                withAnimation(.easeInOut(duration: 0.25)) { _ = expandedCompletedSceneIds.remove(scene.id) }
            } else {
                editingScene = .some(scene)
            }
        }
        .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 15) {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            sceneMenuTarget = scene
        }
        .draggable("scene:\(scene.id)") {
            sceneDragPreview(scene: scene)
        }
        .dropDestination(for: String.self) { ids, _ in
            // The isTargeted-overload's action closure returns Bool (did
            // this view accept the drop), unlike the plain overload used
            // everywhere else in this file for shots.
            guard let raw = ids.first, raw.hasPrefix("scene:") else { return false }
            let draggedId = String(raw.dropFirst("scene:".count))
            guard draggedId != scene.id, let dragged = viewModel.scenes.first(where: { $0.id == draggedId }) else { return false }
            Task {
                if dragged.sectionId != scene.sectionId {
                    await viewModel.assignSceneToSection(dragged, sectionId: scene.sectionId)
                }
                await viewModel.reorderScene(draggedId, before: scene.id)
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                dropTargetSceneId = targeted ? scene.id : (dropTargetSceneId == scene.id ? nil : dropTargetSceneId)
            }
        }
    }

    /// Reduced-info counterpart to sceneTile for isCompactTileMode — photo,
    /// number/title/priority, and the timer only. Deliberately leaves out
    /// dialogues, address, good take, and assignee (all still one tap away:
    /// tapping the tile opens the same edit sheet as the full card) so a
    /// 2-column grid of these reads as a fast visual overview, not a smaller
    /// version of the same dense card. Reuses SceneTimerInfo/ScenePulseOnElapse
    /// as-is rather than duplicating the countdown/elapse logic.
    @ViewBuilder
    private func sceneCompactTile(scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imageUrl = scene.imageUrl {
                AsyncShotThumbnail(path: imageUrl, size: nil, lockAspectRatio: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .top, spacing: 6) {
                Text(scene.displayNumber)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(sceneAccentColor(scene.priority))
                    .clipShape(Capsule())
                Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            SceneTimerInfo(scene: scene)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scene.completed ? Color.green.opacity(0.18) : Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .modifier(ScenePulseOnElapse(scene: scene))
        .contentShape(Rectangle())
        .onTapGesture { editingScene = .some(scene) }
    }

    /// Custom drag preview instead of the system's plain view snapshot — a
    /// compact "lifted" card (shadow, slight rotation) so picking a scene up
    /// reads as a deliberate, physical action instead of just a ghost of
    /// the full tile following the finger.
    private func sceneDragPreview(scene: Scene) -> some View {
        HStack(spacing: 8) {
            Text(scene.displayNumber)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(sceneAccentColor(scene.priority))
                .clipShape(Capsule())
            Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .rotationEffect(.degrees(-2))
    }

    /// Two rows, not one: the title used to be squeezed between a drag handle
    /// and a row of action buttons, which left it almost no room. Now that
    /// scene reordering is drag & drop (no more handle icon), the title gets
    /// its own full-width row and can wrap to two lines.
    @ViewBuilder
    private func sceneHeader(scene: Scene) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(scene.displayNumber)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(sceneAccentColor(scene.priority))
                .clipShape(Capsule())
            Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            if !scene.isIntermediateStep, let priority = scene.priority {
                Text(priority.label)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(sceneAccentColor(priority))
                    .clipShape(Capsule())
            }
        }
    }

    /// Responsible person for this scene — same quick Menu pattern as todo
    /// item assignment (ProjectInfoBox.TodoItemRow), not tucked into the full
    /// edit sheet, so setting/changing it is a one-tap action from the list.
    @ViewBuilder
    private func sceneAssigneeMenu(scene: Scene) -> some View {
        let assignee = viewModel.members.first { $0.userId == scene.assigneeId }
        Menu {
            if assignee != nil {
                Button {
                    Task { await viewModel.assignScene(scene, to: nil) }
                } label: {
                    Label("Niemand zugewiesen", systemImage: "xmark.circle")
                }
            }
            ForEach(viewModel.members) { member in
                Button {
                    Task { await viewModel.assignScene(scene, to: member.userId) }
                } label: {
                    Text(member.name?.isEmpty == false ? member.name! : member.email)
                }
            }
        } label: {
            if let assignee {
                MemberAvatar(member: assignee, size: 32)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// "Im Kasten" ("it's a wrap" — scene fully shot): tapping it toggles
    /// `completed`, which tints the whole card green and collapses it to
    /// sceneCollapsedRow in place (see isCollapsed/sceneCard) — it used to
    /// also move the scene to the end of the list, removed since it made
    /// the list jump around mid-scroll while checking scenes off on set.
    /// A plain Button nested here so its tap takes priority over the
    /// surrounding tile's own onTapGesture/draggable.
    @ViewBuilder
    private func imKastenButton(scene: Scene) -> some View {
        Button {
            Task { await viewModel.setSceneCompleted(scene, completed: !scene.completed) }
        } label: {
            Label("Im Kasten", systemImage: scene.completed ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(scene.completed ? Color.green.opacity(0.25) : Color(.tertiarySystemGroupedBackground))
                .foregroundStyle(scene.completed ? .green : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: scene.completed)
    }

    /// Good-take filename entry, always on the scene's own main tile — lives
    /// on the scene itself (not a shot), so it's there whether the scene has
    /// zero, one, or several shots. A shot's own detail sheet has its own
    /// separate good-take field for per-shot logging; this one is the
    /// scene-level "the take we're keeping" note.
    @ViewBuilder
    private func sceneGoodTakeButton(scene: Scene) -> some View {
        let hasGoodTake = scene.goodTakeFilename?.isEmpty == false
        Button {
            goodTakeText = scene.goodTakeFilename ?? ""
            editingGoodTakeScene = scene
        } label: {
            Label(hasGoodTake ? scene.goodTakeFilename! : "Good Take", systemImage: "sdcard.fill")
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(hasGoodTake ? Color.green.opacity(0.25) : Color(.tertiarySystemGroupedBackground))
                .foregroundStyle(hasGoodTake ? .green : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shotCardView(shot: Shot, sceneId: String?) -> some View {
        ShotCard(shot: shot) {
            Task { await viewModel.toggleDone(shot) }
        }
            .contentShape(Rectangle())
            .onTapGesture { selectedShot = shot }
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 15) {
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                shotMenuTarget = shot
            }
            .draggable(shot.id)
            .dropDestination(for: String.self) { ids, _ in
                guard let dragged = ids.first, dragged != shot.id else { return }
                Task { await viewModel.moveShot(dragged, toScene: sceneId, before: shot.id) }
            }
    }

    /// One checkable spoken line — tapping the checkmark marks it recorded
    /// (strikethrough), long-press to remove it entirely.
    @ViewBuilder
    private func dialogueRow(dialogue: SceneDialogue, scene: Scene) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.toggleDialogue(dialogue, in: scene) }
            } label: {
                Image(systemName: dialogue.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(dialogue.done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            Text(dialogue.text)
                .font(.subheadline.italic())
                .foregroundStyle(.secondary)
                .strikethrough(dialogue.done)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await viewModel.deleteDialogue(dialogue, in: scene) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func addRow(sceneId: String?) -> some View {
        if addingToScene == .some(sceneId) {
            TextField("Neue Einstellung", text: $newShotText)
                .focused($newRowFocused)
                .submitLabel(.done)
                .onSubmit { Task { await commitNewShot(sceneId: sceneId) } }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Button {
                startAdding(sceneId: sceneId)
            } label: {
                Label("Einstellung hinzufügen", systemImage: "plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func undoToast(for shot: Shot) -> some View {
        HStack {
            Text("„\(shot.description ?? "Einstellung")" + "“ gelöscht")
                .font(.footnote)
                .lineLimit(1)
            Spacer()
            Button("Rückgängig") { viewModel.undoDelete() }
                .font(.footnote.bold())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    // MARK: - Actions

    private func startAdding(sceneId: String?) {
        newShotText = ""
        addingToScene = .some(sceneId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            newRowFocused = true
        }
    }

    private func commitNewShot(sceneId: String?) async {
        addingToScene = nil
        await viewModel.createShot(description: newShotText, sceneId: sceneId)
    }

    /// Downloads the project's PDF once and caches it at a temp URL — the
    /// toolbar swaps to a `ShareLink` for that URL afterward so re-tapping
    /// doesn't re-download; `.task`/`.onDisappear` isn't used to invalidate
    /// it since a stale PDF from a few edits ago is harmless to re-share.
    private func exportPdf() async {
        isExportingPdf = true
        defer { isExportingPdf = false }
        do {
            let data = try await APIClient.shared.projectPdf(projectId)
            let safeName = projectName.isEmpty ? "shotlist" : projectName
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).pdf")
            try data.write(to: url, options: .atomic)
            exportedPdfURL = url
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    /// Public, no-login link to this project's storyboard (see GET /share/
    /// {token} — server-rendered, responsive HTML, 7-day expiry). Server-side
    /// idempotent, so tapping this again later just extends the same link
    /// rather than creating a second, different URL to confuse whoever
    /// already has the first one.
}

/// Bundles the Szene/Abschnitt/Einstellung long-press action sheets and their
/// delete-confirmation alerts — pulled out of ShotListView.body (see the
/// `.modifier(TileActionDialogs(...))` call there) purely to keep the
/// compiler's job smaller; body was already a long chain of sheets/alerts/
/// toolbar/task modifiers on one expression before these existed, and adding
/// 5 more inline pushed Xcode into "unable to type-check this expression in
/// reasonable time".
private struct TileActionDialogs: ViewModifier {
    @ObservedObject var viewModel: ShotListViewModel
    @Binding var sectionToDelete: SceneSection?
    @Binding var sceneMenuTarget: Scene?
    @Binding var sceneToDelete: Scene?
    @Binding var sectionMenuTarget: SceneSection?
    @Binding var shotMenuTarget: Shot?
    @Binding var editingScene: Scene??
    @Binding var editingSection: SceneSection??

    func body(content: Content) -> some View {
        content
            .alert("Abschnitt löschen?", isPresented: Binding(
                get: { sectionToDelete != nil },
                set: { if !$0 { sectionToDelete = nil } }
            )) {
                Button("Abbrechen", role: .cancel) {}
                Button("Löschen", role: .destructive) {
                    if let section = sectionToDelete {
                        Task { await viewModel.deleteSection(section) }
                    }
                }
            } message: {
                Text(sectionDeleteMessage)
            }
            .confirmationDialog("Szene", isPresented: Binding(
                get: { sceneMenuTarget != nil },
                set: { if !$0 { sceneMenuTarget = nil } }
            ), presenting: sceneMenuTarget) { scene in
                Button("Bearbeiten") { editingScene = .some(scene) }
                if scene.completed {
                    Button("Nicht mehr im Kasten") {
                        Task { await viewModel.setSceneCompleted(scene, completed: false) }
                    }
                }
                Button("Löschen", role: .destructive) { sceneToDelete = scene }
                Button("Abbrechen", role: .cancel) {}
            }
            .alert("Szene löschen?", isPresented: Binding(
                get: { sceneToDelete != nil },
                set: { if !$0 { sceneToDelete = nil } }
            )) {
                Button("Abbrechen", role: .cancel) {}
                Button("Löschen", role: .destructive) {
                    if let scene = sceneToDelete {
                        Task { await viewModel.deleteScene(scene) }
                    }
                }
            } message: {
                Text(sceneDeleteMessage)
            }
            .confirmationDialog("Abschnitt", isPresented: Binding(
                get: { sectionMenuTarget != nil },
                set: { if !$0 { sectionMenuTarget = nil } }
            ), presenting: sectionMenuTarget) { section in
                Button("Umbenennen") { editingSection = .some(section) }
                Button("Löschen", role: .destructive) { sectionToDelete = section }
                Button("Abbrechen", role: .cancel) {}
            }
            .confirmationDialog("Einstellung", isPresented: Binding(
                get: { shotMenuTarget != nil },
                set: { if !$0 { shotMenuTarget = nil } }
            ), presenting: shotMenuTarget) { shot in
                Button(shot.status == .done ? "Als offen markieren" : "Erledigt") {
                    Task { await viewModel.toggleDone(shot) }
                }
                Button("Löschen", role: .destructive) { viewModel.deleteWithUndo(shot) }
                Button("Abbrechen", role: .cancel) {}
            }
    }

    // Scenes are NOT deleted when a section is (backend: Scene.section_id is
    // ON DELETE SET NULL) — they fall back to "Ohne Abschnitt". But if this
    // section carries its own Projektinfo (Drehdatum/Ort/Todo-Listen, see
    // SectionInfoBox), that IS deleted for good (TodoList.section_id is
    // ON DELETE CASCADE) — worth spelling out explicitly rather than leaving
    // it implied, since visually that info box reads as its own tile too.
    private var sectionDeleteMessage: String {
        guard let section = sectionToDelete else { return "" }
        if section.hasProjectInfo {
            return "\"\(section.name)\" wird gelöscht. Enthaltene Szenen bleiben erhalten und landen unter \"Ohne Abschnitt\" — die Projektinfo dieses Abschnitts (Drehdatum, Ort, Todo-Listen) wird aber endgültig gelöscht."
        }
        return "\"\(section.name)\" wird gelöscht. Enthaltene Szenen bleiben erhalten und landen unter \"Ohne Abschnitt\"."
    }

    private var sceneDeleteMessage: String {
        let name = sceneToDelete?.name?.isEmpty == false ? sceneToDelete!.name! : "Unbenannte Szene"
        return "\"\(name)\" wird endgültig gelöscht, inklusive aller Einstellungen darin."
    }
}

/// Thin wrapper so the share sheet can be triggered programmatically
/// (`.sheet(isPresented:)`) the instant the link URL is ready — SwiftUI's own
/// `ShareLink` only presents in response to a tap on itself, which is exactly
/// what forced the old two-tap flow (tap to fetch the URL, tap again on the
/// now-swapped-in `ShareLink` to actually see the share sheet).
private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Storyboard-style card: big photo (if one's been added) on top, description
/// and metadata below — replaces the old compact list row so the picture
/// itself carries the weight, matching how a shot list is actually used on
/// set (glance at the frame, not the text).
private struct ShotCard: View {
    let shot: Shot
    /// Lets the checkmark itself toggle done/open directly — previously the
    /// only way to do that was the long-press context menu ("Erledigt"),
    /// with this same checkmark shown purely as a static status icon right
    /// next to it. A nested Button here takes tap priority over the card's
    /// own onTapGesture (which opens the full detail sheet), same pattern as
    /// the scene tile's "Im Kasten" button.
    var onToggleDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let imageUrl = shot.imageUrl {
                    AsyncShotThumbnail(path: imageUrl, size: nil)
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.tertiarySystemGroupedBackground))
                        .frame(height: 90)
                        .overlay {
                            Image(systemName: "camera")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }

                HStack(spacing: 6) {
                    Button(action: onToggleDone) {
                        Image(systemName: shot.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(shot.status == .done ? .green : .white)
                            .font(.title3)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)

                    if let priority = shot.priority {
                        Circle()
                            .fill(priorityColor(priority))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(shot.description?.isEmpty == false ? shot.description! : "Ohne Beschreibung")
                    .font(.subheadline.weight(.medium))
                    .strikethrough(shot.status == .done)
                    .foregroundStyle(shot.status == .done ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    if let angle = shot.cameraAngle, !angle.isEmpty {
                        Label(angle, systemImage: "camera")
                    }
                    if let duration = shot.durationSeconds {
                        Label("\(duration)s", systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let goodTake = shot.goodTakeFilename, !goodTake.isEmpty {
                    Label("Good Take: \(goodTake)", systemImage: "sdcard.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }
            .padding(10)
        }
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func priorityColor(_ priority: ShotPriority) -> Color {
        switch priority {
        case .must: return .red
        case .should: return .orange
        case .optional: return .gray
        }
    }
}

/// scheduledAt is the shoot's START time now (not a deadline) — durationMinutes
/// is how long the shoot is expected to take. Three states, all driven off
/// one 1s TimelineView in the parent:
/// - before start: static "Geplante Drehzeit: Xmin"
/// - during [start, start+duration): live mm:ss countdown, grey more than
///   15min out, fading through yellow at 15min, red at 10min
/// - after end: "Drehzeit abgelaufen" — the one-time whole-card pulse on
///   crossing into this state lives on SceneCard's ScenePulseOnElapse,
///   not here.
private struct SceneTimerInfo: View {
    let scene: Scene

    var body: some View {
        if let scheduledAt = scene.scheduledAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                let end = scene.durationMinutes.map { scheduledAt.addingTimeInterval(TimeInterval($0) * 60) }
                let isRunning = end.map { now >= scheduledAt && now < $0 } ?? false

                HStack(alignment: .center, spacing: 8) {
                    Label("Start: \(scheduledAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(isRunning ? Color.yellow : Color(.secondaryLabel))
                        .animation(.easeInOut(duration: 0.4), value: isRunning)

                    Spacer(minLength: 8)

                    if let end {
                        if now < scheduledAt {
                            Label("Geplante Drehzeit: \(scene.durationMinutes.map { "\($0) Min." } ?? "")", systemImage: "timer")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else if isRunning {
                            LiveSceneBadge(remaining: end.timeIntervalSince(now))
                        } else {
                            Label("Drehzeit abgelaufen", systemImage: "timer")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Live mm:ss countdown while a scene is rolling — grey more than 15min from
/// the end, fading through yellow at the 15min mark, solid red from the 5min
/// mark on (previously only reached full red at 0 — now the whole badge also
/// pulses once it's solid red, not just the small "live" dot, so the last 5
/// minutes read as unmistakably urgent). The small white dot pulses
/// continuously the whole time as a general "live" indicator (unrelated to
/// the one-time whole-card pulse fired when the timer hits 0, see
/// ScenePulseOnElapse).
private struct LiveSceneBadge: View {
    let remaining: TimeInterval
    @State private var pulse = false

    private var isUrgent: Bool { remaining > 0 && remaining <= 300 }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.5 : 0.85)
                .opacity(pulse ? 0.35 : 1.0)
            Text("Verbleibend: \(Self.format(remaining))")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Self.color(for: remaining))
        .clipShape(Capsule())
        .scaleEffect(isUrgent && pulse ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.4), value: remaining <= 900)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private static func color(for remaining: TimeInterval) -> Color {
        if remaining <= 300 {
            return .red
        } else if remaining <= 600 {
            return Color.yellow.interpolated(to: .red, fraction: 1 - ((remaining - 300) / 300))
        } else if remaining <= 900 {
            return Color(.secondaryLabel).interpolated(to: .yellow, fraction: 1 - ((remaining - 600) / 300))
        } else {
            return Color(.secondaryLabel)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Pulses the whole scene card once, exactly on the tick where `now` crosses
/// from "running" into "elapsed" (scheduledAt + durationMinutes) — not a
/// continuous effect. Self-contained ViewModifier (not folded into SceneTile
/// directly) so it can own its own @State without restructuring the rest of
/// sceneCard's view-builder-function shape.
///
/// A spring (instead of the old linear easeInOut) gives the scale a natural
/// overshoot-and-settle instead of a hard snap back to 1.0, paired with a
/// brief red glow so the "pop" reads as an alert, not just a size change.
/// Also fires a haptic (vibration) at the exact same moment — the visual
/// pulse alone is easy to miss if the phone isn't being looked at right when
/// time runs out.
private struct ScenePulseOnElapse: ViewModifier {
    let scene: Scene
    @State private var pulse = false

    func body(content: Content) -> some View {
        guard let scheduledAt = scene.scheduledAt, let duration = scene.durationMinutes else {
            return AnyView(content)
        }
        let end = scheduledAt.addingTimeInterval(TimeInterval(duration) * 60)
        return AnyView(
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content
                    .scaleEffect(pulse ? 1.045 : 1.0)
                    .shadow(color: .red.opacity(pulse ? 0.4 : 0), radius: pulse ? 16 : 0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.55), value: pulse)
                    .onChange(of: context.date) { oldDate, newDate in
                        if oldDate < end && newDate >= end {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            pulse = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { pulse = false }
                        }
                    }
            }
        )
    }
}
