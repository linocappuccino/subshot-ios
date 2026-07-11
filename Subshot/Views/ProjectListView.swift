import SwiftUI
import UIKit
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
    /// Landing indicator while dragging a project tile onto another project
    /// tile to reorder — same idea as ShotListView's dropTargetSceneId.
    @State private var dropTargetProjectId: String?
    /// Blue outline on a folder tile being dragged over — shown for BOTH a
    /// project being filed into it AND another folder being reordered onto
    /// it (Lino, 2026-07-11: "wenn man ein Projekt oder Ordner über einen
    /// anderen Ordner legt... soll der Ziel-Ordner blau umrandet werden").
    @State private var dropTargetFolderId: String?

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
                    // Three things were wrong, found only once Lino sent an
                    // actual screenshot (2026-07-10 — should have asked for
                    // one immediately instead of guessing three times):
                    // 1. The circular dark background around the bell is
                    //    SYSTEM-drawn toolbar-button chrome, not anything in
                    //    this file — badge math positioned against the bare
                    //    SF Symbol's small glyph size landed ON the glyph,
                    //    nowhere near that larger circle's actual edge.
                    //    Fixed by giving the glyph an explicit 30x30 frame
                    //    to position the badge against a known, stable size.
                    // 2. .offset() doesn't change what the parent counts as
                    //    this view's layout bounds, so a toolbar item (which
                    //    clips to that unchanged size) cut the badge off.
                    //    .alignmentGuide does change the layout contribution,
                    //    so the icon's effective bounds actually grow to
                    //    include the badge instead of it being clipped.
                    // 3. The badge looked translucent (bell glyph visible
                    //    through the red circle) — toolbar button labels get
                    //    a system vibrancy/material effect applied to their
                    //    whole content, which bleeds through plain solid
                    //    colors. .compositingGroup() flattens the badge into
                    //    one opaque layer BEFORE that effect applies.
                    //
                    // 4. Still saw some transparency after (3), AND again
                    //    after a second, wider .compositingGroup() around
                    //    the whole bell+badge combo (2026-07-11, "KEINE
                    //    TRANSPARENTS BEI DEM ZAHLEN ICON", asked twice).
                    //    Giving up on fighting the toolbar's own vibrancy/
                    //    template rendering from inside SwiftUI's view tree
                    //    — whatever exactly is causing it, it survived two
                    //    different compositing fixes, so it's evidently not
                    //    fully addressable with SwiftUI layer-flattening
                    //    alone. NotificationBadgeView below is a raw UIKit
                    //    UILabel bridged in via UIViewRepresentable instead
                    //    — a genuine UIView's own compositing is NOT subject
                    //    to SwiftUI's toolbar-label vibrancy pipeline at
                    //    all, which sidesteps the whole question rather
                    //    than trying to counteract it a third time.
                    Image(systemName: "bell")
                        .frame(width: 30, height: 30)
                        .overlay(alignment: .topTrailing) {
                            if !viewModel.notifications.isEmpty {
                                NotificationBadgeView(count: viewModel.notifications.count)
                                    .frame(width: 18, height: 18)
                                    .alignmentGuide(.top) { d in d.height * 0.7 }
                                    .alignmentGuide(.trailing) { d in d.width * 0.3 }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Tiles

    @ViewBuilder
    private func projectTile(_ project: Project) -> some View {
        VStack(spacing: 4) {
            // Landing indicator — same idea as ShotListView's scene tiles
            // ("die Projekte und Ordner müssen genau so verschoben werden
            // können wie jede Kachel in der Szenenübersicht", 2026-07-11).
            if dropTargetProjectId == project.id {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .transition(.opacity)
            }
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
        }
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
        // dropping it on a folder tile files it there, dropping it on
        // another project tile reorders. "project:"-prefixed so folderTile's
        // dropDestination below can tell a project drop apart from a folder
        // being dragged onto it (reorder), same prefix convention
        // ShotListView already uses for "scene:"/"section:".
        .draggable("project:\(project.id)")
        .dropDestination(for: String.self) { ids, _ in
            guard let raw = ids.first, raw.hasPrefix("project:") else { return false }
            let draggedId = String(raw.dropFirst("project:".count))
            guard draggedId != project.id else { return false }
            Task { await viewModel.reorderProject(draggedId, before: project.id) }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                dropTargetProjectId = targeted ? project.id : (dropTargetProjectId == project.id ? nil : dropTargetProjectId)
            }
        }
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
        .overlay {
            if dropTargetFolderId == folder.id {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        // Also draggable now (2026-07-11) — folders could be dropped ONTO
        // but never picked up themselves, so they could never be reordered
        // among each other, only ever receive a filed-in project.
        .draggable("folder:\(folder.id)")
        .dropDestination(for: String.self) { ids, _ in
            guard let raw = ids.first else { return false }
            if raw.hasPrefix("project:") {
                let projectId = String(raw.dropFirst("project:".count))
                guard let project = viewModel.projects.first(where: { $0.id == projectId }) else { return false }
                Task { await viewModel.moveProject(project, toFolder: folder.id) }
                return true
            } else if raw.hasPrefix("folder:") {
                let draggedId = String(raw.dropFirst("folder:".count))
                guard draggedId != folder.id else { return false }
                Task { await viewModel.reorderFolder(draggedId, before: folder.id) }
                return true
            }
            return false
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                dropTargetFolderId = targeted ? folder.id : (dropTargetFolderId == folder.id ? nil : dropTargetFolderId)
            }
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
                        // An image always wins if there is one — the picked
                        // color no longer fills the background in that case
                        // (2026-07-11: "die Farben... färben dann den Rahmen
                        // der Kachel, aber nicht mehr den Hintergrund, nur
                        // wenn ein Bild vorhanden ist"). Plain neutral fill
                        // here is just a placeholder behind the photo (covers
                        // any transparent/unloaded edges), not a color choice.
                        // Without an image, the color fill is unchanged from
                        // before (solid, not a translucent tint — see prior
                        // comment on why: pastel palette washed out otherwise).
                        RoundedRectangle(cornerRadius: 14)
                            .fill(thumbnailPath != nil ? AnyShapeStyle(Color(.tertiarySystemFill)) : AnyShapeStyle(Color(hex: color).opacity(0.9)))
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
                            // Emoji still shows even with an image now — laid
                            // over the photo as a small corner badge instead
                            // of the two being mutually exclusive as before
                            // ("ein Emoji kann dann noch über das Bild gelegt
                            // werden").
                            if let emoji, !emoji.isEmpty {
                                VStack {
                                    Spacer()
                                    HStack {
                                        Spacer()
                                        Text(emoji)
                                            .font(.system(size: 22))
                                            .padding(6)
                                            .background(Circle().fill(.black.opacity(0.35)))
                                            .padding(6)
                                    }
                                }
                            }
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
                    // The frame is where the picked color shows once there's
                    // an image (see the background-fill comment above) —
                    // without an image, the border stays the previous plain
                    // subtle white (the fill itself already carries the
                    // color in that case, a colored border too would be
                    // redundant).
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(thumbnailPath != nil ? Color(hex: color) : Color.white.opacity(0.15), lineWidth: thumbnailPath != nil ? 2.5 : 1)
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

/// Raw UIKit badge (see toolbarContent's own comment on why) — after the
/// first UILabel-based version STILL rendered wrong (2026-07-11, this time
/// as a plain white circle instead of red — a different symptom than the
/// earlier transparency reports, which points at the SIZE/bounds SwiftUI
/// hands this view being unreliable rather than any color-resolution
/// issue: a mismatched size would make cornerRadius-based circular
/// clipping land wrong, and/or leave an unclipped rectangular remainder
/// showing whatever's behind it, i.e. plausibly a white hosting-view
/// background). This version removes every source of that ambiguity:
/// - A dedicated BadgeShapeView subclass overrides intrinsicContentSize to
///   always report exactly 18x18, so UIKit's own layout has no reason to
///   size this any other way regardless of what SwiftUI's bridging layer
///   does with the .frame() modifier.
/// - Draws the circle itself in draw(rect:) with explicit CoreGraphics
///   fill using bounds read AT DRAW TIME (always current/correct, unlike
///   a cornerRadius set once in makeUIView before layout has necessarily
///   run) instead of relying on layer.cornerRadius + masksToBounds.
/// - A literal, non-dynamic RGB red (not .systemRed / UIColor.red, both of
///   which are dynamic/adaptive colors) — eliminates any chance of a
///   color asset or dark/light-mode resolution issue, however unlikely,
///   given two previous attempts using dynamic-adjacent styling already
///   failed for unclear reasons.
private struct NotificationBadgeView: UIViewRepresentable {
    let count: Int

    final class BadgeShapeView: UIView {
        var text: String = "" {
            didSet { setNeedsDisplay() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        override var intrinsicContentSize: CGSize { CGSize(width: 18, height: 18) }

        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            let solidRed = CGColor(red: 1, green: 0.0, blue: 0.0, alpha: 1)
            ctx.setFillColor(solidRed)
            ctx.fillEllipse(in: bounds)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: bounds.midX - textSize.width / 2,
                y: bounds.midY - textSize.height / 2,
                width: textSize.width, height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    func makeUIView(context: Context) -> BadgeShapeView {
        BadgeShapeView()
    }

    func updateUIView(_ view: BadgeShapeView, context: Context) {
        view.text = count > 99 ? "99+" : "\(count)"
    }
}
