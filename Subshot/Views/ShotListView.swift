import SwiftUI

struct ShotListView: View {
    @StateObject private var viewModel: ShotListViewModel
    let projectName: String

    @State private var addingToScene: String??  // nil = not adding; .some(nil) = adding to "no scene"; .some(id) = adding to that scene
    @State private var newShotText = ""
    @State private var selectedShot: Shot?
    @State private var showingTeamSheet = false
    @FocusState private var newRowFocused: Bool
    private let projectId: String

    init(projectId: String, projectName: String) {
        self.projectId = projectId
        _viewModel = StateObject(wrappedValue: ShotListViewModel(projectId: projectId))
        self.projectName = projectName
    }

    var body: some View {
        List {
            // Shots with no scene assigned always show first, un-sectioned —
            // most projects start here before any scenes exist at all.
            shotSection(scene: nil)

            ForEach(viewModel.scenes, id: \.id) { scene in
                shotSection(scene: scene)
            }

            Button {
                Task { await viewModel.createScene(name: nil, color: randomSceneColor()) }
            } label: {
                Label("Szene hinzufügen", systemImage: "plus.rectangle.on.rectangle")
            }

            // Tap-empty-area-to-add, same affordance as ProjectListView.
            Color.clear
                .frame(height: 80)
                .contentShape(Rectangle())
                .onTapGesture { startAdding(sceneId: nil) }
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
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
        .safeAreaInset(edge: .bottom) {
            if let pending = viewModel.pendingUndoShot {
                undoToast(for: pending)
            }
        }
    }

    @ViewBuilder
    private func shotSection(scene: Scene?) -> some View {
        Section {
            ForEach(viewModel.shots(in: scene)) { shot in
                ShotRow(shot: shot)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedShot = shot }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await viewModel.toggleDone(shot) }
                        } label: {
                            Label("Erledigt", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.deleteWithUndo(shot)
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
            }

            if addingToScene == .some(scene?.id) {
                TextField("Neue Einstellung", text: $newShotText)
                    .focused($newRowFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await commitNewShot(sceneId: scene?.id) } }
            }
        } header: {
            if let scene {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: scene.color))
                        .frame(width: 4, height: 14)
                    Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                }
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

    private func randomSceneColor() -> String {
        // Palette check-validated pastel set (see dataviz skill notes on this
        // project) — reused from the SUBLI speaker-diarization palette rather
        // than picking arbitrary colors that might collide under CVD.
        let palette = ["#3875bd", "#0f7e55", "#4e4295", "#d1504f", "#b9507b", "#a64c22"]
        return palette.randomElement() ?? "#3875bd"
    }
}

private struct ShotRow: View {
    let shot: Shot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: shot.status == .done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(shot.status == .done ? .green : .secondary)
                .font(.title3)

            if let priority = shot.priority {
                Circle()
                    .fill(priorityColor(priority))
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(shot.description?.isEmpty == false ? shot.description! : "Ohne Beschreibung")
                    .strikethrough(shot.status == .done)
                    .foregroundStyle(shot.status == .done ? .secondary : .primary)
                HStack(spacing: 6) {
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

            Spacer()

            if let imageUrl = shot.imageUrl {
                AsyncShotThumbnail(path: imageUrl)
            }
        }
        .padding(.vertical, 4)
    }

    private func priorityColor(_ priority: ShotPriority) -> Color {
        switch priority {
        case .must: return .red
        case .should: return .orange
        case .optional: return .gray
        }
    }
}
