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
    @State private var path = NavigationPath()
    @State private var editingProject: Project?
    @State private var editingFolder: ProjectFolder?
    @State private var showingNotifications = false

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

    // Broken into grid + toolbar + sheets as separate pieces (rather than
    // one long chained expression) after Xcode's type checker gave up on
    // this view entirely ("unable to type-check in reasonable time") — the
    // combination of nested conditionals in .toolbar plus five .sheet
    // modifiers in a single chain was too much for it to solve at once.
    private var gridScreen: some View {
        gridContent
            .toolbar { toolbarContent }
            .task { await viewModel.load() }
            .task { if folderId == nil { await viewModel.loadNotifications() } }
            .refreshable {
                await viewModel.load()
                if folderId == nil { await viewModel.loadNotifications() }
            }
            .modifier(GridSheets(
                viewModel: viewModel, path: $path,
                creatingProject: $creatingProject, creatingFolder: $creatingFolder,
                editingProject: $editingProject, editingFolder: $editingFolder,
                showingNotifications: $showingNotifications
            ))
    }

    private var gridContent: some View {
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
        .overlay(alignment: .bottomTrailing) {
            addButton
        }
    }

    /// Same floating-FAB pattern as ShotListView's addSceneButton — the
    /// toolbar "+" up top still works too, this is just a second, easier-to-
    /// reach spot for the same action (thumb-friendly on a big grid).
    @ViewBuilder
    private var addButton: some View {
        Group {
            if folderId == nil {
                Menu {
                    Button {
                        creatingProject = true
                    } label: {
                        Label("Neues Projekt", systemImage: "film.stack")
                    }
                    Button {
                        creatingFolder = true
                    } label: {
                        Label("Neuer Ordner", systemImage: "folder.badge.plus")
                    }
                } label: {
                    fabIcon
                }
            } else {
                Button {
                    creatingProject = true
                } label: {
                    fabIcon
                }
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    private var fabIcon: some View {
        Image(systemName: "plus")
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(Circle().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if folderId == nil {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showingNotifications = true } label: {
                    // Toolbar items clip content to the label's own natural
                    // size — an .offset() badge meant to overflow past the
                    // bell's edge gets cut off there instead of floating
                    // above it (Lino, 2026-07-10: "die Zahl... sieht so aus
                    // als würd der rote Kreis mit der Zahl im Glockekreis
                    // sein und nicht darüber"). Fix: give the ZStack an
                    // explicit frame bigger than the bell glyph itself, so
                    // the badge has real layout room inside it instead of
                    // relying on visual overflow the toolbar then clips.
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .frame(width: 22, height: 22)
                        if !viewModel.notifications.isEmpty {
                            Text(viewModel.notifications.count > 99 ? "99+" : "\(viewModel.notifications.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.red)
                                .clipShape(Capsule())
                                .offset(x: 6, y: -4)
                        }
                    }
                    .frame(width: 30, height: 30)
                }
            }
        }
    }

    // MARK: - Tiles

    @ViewBuilder
    private func projectTile(_ project: Project) -> some View {
        NavigationLink(value: project) {
            tileBody(
                title: project.name,
                subtitle: "Wird gelöscht in \(project.daysUntilDeletion) Tagen",
                color: project.color,
                thumbnailPath: project.thumbnailUrl,
                fallbackIcon: "film.stack",
                emoji: project.emoji
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
                subtitle: folder.projectCount == 1 ? "1 Projekt" : "\(folder.projectCount) Projekte",
                color: folder.color,
                thumbnailPath: folder.backgroundImageURL,
                fallbackIcon: "folder.fill",
                emoji: folder.emoji,
                thumbnailFocusPoint: folder.backgroundImageFocusPoint
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editingFolder = folder } label: {
                Label("Bearbeiten", systemImage: "pencil")
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

    private func tileBody(title: String, subtitle: String?, color: String, thumbnailPath: String?, fallbackIcon: String, emoji: String? = nil, thumbnailFocusPoint: UnitPoint? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Color.clear + .aspectRatio + .overlay, not relying on the
            // ZStack sizing itself from its content — the same bulletproof
            // pattern AsyncShotThumbnail's lockAspectRatio mode already
            // uses, here fixed at 4:3 regardless of whether there's a real
            // photo, an emoji, or a fallback SF Symbol inside. Guarantees
            // every tile (project or folder, at root or inside a folder —
            // same tileBody either way) is exactly the same size.
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    ZStack {
                        // Near-solid fill, not a translucent tint — at the old 0.25
                        // opacity, this app's pastel palette all washed out to roughly
                        // the same pale shade against the system background, so picking
                        // a different color in the edit sheet looked like it did
                        // nothing. Solid fill makes every palette color unmistakably
                        // distinct (matters most for folder tiles, which never have a
                        // thumbnail to look at instead).
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(hex: color).opacity(0.9))
                        if let thumbnailPath {
                            AsyncShotThumbnail(path: thumbnailPath, size: nil, lockAspectRatio: false, focusPoint: thumbnailFocusPoint)
                            // Diagonal light-reflection streak — the classic
                            // "light catching glass" cue, same treatment as
                            // the web app's tiles (TileShell) for parity, so
                            // an uploaded photo reads as sitting behind a
                            // glass pane rather than a flat, plain picture.
                            GeometryReader { geo in
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.3), .clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                                .frame(width: geo.size.width * 0.55)
                                .rotationEffect(.degrees(-20))
                                .offset(x: -geo.size.width * 0.35)
                                .blur(radius: 6)
                            }
                            .allowsHitTesting(false)
                        } else if let emoji, !emoji.isEmpty {
                            Text(emoji)
                                .font(.system(size: 48))
                        } else {
                            Image(systemName: fallbackIcon)
                                .font(.system(size: 32))
                                .foregroundStyle(.white)
                        }
                        // Subtle glossy light sweep from the top-left, like
                        // an app icon — a plain flat-color tile read as a
                        // placeholder rather than a finished surface.
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

}

/// All five .sheet(...) modifiers for the grid screen, split out into their
/// own ViewModifier — see gridScreen's comment for why (Xcode's type checker
/// couldn't solve the combined chain).
private struct GridSheets: ViewModifier {
    @ObservedObject var viewModel: ProjectListViewModel
    @Binding var path: NavigationPath
    @Binding var creatingProject: Bool
    @Binding var creatingFolder: Bool
    @Binding var editingProject: Project?
    @Binding var editingFolder: ProjectFolder?
    @Binding var showingNotifications: Bool

    @State private var newItemName = ""
    @FocusState private var newNameFocused: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $creatingProject) {
                nameSheet(title: "Neues Projekt") { name in
                    if let project = await viewModel.create(name: name) { path.append(project) }
                }
            }
            .sheet(isPresented: $creatingFolder) {
                FolderEditSheet(existing: nil) { name, color, emoji, image, _ in
                    await viewModel.createFolder(name: name, color: color, emoji: emoji, image: image)
                }
            }
            .sheet(item: $editingProject) { project in
                ProjectEditSheet(project: project) { name, color, emoji in
                    await viewModel.update(project, name: name, color: color, emoji: emoji)
                }
            }
            .sheet(item: $editingFolder) { folder in
                FolderEditSheet(existing: folder) { name, color, emoji, image, clearImage in
                    await viewModel.updateFolder(folder, name: name, color: color, emoji: emoji, image: image, clearImage: clearImage)
                }
            }
            .sheet(isPresented: $showingNotifications) {
                NotificationsSheet(viewModel: viewModel) { project in
                    path.append(project)
                }
            }
    }

    @ViewBuilder
    private func nameSheet(title: String, onSave: @escaping (String) async -> Void) -> some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $newItemName)
                        .focused($newNameFocused)
                        .onAppear {
                            newItemName = ""
                            newNameFocused = true
                        }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { creatingProject = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        let trimmed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            await onSave(trimmed)
                            creatingProject = false
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
