import SwiftUI

struct ShotListView: View {
    @StateObject private var viewModel: ShotListViewModel
    let projectName: String

    @State private var addingToScene: String??  // nil = not adding; .some(nil) = "no scene"; .some(id) = that scene
    @State private var newShotText = ""
    @State private var selectedShot: Shot?
    @State private var showingTeamSheet = false
    @State private var editingScene: Scene??      // nil = sheet closed; .some(nil) = creating; .some(scene) = renaming
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
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                SceneEditSheet(existing: existing) { name, color in
                    if let existing {
                        await viewModel.renameScene(existing, name: name, color: color)
                    } else {
                        await viewModel.createScene(name: name.isEmpty ? "Unbenannte Szene" : name, color: color)
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
            guard let dragged = ids.first else { return }
            Task { await viewModel.moveShot(dragged, toScene: nil) }
        }
    }

    @ViewBuilder
    private func sceneCard(scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sceneHeader(scene: scene)
            ForEach(viewModel.shots(in: scene)) { shot in
                shotCardView(shot: shot, sceneId: scene.id)
            }
            addRow(sceneId: scene.id)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first else { return }
            Task { await viewModel.moveShot(dragged, toScene: scene.id) }
        }
    }

    @ViewBuilder
    private func sceneHeader(scene: Scene) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: scene.color))
                    .frame(width: 14, height: 14)
                Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                    .font(.headline)
                Text("\(viewModel.shots(in: scene).count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { editingScene = .some(scene) }

            Spacer()

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
                    .padding(.leading, 4)
            }
        }
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

    private func moveSceneUp(_ scene: Scene) async {
        guard let idx = viewModel.scenes.firstIndex(where: { $0.id == scene.id }), idx > 0 else { return }
        let target = viewModel.scenes[idx - 1]
        await viewModel.reorderScene(scene.id, before: target.id)
    }

    private func moveSceneDown(_ scene: Scene) async {
        guard let idx = viewModel.scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        let nextIndex = idx + 2  // "insert before" semantics — see reorderScene
        let targetId = nextIndex < viewModel.scenes.count ? viewModel.scenes[nextIndex].id : nil
        await viewModel.reorderScene(scene.id, before: targetId)
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
