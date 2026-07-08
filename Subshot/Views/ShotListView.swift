import SwiftUI

struct ShotListView: View {
    @StateObject private var viewModel: ShotListViewModel
    let projectName: String

    @State private var addingToScene: String??  // nil = not adding; .some(nil) = "no scene"; .some(id) = that scene
    @State private var newShotText = ""
    @State private var selectedShot: Shot?
    @State private var showingTeamSheet = false
    @State private var editingScene: Scene??      // nil = sheet closed; .some(nil) = creating; .some(scene) = renaming
    @State private var editingSection: SceneSection??  // same nesting convention as editingScene
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
                SceneEditSheet(existing: existing, viewModel: viewModel) { name, color, description, dialogue, focalLength, scheduledAt, durationMinutes in
                    if let existing {
                        await viewModel.renameScene(existing, name: name, color: color, description: description, dialogue: dialogue, focalLengthMm: focalLength, scheduledAt: scheduledAt, durationMinutes: durationMinutes)
                        return existing
                    } else {
                        return await viewModel.createScene(
                            name: name.isEmpty ? "Unbenannte Szene" : name, color: color,
                            description: description.isEmpty ? nil : description,
                            dialogue: dialogue.isEmpty ? nil : dialogue,
                            focalLengthMm: focalLength,
                            scheduledAt: scheduledAt,
                            durationMinutes: durationMinutes
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
                editingScene = .some(nil)
            } label: {
                Label("Neue Szene", systemImage: "film")
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
    /// all once at least one real section exists (see body above).
    @ViewBuilder
    private func sectionGroup(section: SceneSection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section: section)
            ForEach(viewModel.scenes(in: section)) { scene in
                sceneCard(scene: scene)
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(section: SceneSection?) -> some View {
        HStack {
            if let section {
                sectionReorderMenu(section: section)
            } else {
                Spacer().frame(width: 44)
            }
            Text(section?.name ?? "Ohne Abschnitt")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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
    }

    @ViewBuilder
    private func sectionReorderMenu(section: SceneSection) -> some View {
        Menu {
            Button {
                Task { await moveSectionUp(section) }
            } label: {
                Label("Nach oben", systemImage: "arrow.up")
            }
            Button {
                Task { await moveSectionDown(section) }
            } label: {
                Label("Nach unten", systemImage: "arrow.down")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private func moveSectionUp(_ section: SceneSection) async {
        guard let idx = viewModel.sections.firstIndex(where: { $0.id == section.id }), idx > 0 else { return }
        let target = viewModel.sections[idx - 1]
        await viewModel.reorderSection(section.id, before: target.id)
    }

    private func moveSectionDown(_ section: SceneSection) async {
        guard let idx = viewModel.sections.firstIndex(where: { $0.id == section.id }) else { return }
        let nextIndex = idx + 2
        let targetId = nextIndex < viewModel.sections.count ? viewModel.sections[nextIndex].id : nil
        await viewModel.reorderSection(section.id, before: targetId)
    }

    @ViewBuilder
    private func unassignedSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.shots(in: nil)) { shot in
                shotCardView(shot: shot, sceneId: nil)
            }
            addRow(sceneId: nil)
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
        .padding(.horizontal, 16)
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first else { return }
            Task { await viewModel.moveShot(dragged, toScene: scene.id) }
        }
    }

    /// Image + header + description grouped as one tappable unit — tap
    /// anywhere on it to edit the scene. Reordering is a plain up/down menu
    /// (see sceneHeader), not drag & drop: `.draggable()`/`.dropDestination()`
    /// on scene tiles was tried twice and both times made the whole
    /// ScrollView hang/lock up while scrolling — not a MapKit issue (that was
    /// ruled out separately), something about this drag API combination
    /// itself inside a ScrollView/LazyVStack on this SDK. Shots keep their
    /// own `.draggable()` below since that predates the scene-drag attempt
    /// and was never implicated.
    @ViewBuilder
    private func sceneTile(scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageUrl = scene.imageUrl {
                AsyncShotThumbnail(path: imageUrl, size: nil, lockAspectRatio: true)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            sceneHeader(scene: scene)
            if let scheduledAt = scene.scheduledAt {
                // Live-ticking, not just recomputed on the next incidental
                // re-render — TimelineView keeps this in sync with the wall
                // clock on its own (every 30s is plenty for a color that
                // shifts over tens of minutes).
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(scheduledAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(urgencyColor(for: scheduledAt, now: context.date))
                        .animation(.easeInOut(duration: 0.4), value: urgencyColor(for: scheduledAt, now: context.date))
                }
            }
            if let scheduledAt = scene.scheduledAt, let durationMinutes = scene.durationMinutes {
                // Separate 1s-ticking timeline (vs. the 30s one above) — this
                // one drives an actual mm:ss countdown while the scene is
                // running, so it needs second-level precision.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let end = scheduledAt.addingTimeInterval(TimeInterval(durationMinutes) * 60)
                    if context.date >= scheduledAt && context.date < end {
                        LiveSceneBadge(remaining: end.timeIntervalSince(context.date))
                    }
                }
            }
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
    }

    @ViewBuilder
    private func sceneHeader(scene: Scene) -> some View {
        HStack(spacing: 8) {
            reorderMenu(scene: scene)
            Text(scene.displayNumber)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(hex: scene.color))
                .clipShape(Capsule())
            Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                .font(.headline)
            Text("\(viewModel.shots(in: scene).count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !viewModel.sections.isEmpty {
                sceneSectionMenu(scene: scene)
            }
            sceneAssigneeMenu(scene: scene)
            imKastenButton(scene: scene)
        }
    }

    /// Only shown once the project actually has sections — no point
    /// cluttering the header with an empty-state menu.
    @ViewBuilder
    private func sceneSectionMenu(scene: Scene) -> some View {
        Menu {
            if scene.sectionId != nil {
                Button {
                    Task { await viewModel.assignSceneToSection(scene, sectionId: nil) }
                } label: {
                    Label("Ohne Abschnitt", systemImage: "xmark.circle")
                }
            }
            ForEach(viewModel.sections) { section in
                Button {
                    Task { await viewModel.assignSceneToSection(scene, sectionId: section.id) }
                } label: {
                    Text(section.name)
                }
            }
        } label: {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
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

    /// Plain up/down reordering — see sceneTile's doc comment for why this
    /// is a menu and not drag & drop.
    @ViewBuilder
    private func reorderMenu(scene: Scene) -> some View {
        Menu {
            Button {
                Task { await moveSceneUp(scene) }
            } label: {
                Label("Nach oben", systemImage: "arrow.up")
            }
            Button {
                Task { await moveSceneDown(scene) }
            } label: {
                Label("Nach unten", systemImage: "arrow.down")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private func moveSceneUp(_ scene: Scene) async {
        guard let idx = viewModel.scenes.firstIndex(where: { $0.id == scene.id }), idx > 0 else { return }
        let target = viewModel.scenes[idx - 1]
        await viewModel.reorderScene(scene.id, before: target.id)
    }

    private func moveSceneDown(_ scene: Scene) async {
        guard let idx = viewModel.scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        let nextIndex = idx + 2  // "insert before" semantics — see ShotListViewModel.reorderScene
        let targetId = nextIndex < viewModel.scenes.count ? viewModel.scenes[nextIndex].id : nil
        await viewModel.reorderScene(scene.id, before: targetId)
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
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: scene.completed)
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

    /// Grey more than 1h out, fading through yellow at the 30min mark, red
    /// once the scheduled time has passed — a continuous fade, not a hard
    /// 3-way switch, so it visibly "warms up" as the deadline approaches.
    private func urgencyColor(for scheduledAt: Date, now: Date) -> Color {
        let remaining = scheduledAt.timeIntervalSince(now)
        if remaining <= 0 {
            return .red
        } else if remaining <= 1800 {
            return .yellow.interpolated(to: .red, fraction: 1 - (remaining / 1800))
        } else if remaining <= 3600 {
            return Color(.secondaryLabel).interpolated(to: .yellow, fraction: 1 - ((remaining - 1800) / 1800))
        } else {
            return Color(.secondaryLabel)
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

/// Shown on a scene's tile while `now` falls inside [scheduledAt,
/// scheduledAt + durationMinutes) — a gently pulsing dot + live mm:ss
/// countdown so it's obvious at a glance which scene is currently rolling.
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
        .background(Color.red)
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
