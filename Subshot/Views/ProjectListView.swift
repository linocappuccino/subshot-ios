import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ClerkKit

/// Which of a tile's 4 edges a drop point is nearest to — same nearest-
/// edge-to-cursor rule as the web app's tileCollisionDetection (distances
/// = {left: relX, right: 1-relX, top: relY, bottom: 1-relY}, pick the
/// minimum). File-scope (not nested in ProjectListView) so TileDropDelegate
/// below can share it without needing a ProjectListView instance.
fileprivate enum TileEdge {
    case left, right, top, bottom
}

fileprivate func nearestEdge(of point: CGPoint, in size: CGSize) -> TileEdge {
    guard size.width > 0, size.height > 0 else { return .top }
    let relX = point.x / size.width
    let relY = point.y / size.height
    let distances: [(TileEdge, CGFloat)] = [
        (.left, relX), (.right, 1 - relX), (.top, relY), (.bottom, 1 - relY)
    ]
    return distances.min { $0.1 < $1.1 }!.0
}

fileprivate func tileEdgeAlignment(_ edge: TileEdge) -> Alignment {
    switch edge {
    case .left: return .leading
    case .right: return .trailing
    case .top: return .top
    case .bottom: return .bottom
    }
}

/// Drives the live directional drop indicator for project/folder grid tiles
/// (2026-07-15, Lino: "hat man immer noch keinen indikator um ein objekt zu
/// verschieben und irgendwo zu platzieren"). SwiftUI's Transferable-based
/// .dropDestination only ever reported a plain Bool "isTargeted" — no
/// continuous position while hovering, only a CGPoint at the final drop
/// (see the old tileSizes doc comment, still true of that API). The
/// classic UIKit-backed DropDelegate protocol (.onDrop(of:delegate:))
/// receives the exact same drag session .draggable() starts — same
/// underlying NSItemProvider/UIDragInteraction machinery — but its
/// dropUpdated(info:) fires continuously with a live location, which is
/// what actually makes a moving indicator possible here. Shared by both
/// projectTile and folderTile below; which action a drop performs
/// (reorder vs. file-into-folder) is still resolved from the dragged
/// payload's "project:"/"folder:" prefix exactly as before.
fileprivate struct TileDropDelegate: DropDelegate {
    let tileSize: CGSize
    let onHover: (TileEdge?) -> Void
    let onDrop: (_ payload: String, _ edge: TileEdge) -> Void

    func dropEntered(info: DropInfo) {
        onHover(nearestEdge(of: info.location, in: tileSize))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(nearestEdge(of: info.location, in: tileSize))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onHover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let edge = nearestEdge(of: info.location, in: tileSize)
        onHover(nil)
        guard let provider = info.itemProviders(for: [.plainText, .text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let str = reading as? String else { return }
            DispatchQueue.main.async { onDrop(str, edge) }
        }
        return true
    }
}

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
    /// Which edge of the CURRENTLY hovered tile (dropTargetProjectId/
    /// dropTargetFolderId) the pointer is nearest to, updated live via
    /// TileDropDelegate's dropUpdated — drives the directional capsule
    /// indicator in projectTile/folderTile (2026-07-15, replaces the old
    /// drop-time-only edge resolution, see TileDropDelegate's own doc
    /// comment for why that's now possible).
    @State private var dropTargetEdge: TileEdge?
    /// Each tile's own rendered size, captured passively via
    /// .onGeometryChange (2026-07-13) — turns TileDropDelegate's live
    /// DropInfo.location into a relative left/right/top/bottom edge via
    /// nearestEdge(of:in:), same nearest-edge-to-cursor rule the web app
    /// uses.
    @State private var tileSizes: [String: CGSize] = [:]

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

    // MARK: - Directional drop targeting

    /// Right/bottom edges mean "insert after the target" — translated to
    /// the move endpoints' before_x_id contract by looking up the target's
    /// next sibling in the currently displayed order (nil if the target is
    /// last), same as the web app's `next[idx+1]?.id ?? null`. `edge` now
    /// comes pre-resolved from TileDropDelegate's live tracking, not a
    /// drop-time-only CGPoint.
    private func beforeId(edge: TileEdge, onTarget targetId: String, orderedIds: [String]) -> String? {
        let insertAfter = edge == .right || edge == .bottom
        guard insertAfter, let idx = orderedIds.firstIndex(of: targetId) else { return targetId }
        let nextIdx = idx + 1
        return nextIdx < orderedIds.count ? orderedIds[nextIdx] : nil
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tileSizes[project.id] = $0 }
        // 2026-07-14: was a plain .contextMenu { } stacked directly with
        // .draggable() below — ShotListView's scene tiles hit this exact
        // combination first (see its own doc comment on sceneToDelete) and
        // found it broken on-device: a bare .contextMenu with its default
        // auto-preview competes with .draggable's own long-press-based
        // recognizer for gesture ownership, which can silently kill
        // dragging entirely rather than just picking one winner. That fix
        // was never ported here, so project tiles kept the broken combo —
        // matches "kann man die Objekte nicht neu anordnen". Switching to
        // .contextMenu(menuItems:preview:) is Apple's actual supported
        // combo for this (UIContextMenuInteraction + UIDragInteraction are
        // built to disambiguate "hold still" vs "hold and move" together),
        // with tileBody(...) reused as the preview instead of the default
        // full-tile auto-snapshot.
        .contextMenu {
            Button { editingProject = project } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await viewModel.delete(project) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        } preview: {
            tileBody(
                title: project.name,
                subtitle: "Wird gelöscht in \(project.daysUntilDeletion) Tagen",
                color: project.color,
                thumbnailPath: project.thumbnailUrl,
                fallbackIcon: "film.stack",
                emoji: project.emoji
            )
        }
        // Live directional landing indicator (2026-07-15, replaces the old
        // fixed top-only Capsule — see TileDropDelegate's doc comment for
        // why this can now track the actual hovered edge instead of only
        // resolving it once, at drop time).
        .overlay(alignment: dropTargetProjectId == project.id ? (dropTargetEdge.map(tileEdgeAlignment) ?? .center) : .center) {
            if dropTargetProjectId == project.id, let edge = dropTargetEdge {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: (edge == .left || edge == .right) ? 4 : nil,
                           height: (edge == .top || edge == .bottom) ? 4 : nil)
                    .frame(maxWidth: (edge == .top || edge == .bottom) ? .infinity : nil,
                           maxHeight: (edge == .left || edge == .right) ? .infinity : nil)
                    .padding(3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // Long-press-and-hold picks the tile up (standard iOS drag haptic) —
        // dropping it on a folder tile files it there, dropping it on
        // another project tile reorders. "project:"-prefixed so folderTile's
        // drop delegate below can tell a project drop apart from a folder
        // being dragged onto it (reorder), same prefix convention
        // ShotListView already uses for "scene:"/"section:".
        .draggable("project:\(project.id)")
        .onDrop(of: [.plainText, .text], delegate: TileDropDelegate(
            tileSize: tileSizes[project.id] ?? .zero,
            onHover: { edge in
                withAnimation(.easeOut(duration: 0.15)) {
                    dropTargetProjectId = edge != nil ? project.id : (dropTargetProjectId == project.id ? nil : dropTargetProjectId)
                    if edge != nil { dropTargetEdge = edge }
                }
            },
            onDrop: { raw, edge in
                guard raw.hasPrefix("project:") else { return }
                let draggedId = String(raw.dropFirst("project:".count))
                guard draggedId != project.id else { return }
                let orderedIds = viewModel.projects.map(\.id)
                let before = beforeId(edge: edge, onTarget: project.id, orderedIds: orderedIds)
                Task { await viewModel.reorderProject(draggedId, before: before) }
            }
        ))
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
        // Same plain-.contextMenu-vs-.draggable conflict as projectTile
        // above — see its doc comment.
        .contextMenu {
            Button { editingFolder = folder } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await viewModel.deleteFolder(folder) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        } preview: {
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
        .overlay {
            // Full-tile highlight — stays the generic "you're hovering over
            // this folder" signal, meaningful either way a drop resolves
            // (file a project INTO it, which has no direction of its own;
            // or reorder it among other folders, see the directional
            // capsule below for that case specifically).
            if dropTargetFolderId == folder.id {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .overlay(alignment: dropTargetFolderId == folder.id ? (dropTargetEdge.map(tileEdgeAlignment) ?? .center) : .center) {
            // Directional capsule (2026-07-15) — only meaningful for a
            // folder-onto-folder reorder; harmless to also show while
            // filing a project in (ignorable, doesn't contradict the
            // border above).
            if dropTargetFolderId == folder.id, let edge = dropTargetEdge {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: (edge == .left || edge == .right) ? 4 : nil,
                           height: (edge == .top || edge == .bottom) ? 4 : nil)
                    .frame(maxWidth: (edge == .top || edge == .bottom) ? .infinity : nil,
                           maxHeight: (edge == .left || edge == .right) ? .infinity : nil)
                    .padding(3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tileSizes[folder.id] = $0 }
        // Also draggable now (2026-07-11) — folders could be dropped ONTO
        // but never picked up themselves, so they could never be reordered
        // among each other, only ever receive a filed-in project.
        .draggable("folder:\(folder.id)")
        .onDrop(of: [.plainText, .text], delegate: TileDropDelegate(
            tileSize: tileSizes[folder.id] ?? .zero,
            onHover: { edge in
                withAnimation(.easeOut(duration: 0.15)) {
                    dropTargetFolderId = edge != nil ? folder.id : (dropTargetFolderId == folder.id ? nil : dropTargetFolderId)
                    if edge != nil { dropTargetEdge = edge }
                }
            },
            onDrop: { raw, edge in
                if raw.hasPrefix("project:") {
                    let projectId = String(raw.dropFirst("project:".count))
                    guard let project = viewModel.projects.first(where: { $0.id == projectId }) else { return }
                    Task { await viewModel.moveProject(project, toFolder: folder.id) }
                } else if raw.hasPrefix("folder:") {
                    let draggedId = String(raw.dropFirst("folder:".count))
                    guard draggedId != folder.id else { return }
                    let orderedIds = viewModel.folders.map(\.id)
                    let before = beforeId(edge: edge, onTarget: folder.id, orderedIds: orderedIds)
                    Task { await viewModel.reorderFolder(draggedId, before: before) }
                }
            }
        ))
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
                // Real Apple Liquid Glass material (iOS 26) on every tile now
                // (Lino: "der apple glas effekt soll auf ALLEN Kacheln
                // sein!" — folder/project AND scene tiles, see
                // ShotListView's regularSceneCard/sceneCompactTile for the
                // same treatment there). Supersedes the plain white
                // strokeBorder this used to have — glassEffect renders its
                // own refractive edge highlight natively. The picked-color
                // glow (the two .shadow() calls below) is a separate cue
                // (which project/folder this is), kept alongside the glass.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: thumbnailPath != nil ? Color(hex: color).opacity(0.55) : .clear, radius: 10)
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

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $creatingProject) {
                ProjectEditSheet(project: nil, defaultColor: viewModel.nextDefaultColor) { name, color, emoji, concept, scripting, postproduction in
                    if let project = await viewModel.create(
                        name: name, color: color, emoji: emoji,
                        moduleConcept: concept, moduleScripting: scripting,
                        modulePostproduction: postproduction
                    ) { path.append(project) }
                }
            }
            .sheet(isPresented: $creatingFolder) {
                FolderEditSheet(existing: nil) { name, color, emoji, image, _ in
                    await viewModel.createFolder(name: name, color: color, emoji: emoji, image: image)
                }
            }
            .sheet(item: $editingProject) { project in
                ProjectEditSheet(project: project) { name, color, emoji, concept, scripting, postproduction in
                    await viewModel.update(
                        project, name: name, color: color, emoji: emoji,
                        moduleConcept: concept, moduleScripting: scripting,
                        modulePostproduction: postproduction
                    )
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
