import SwiftUI

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
    case .optional: return .yellow
    case nil: return Color(.systemGray3)
    }
}

struct ShotListView: View {
    @StateObject private var viewModel: ShotListViewModel
    let projectName: String

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
    @State private var editingSection: SceneSection??  // same nesting convention as editingScene
    @State private var collapsedSections: Set<String> = []
    /// Which scene tile is currently hovered by an in-flight drag — drives
    /// the thin accent-color landing indicator above that tile (see
    /// sceneCard). Not "which scene is being dragged": .draggable() doesn't
    /// expose a drag-started callback, only drop-target hover does.
    @State private var dropTargetSceneId: String?
    @State private var isExportingPdf = false
    @State private var exportedPdfURL: URL?
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
                    ForEach(viewModel.scenes) { scene in
                        sceneCard(scene: scene)
                    }
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
                Button { showingTeamSheet = true } label: {
                    Image(systemName: "person.2")
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: $selectedShot) { shot in
            ShotDetailSheet(shot: shot, viewModel: viewModel)
        }
        .sheet(isPresented: $showingTeamSheet) {
            TeamSheet(projectId: projectId)
        }
        .sheet(isPresented: Binding(
            get: { editingScene != nil },
            set: { if !$0 { editingScene = nil } }
        )) {
            if case .some(let existing) = editingScene {
                SceneEditSheet(existing: existing, isIntermediateStep: creatingIntermediateStep, viewModel: viewModel) { name, color, description, dialogue, focalLength, scheduledAt, durationMinutes, priority in
                    if let existing {
                        await viewModel.renameScene(existing, name: name, color: color, description: description, dialogue: dialogue, focalLengthMm: focalLength, scheduledAt: scheduledAt, durationMinutes: durationMinutes, priority: priority)
                        return existing
                    } else {
                        return await viewModel.createScene(
                            name: name.isEmpty ? "Unbenannte Szene" : name, color: color,
                            description: description.isEmpty ? nil : description,
                            dialogue: dialogue.isEmpty ? nil : dialogue,
                            focalLengthMm: focalLength,
                            scheduledAt: scheduledAt,
                            durationMinutes: durationMinutes,
                            priority: priority
                        )
                    }
                } onImagePicked: { scene, image in
                    await viewModel.uploadSceneImage(scene, image: image)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingSection != nil },
            set: { if !$0 { editingSection = nil } }
        )) {
            if case .some(let existing) = editingSection {
                SectionEditSheet(existing: existing) { name in
                    if let existing {
                        await viewModel.renameSection(existing, name: name)
                    } else {
                        await viewModel.createSection(name: name)
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

    /// `section == nil` renders the "Ohne Abschnitt" bucket — only shown at
    /// all once at least one real section exists (see body above), and
    /// always expanded (no collapse toggle) since it has no identity of its
    /// own to persist a collapsed state against.
    @ViewBuilder
    private func sectionGroup(section: SceneSection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section: section)
            if section == nil || !collapsedSections.contains(section!.id) {
                ForEach(viewModel.scenes(in: section)) { scene in
                    sceneCard(scene: scene)
                }
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

    @ViewBuilder
    private func sectionHeaderRow(section: SceneSection?) -> some View {
        HStack {
            if let section {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        if collapsedSections.contains(section.id) {
                            collapsedSections.remove(section.id)
                        } else {
                            collapsedSections.insert(section.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsedSections.contains(section.id) ? 0 : 90))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
            if let section {
                Menu {
                    Button {
                        editingSection = .some(section)
                    } label: {
                        Label("Umbenennen", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        Task { await viewModel.deleteSection(section) }
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
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

    @ViewBuilder
    private func sceneCard(scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            sceneTile(scene: scene)
            ForEach(viewModel.shots(in: scene)) { shot in
                shotCardView(shot: shot, sceneId: scene.id)
            }
            addRow(sceneId: scene.id)
        }
        .padding(12)
        .background(scene.completed ? Color.green.opacity(0.18) : Color(.secondarySystemGroupedBackground))
        .animation(.easeInOut(duration: 0.3), value: scene.completed)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .modifier(ScenePulseOnElapse(scene: scene))
        .padding(.horizontal, 16)
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first, !dragged.hasPrefix("scene:") else { return }
            Task { await viewModel.moveShot(dragged, toScene: scene.id) }
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
    private func sceneTile(scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageUrl = scene.imageUrl {
                AsyncShotThumbnail(path: imageUrl, size: nil, lockAspectRatio: true)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            sceneHeader(scene: scene)
            SceneTimerInfo(scene: scene)
            // No lineLimit here on purpose — description/dialogue must always
            // show in full, with whatever line breaks the person typed
            // (Text renders literal "\n"s as-is; nothing strips them on the
            // way in from SceneEditSheet's TextField).
            if let description = scene.description, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let description = scene.description, !description.isEmpty,
               let dialogue = scene.dialogue, !dialogue.isEmpty {
                Divider()
            }
            if let dialogue = scene.dialogue, !dialogue.isEmpty {
                Label(dialogue, systemImage: "quote.bubble")
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let address = scene.locationAddress, let lat = scene.locationLat, let lng = scene.locationLng {
                HStack(spacing: 10) {
                    SceneMapThumbnail(lat: lat, lng: lng, size: 48)
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { editingScene = .some(scene) }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(scene.displayNumber)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(sceneAccentColor(scene.priority))
                    .clipShape(Capsule())
                Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("\(viewModel.shots(in: scene).count) Einstellungen")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                sceneAssigneeMenu(scene: scene)
                imKastenButton(scene: scene)
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
                let source = assignee.name?.isEmpty == false ? assignee.name! : assignee.email
                Text(String(source.prefix(2)).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.stableColor(for: assignee.userId))
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Im Kasten" ("it's a wrap" — scene fully shot): tapping it toggles
    /// `completed`, which tints the whole card green and (when turning it on)
    /// slides it to the bottom of the scene list — see
    /// `ShotListViewModel.setSceneCompleted` for the animation/reorder.
    /// A plain Button nested here so its tap takes priority over the
    /// surrounding tile's own onTapGesture/draggable.
    @ViewBuilder
    private func imKastenButton(scene: Scene) -> some View {
        Button {
            Task { await viewModel.setSceneCompleted(scene, completed: !scene.completed) }
        } label: {
            Label("Im Kasten", systemImage: scene.completed ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(scene.completed ? Color.green.opacity(0.25) : Color(.tertiarySystemGroupedBackground))
                .foregroundStyle(scene.completed ? .green : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: scene.completed)
    }

    @ViewBuilder
    private func shotCardView(shot: Shot, sceneId: String?) -> some View {
        ShotCard(shot: shot)
            .contentShape(Rectangle())
            .onTapGesture { selectedShot = shot }
            .contextMenu {
                Button {
                    Task { await viewModel.toggleDone(shot) }
                } label: {
                    Label(shot.status == .done ? "Als offen markieren" : "Erledigt", systemImage: "checkmark.circle")
                }
                Button(role: .destructive) {
                    viewModel.deleteWithUndo(shot)
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
            .draggable(shot.id)
            .dropDestination(for: String.self) { ids, _ in
                guard let dragged = ids.first, dragged != shot.id else { return }
                Task { await viewModel.moveShot(dragged, toScene: sceneId, before: shot.id) }
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

}

/// Storyboard-style card: big photo (if one's been added) on top, description
/// and metadata below — replaces the old compact list row so the picture
/// itself carries the weight, matching how a shot list is actually used on
/// set (glance at the frame, not the text).
private struct ShotCard: View {
    let shot: Shot

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
                    Image(systemName: shot.status == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(shot.status == .done ? .green : .white)
                        .font(.title3)
                        .shadow(radius: 2)

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
                    Label("Good Take: \(goodTake)", systemImage: "checkmark.seal.fill")
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

                VStack(alignment: .leading, spacing: 6) {
                    Label(scheduledAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(isRunning ? Color.yellow : Color(.secondaryLabel))
                        .animation(.easeInOut(duration: 0.4), value: isRunning)

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
/// the end, fading through yellow at the 15min mark, red at 10min. The small
/// white dot pulses continuously the whole time as a "live" indicator (this
/// is unrelated to the one-time whole-card pulse fired when the timer hits 0).
private struct LiveSceneBadge: View {
    let remaining: TimeInterval
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.5 : 0.85)
                .opacity(pulse ? 0.35 : 1.0)
            Text("Läuft · noch \(Self.format(remaining))")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Self.color(for: remaining))
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.4), value: remaining <= 900)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private static func color(for remaining: TimeInterval) -> Color {
        if remaining <= 0 {
            return .red
        } else if remaining <= 600 {
            return Color.yellow.interpolated(to: .red, fraction: 1 - (remaining / 600))
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
                    .scaleEffect(pulse ? 1.03 : 1.0)
                    .animation(.easeInOut(duration: 0.18), value: pulse)
                    .onChange(of: context.date) { oldDate, newDate in
                        if oldDate < end && newDate >= end {
                            pulse = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pulse = false }
                        }
                    }
            }
        )
    }
}
