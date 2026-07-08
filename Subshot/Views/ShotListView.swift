import SwiftUI

struct ShotListView: View {
    @StateObject private var viewModel: ShotListViewModel
    let projectName: String

    @State private var addingToScene: String??  // nil = not adding; .some(nil) = "no scene"; .some(id) = that scene
    @State private var newShotText = ""
    @State private var selectedShot: Shot?
    @State private var showingTeamSheet = false
    @State private var editingScene: Scene??      // nil = sheet closed; .some(nil) = creating; .some(scene) = renaming
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
                ProjectInfoBox(viewModel: viewModel, projectId: projectId)

                unassignedSection()

                ForEach(viewModel.scenes) { scene in
                    sceneCard(scene: scene)
                }

                Button {
                    editingScene = .some(nil)
                } label: {
                    Label("Szene hinzufügen", systemImage: "plus.rectangle.on.rectangle")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    guard let dragged = ids.first, viewModel.scenes.contains(where: { $0.id == dragged }) else { return }
                    Task { await viewModel.reorderScene(dragged, before: nil) }
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
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
                SceneEditSheet(existing: existing, viewModel: viewModel) { name, color, description, dialogue, focalLength, scheduledAt in
                    if let existing {
                        await viewModel.renameScene(existing, name: name, color: color, description: description, dialogue: dialogue, focalLengthMm: focalLength, scheduledAt: scheduledAt)
                    } else {
                        await viewModel.createScene(
                            name: name.isEmpty ? "Unbenannte Szene" : name, color: color,
                            description: description.isEmpty ? nil : description,
                            dialogue: dialogue.isEmpty ? nil : dialogue,
                            focalLengthMm: focalLength,
                            scheduledAt: scheduledAt
                        )
                    }
                } onImagePicked: { image in
                    if let existing {
                        await viewModel.uploadSceneImage(existing, image: image)
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

    // MARK: - Sections

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
            guard let dragged = ids.first, !viewModel.scenes.contains(where: { $0.id == dragged }) else { return }
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
            guard let dragged = ids.first, dragged != scene.id else { return }
            Task {
                if viewModel.scenes.contains(where: { $0.id == dragged }) {
                    await viewModel.reorderScene(dragged, before: scene.id)
                } else {
                    await viewModel.moveShot(dragged, toScene: scene.id)
                }
            }
        }
    }

    /// Image + header + description grouped as one tappable unit — tap
    /// anywhere on it to edit the scene. Dragging to reorder lives on the
    /// dedicated handle in the header, NOT here: `.draggable()` on a view
    /// this big inside a ScrollView/LazyVStack fights the ScrollView's own
    /// pan gesture for touches and can make the whole list stop scrolling
    /// (confirmed — a `List` doesn't have this problem since it has native
    /// drag/scroll coexistence, but a plain ScrollView does).
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
                Label(scheduledAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let description = scene.description, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let dialogue = scene.dialogue, !dialogue.isEmpty {
                Label(dialogue, systemImage: "quote.bubble")
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { editingScene = .some(scene) }
    }

    @ViewBuilder
    private func sceneHeader(scene: Scene) -> some View {
        HStack(spacing: 8) {
            dragHandle(scene: scene)
            Circle()
                .fill(Color(hex: scene.color))
                .frame(width: 14, height: 14)
            Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                .font(.headline)
            Text("\(viewModel.shots(in: scene).count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            imKastenButton(scene: scene)
        }
    }

    /// Generous (44x44pt min, per HIG touch-target guidance) dedicated drag
    /// source — press and hold anywhere on this specific icon, then move to
    /// reorder. Scoped small on purpose (see sceneTile's doc comment).
    @ViewBuilder
    private func dragHandle(scene: Scene) -> some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .draggable(scene.id)
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
