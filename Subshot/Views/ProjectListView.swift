import SwiftUI
import ClerkKit

/// Root project screen AND every folder's contents use this same view —
/// `folderId`/`folderName` nil means the root (all top-level projects +
/// folder tiles), non-nil means we're inside a folder (its projects only,
/// no nested folders). Grid of tiles throughout: a project tile shows a
/// thumbnail pulled from one of its scenes, a folder tile looks identical
/// (no folder chrome) so the two read as one consistent tile system.
struct ProjectListView: View {
    let folderId: String?
    let folderName: String?

    @StateObject private var viewModel: ProjectListViewModel
    @Environment(Clerk.self) private var clerk
    @State private var creatingProject = false
    @State private var creatingFolder = false
    @State private var newItemName = ""
    @State private var path = NavigationPath()
    @State private var editingProject: Project?
    @State private var editingFolder: ProjectFolder?
    @State private var showingNotifications = false
    @FocusState private var newNameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    init(folderId: String? = nil, folderName: String? = nil) {
        self.folderId = folderId
        self.folderName = folderName
        _viewModel = StateObject(wrappedValue: ProjectListViewModel(folderId: folderId))
    }

    var body: some View {
        // Only the root level owns a NavigationStack — a folder pushes onto
        // it the same way ShotListView already does, so drilling into a
        // folder and then into one of its projects is one continuous stack.
        if folderId == nil {
            NavigationStack(path: $path) {
                gridScreen
                    .navigationDestination(for: Project.self) { project in
                        ShotListView(projectId: project.id, projectName: project.name)
                    }
                    .navigationDestination(for: ProjectFolder.self) { folder in
                        ProjectListView(folderId: folder.id, folderName: folder.name)
                    }
            }
        } else {
            gridScreen
        }
    }

    private var gridScreen: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                if folderId == nil {
                    ForEach(viewModel.folders) { folder in
                        folderTile(folder)
                    }
                }
                ForEach(viewModel.projects) { project in
                    projectTile(project)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(folderName ?? "Subshot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folderId == nil {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showingNotifications = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell")
                            if !viewModel.notifications.isEmpty {
                                Text("\(viewModel.notifications.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Color.red)
                                    .clipShape(Circle())
                                    .offset(x: 9, y: -9)
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if folderId == nil {
                    Menu {
                        Button {
                            newItemName = ""
                            creatingProject = true
                        } label: {
                            Label("Neues Projekt", systemImage: "film.stack")
                        }
                        Button {
                            newItemName = ""
                            creatingFolder = true
                        } label: {
                            Label("Neuer Ordner", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                } else {
                    Button {
                        newItemName = ""
                        creatingProject = true
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.projects.isEmpty && viewModel.folders.isEmpty {
                ProgressView()
            } else if viewModel.projects.isEmpty && viewModel.folders.isEmpty {
                ContentUnavailableView(
                    "Noch keine Projekte",
                    systemImage: "film.stack",
                    description: Text("Tippe auf + um dein erstes Projekt anzulegen.")
                )
            }
        }
        .task { await viewModel.load() }
        .task { if folderId == nil { await viewModel.loadNotifications() } }
        .refreshable {
            await viewModel.load()
            if folderId == nil { await viewModel.loadNotifications() }
        }
        .sheet(isPresented: $creatingProject) { nameSheet(title: "Neues Projekt") { name in
            if let project = await viewModel.create(name: name) { path.append(project) }
        } }
        .sheet(isPresented: $creatingFolder) { nameSheet(title: "Neuer Ordner") { name in
            await viewModel.createFolder(name: name)
        } }
        .sheet(item: $editingProject) { project in
            ProjectEditSheet(project: project) { name, color in
                await viewModel.update(project, name: name, color: color)
            }
        }
        .sheet(item: $editingFolder) { folder in
            nameSheet(title: "Ordner umbenennen", initialValue: folder.name) { name in
                await viewModel.renameFolder(folder, name: name)
            }
        }
        .sheet(isPresented: $showingNotifications) {
            NotificationsSheet(viewModel: viewModel) { project in
                path.append(project)
            }
        }
    }

    // MARK: - Tiles

    @ViewBuilder
    private func projectTile(_ project: Project) -> some View {
        NavigationLink(value: project) {
            tileBody(
                title: project.name,
                subtitle: project.lastOpenedAt.formatted(.relative(presentation: .named)),
                color: project.color,
                thumbnailPath: project.thumbnailUrl,
                fallbackIcon: "film.stack"
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editingProject = project } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await viewModel.delete(project) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
        // Long-press-and-hold picks the tile up (standard iOS drag haptic) —
        // dropping it on a folder tile files it there.
        .draggable(project.id)
    }

    @ViewBuilder
    private func folderTile(_ folder: ProjectFolder) -> some View {
        NavigationLink(value: folder) {
            tileBody(
                title: folder.name,
                subtitle: nil,
                color: folder.color,
                thumbnailPath: nil,
                fallbackIcon: "folder.fill"
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editingFolder = folder } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await viewModel.deleteFolder(folder) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let projectId = ids.first, let project = viewModel.projects.first(where: { $0.id == projectId }) else { return }
            Task { await viewModel.moveProject(project, toFolder: folder.id) }
        }
    }

    private func tileBody(title: String, subtitle: String?, color: String, thumbnailPath: String?, fallbackIcon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(hex: color).opacity(0.25))
                if let thumbnailPath {
                    AsyncShotThumbnail(path: thumbnailPath, size: nil, lockAspectRatio: false)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Image(systemName: fallbackIcon)
                        .font(.system(size: 32))
                        .foregroundStyle(Color(hex: color))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Creation sheet

    @ViewBuilder
    private func nameSheet(title: String, initialValue: String = "", onSave: @escaping (String) async -> Void) -> some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $newItemName)
                        .focused($newNameFocused)
                        .onAppear {
                            newItemName = initialValue
                            newNameFocused = true
                        }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismissSheets() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        let trimmed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            await onSave(trimmed)
                            dismissSheets()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func dismissSheets() {
        creatingProject = false
        creatingFolder = false
        editingFolder = nil
    }
}
