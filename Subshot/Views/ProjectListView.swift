import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ClerkKit

/// Drives the folder-tile drop target (2026-07-15, Lino: "hat man immer
/// noch keinen indikator um ein objekt zu verschieben und irgendwo zu
/// platzieren"). SwiftUI's Transferable-based .dropDestination only ever
/// reported a plain Bool "isTargeted" at the final drop — the classic
/// UIKit-backed DropDelegate protocol (.onDrop(of:delegate:)) receives the
/// exact same drag session .draggable() starts (same underlying
/// NSItemProvider/UIDragInteraction machinery) but fires dropEntered/
/// dropExited continuously, which is what drives the live ring highlight.
///
/// 2026-08-06, Lino (ported from the same web fix): "sortieren soll man
/// nicht können, aber man soll projekte in ordner ziehen können und ordner
/// in ordner ziehen können" — manual reordering removed entirely (see
/// ProjectListViewModel.moveFolder's doc comment for why: the backend never
/// actually read sort_order for display, so it had been a silent no-op for
/// weeks). A folder tile is now the ONLY valid drop target at all — no more
/// 4-directional edge tracking (nearestEdge/TileEdge/beforeId, all
/// removed), just "is a drag currently over me". Project tiles are no
/// longer droppable onto at all (still draggable — just nothing accepts a
/// drop on them now), so this delegate only ever attaches to folder tiles.
fileprivate struct FolderDropDelegate: DropDelegate {
    let onHover: (Bool) -> Void
    let onDrop: (_ payload: String) -> Void

    func dropEntered(info: DropInfo) {
        onHover(true)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onHover(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHover(false)
        guard let provider = info.itemProviders(for: [.plainText, .text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let str = reading as? String else { return }
            DispatchQueue.main.async { onDrop(str) }
        }
        return true
    }
}

/// Root project screen AND every folder's contents use this same view —
/// `folderId`/`folderName` nil means the root (all top-level projects +
/// folder tiles), non-nil means we're inside a folder (its own direct
/// projects AND subfolders — folders can nest, see ProjectFolder.folderCount's
/// doc comment; this view recurses into itself via .navigationDestination
/// below for any depth). Grid of tiles throughout: a project tile shows a
/// thumbnail pulled from one of its scenes, a folder tile looks identical
/// (no folder chrome) so the two read as one consistent tile system.
struct ProjectListView: View {
    let folderId: String?
    let folderName: String?

    @StateObject private var viewModel: ProjectListViewModel
    @ObservedObject private var language = AppLanguage.shared
    @Environment(Clerk.self) private var clerk
    @State private var creatingProject = false
    @State private var creatingFolder = false
    @State private var path = NavigationPath()
    @State private var editingProject: Project?
    @State private var editingFolder: ProjectFolder?
    @State private var showingNotifications = false
    @State private var showingTodoSidebar = false
    /// Blue outline on a folder tile being dragged over — shown for BOTH a
    /// project being filed into it AND another folder being nested into it
    /// (Lino, 2026-07-11: "wenn man ein Projekt oder Ordner über einen
    /// anderen Ordner legt... soll der Ziel-Ordner blau umrandet werden").
    /// 2026-08-06: folders/projects are no longer droppable onto each other
    /// for reordering (removed, see ProjectListViewModel.moveFolder's doc
    /// comment) — a folder is now the ONLY valid drop target at all, so this
    /// is the one remaining piece of hover state.
    @State private var dropTargetFolderId: String?
    /// Each tile's own rendered size, captured passively via
    /// .onGeometryChange (2026-07-13) — used to size the .contextMenu's
    /// preview to match the live tile (see projectTile's own doc comment),
    /// unrelated to drag-and-drop now.
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
                        ShotListView(
                            projectId: project.id, projectName: project.name, projectClientName: project.clientName, projectColor: project.color,
                            moduleConcept: project.moduleConcept, moduleScripting: project.moduleScripting,
                            modulePostproduction: project.modulePostproduction
                        )
                    }
                    .navigationDestination(for: ProjectFolder.self) { folder in
                        ProjectListView(folderId: folder.id, folderName: folder.name)
                    }
                    .navigationDestination(for: NotificationDeepLink.self) { link in
                        ShotListView(
                            projectId: link.project.id, projectName: link.project.name, projectClientName: link.project.clientName, projectColor: link.project.color,
                            pendingDeepLinkKind: link.entityKind, pendingDeepLinkId: link.entityId,
                            moduleConcept: link.project.moduleConcept, moduleScripting: link.project.moduleScripting,
                            modulePostproduction: link.project.modulePostproduction
                        )
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
            .task { if folderId == nil { await viewModel.loadTodoSidebar() } }
            .refreshable {
                await viewModel.load()
                if folderId == nil { await viewModel.loadNotifications() }
                if folderId == nil { await viewModel.loadTodoSidebar() }
            }
            .modifier(GridSheets(
                viewModel: viewModel, path: $path,
                creatingProject: $creatingProject, creatingFolder: $creatingFolder,
                editingProject: $editingProject, editingFolder: $editingFolder,
                showingNotifications: $showingNotifications, showingTodoSidebar: $showingTodoSidebar
            ))
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.folders) { folder in
                    folderTile(folder)
                }
                ForEach(viewModel.projects) { project in
                    projectTile(project)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        // 2026-08-05, Lino: "Startseite der app, mach den hintergrund auch
        // im typischen subshot style" — this screen never forced dark mode
        // (unlike LoginView/PostproductionListView/VideoPlayerSheet/
        // SceneAIImageSheet, all of which already do), so on a device set
        // to Light Mode the actual home/projects screen showed the plain
        // light-gray systemGroupedBackground instead of matching the rest
        // of the app's consistently dark aesthetic. Same one-line fix as
        // those other screens — systemGroupedBackground above is already
        // an adaptive color, forcing dark here is enough, no separate
        // background color needed.
        .preferredColorScheme(.dark)
        .navigationTitle(folderName ?? "Subshot")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.isLoading && viewModel.projects.isEmpty && viewModel.folders.isEmpty {
                ProgressView()
            } else if viewModel.projects.isEmpty && viewModel.folders.isEmpty {
                ContentUnavailableView(
                    language.t("projectListView.emptyTitle"),
                    systemImage: "film.stack",
                    description: Text(language.t("projectListView.emptyDescription"))
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            addButton
        }
        .overlay(alignment: .bottom) {
            todoListButton
        }
    }

    /// Bottom-center entry point (#412) to TodoSidebarSheet — the iOS
    /// equivalent of web's always-visible right sidebar (TodoSidebar.tsx),
    /// which has no room on a phone. Cross-project data, same scoping as the
    /// notification bell/avatar menu — only rendered on the root screen, not
    /// inside an opened folder.
    @ViewBuilder
    private var todoListButton: some View {
        if folderId == nil {
            Button {
                showingTodoSidebar = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checklist")
                    Text(language.t("projectListView.todoListButton"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(hex: "242426"), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
            .padding(.bottom, 20)
        }
    }

    /// Same floating-FAB pattern as ShotListView's addSceneButton — the
    /// toolbar "+" up top still works too, this is just a second, easier-to-
    /// reach spot for the same action (thumb-friendly on a big grid).
    @ViewBuilder
    private var addButton: some View {
        // 2026-07-20: "Neuer Ordner" used to only show at root (folders
        // couldn't nest yet) — now offered at every level, matching the web
        // app's #249 nested-folders behavior (a folder created while inside
        // another folder nests one level deeper, same as web).
        Group {
            Menu {
                Button {
                    creatingProject = true
                } label: {
                    Label(language.t("projectListView.newProject"), systemImage: "film.stack")
                }
                Button {
                    creatingFolder = true
                } label: {
                    Label(language.t("projectListView.newFolder"), systemImage: "folder.badge.plus")
                }
            } label: {
                fabIcon
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
            // 2026-07-21, Lino: "oben soll man auf seinen avatar klicken
            // koennen dann geht ein dialog auf bei dem man sich von der app
            // ausloggen kann, und die sprache der app aendern kann" — same
            // root-only scoping as the notification bell above (mirrors
            // web's AppShell header, which only ever renders once per
            // screen too, not per nested folder level).
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 8) {
                    // Build-freshness tag (see Config.buildTag's own doc
                    // comment in SubshotApp.swift) — only rendered on this
                    // root Projects screen, same one-per-screen scoping as
                    // the bell/avatar above.
                    Text(Config.buildTag)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    AvatarMenu()
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
                subtitle: nil,
                color: project.color,
                thumbnailPath: project.thumbnailUrl,
                fallbackIcon: "film.stack",
                emoji: project.emoji,
                pipelineStage: project.pipelineStage
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
                Label(language.t("common.edit"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await viewModel.delete(project) }
            } label: {
                Label(language.t("common.delete"), systemImage: "trash")
            }
        } preview: {
            // 2026-07-21, #274 (Lino: long-press correctly opens the menu,
            // but the tile itself renders squished into a "pill" behind
            // it) — root cause: this preview reuses tileBody with no
            // explicit size, but tileBody's own image box is
            // `Color.clear.aspectRatio(4/3, contentMode: .fit)
            // .frame(maxWidth: .infinity)`, which has no width to resolve
            // against once it's laid out here, OUTSIDE the grid's
            // adaptive GridItem column-sizing that gives it a real width
            // everywhere else (see `columns` above:
            // `.adaptive(minimum: 150)` — every tile's actual on-screen
            // width is entirely a product of THAT layout, never an
            // intrinsic size of its own). UIKit's context-menu preview
            // sizing pass ends up proposing something unbounded/only
            // loosely related to the real tile, so the 4:3 image box (and
            // its `RoundedRectangle(cornerRadius: 14)`) render at the
            // wrong aspect entirely — squashed short-and-wide enough that
            // a 14pt corner radius reads as a fully rounded capsule/"pill".
            // Fix: give the preview the SAME width the live tile actually
            // measured via onGeometryChange (tileSizes, already tracked
            // for the drag-and-drop indicator below) — Apple's own
            // guidance for .contextMenu(preview:) is exactly this, make
            // the preview's size match the source view's real size.
            tileBody(
                title: project.name,
                subtitle: nil,
                color: project.color,
                thumbnailPath: project.thumbnailUrl,
                fallbackIcon: "film.stack",
                emoji: project.emoji,
                pipelineStage: project.pipelineStage
            )
            .frame(width: tileSizes[project.id]?.width, height: tileSizes[project.id]?.height)
        }
        // Long-press-and-hold picks the tile up (standard iOS drag haptic) —
        // dropping it on a folder tile files it there. "project:"-prefixed
        // so folderTile's drop delegate can tell a project drop apart from
        // a folder being dragged onto it (nest), same prefix convention
        // ShotListView already uses for "scene:"/"section:".
        // 2026-08-06: no longer droppable ONTO — see FolderDropDelegate's
        // doc comment, a folder tile is the only valid drop target now.
        .draggable("project:\(project.id)")
    }

    @ViewBuilder
    private func folderTile(_ folder: ProjectFolder) -> some View {
        NavigationLink(value: folder) {
            tileBody(
                title: folder.name,
                subtitle: folder.tileSubtitle,
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
                Label(language.t("common.edit"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await viewModel.deleteFolder(folder) }
            } label: {
                Label(language.t("common.delete"), systemImage: "trash")
            }
        } preview: {
            // 2026-07-21, #274 — same fix as projectTile's preview above,
            // see its doc comment for the full root-cause explanation.
            tileBody(
                title: folder.name,
                subtitle: folder.tileSubtitle,
                color: folder.color,
                thumbnailPath: folder.backgroundImageURL,
                fallbackIcon: "folder.fill",
                emoji: folder.emoji,
                thumbnailFocusPoint: folder.backgroundImageFocusPoint
            )
            .frame(width: tileSizes[folder.id]?.width, height: tileSizes[folder.id]?.height)
        }
        .overlay {
            // Full-tile highlight — "you're hovering over this folder",
            // meaningful either way a drop resolves (file a project into
            // it, or nest a dragged folder into it).
            if dropTargetFolderId == folder.id {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tileSizes[folder.id] = $0 }
        // Draggable (2026-07-11, onto another folder to nest — new
        // 2026-08-06) AND droppable (receives a dragged project OR another
        // dragged folder).
        .draggable("folder:\(folder.id)")
        .onDrop(of: [.plainText, .text], delegate: FolderDropDelegate(
            onHover: { isOver in
                withAnimation(.easeOut(duration: 0.15)) {
                    dropTargetFolderId = isOver ? folder.id : (dropTargetFolderId == folder.id ? nil : dropTargetFolderId)
                }
            },
            onDrop: { raw in
                if raw.hasPrefix("project:") {
                    let projectId = String(raw.dropFirst("project:".count))
                    guard let project = viewModel.projects.first(where: { $0.id == projectId }) else { return }
                    Task { await viewModel.moveProject(project, toFolder: folder.id) }
                } else if raw.hasPrefix("folder:") {
                    let draggedId = String(raw.dropFirst("folder:".count))
                    guard draggedId != folder.id, let draggedFolder = viewModel.folders.first(where: { $0.id == draggedId }) else { return }
                    Task { await viewModel.moveFolder(draggedFolder, toParent: folder.id) }
                }
            }
        ))
    }

    /// `pipelineStage` is nil for folder tiles (they have no pipeline of
    /// their own) — only project tiles pass one, see projectTile below.
    private func tileBody(title: String, subtitle: String?, color: String, thumbnailPath: String?, fallbackIcon: String, emoji: String? = nil, thumbnailFocusPoint: UnitPoint? = nil, pipelineStage: ProjectPipelineStage? = nil) -> some View {
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
                            // 2026-08-05, Lino: "ist in der projekt oder
                            // ordner kachel ein Bild übernommen worden,
                            // verschiebt sich das emojo vom Ordner oder
                            // Projekt an den anfang vom Projekttitel" —
                            // the corner-badge-over-photo treatment (2026-07-
                            // something, "ein Emoji kann dann noch über das
                            // Bild gelegt werden") is gone; an image-having
                            // tile no longer renders the emoji here at all,
                            // it's prepended straight into the title Text
                            // below instead.
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

            // 2026-08-05, Lino: "ist in der projekt oder ordner kachel ein
            // Bild übernommen worden, verschiebt sich das emojo vom Ordner
            // oder Projekt an den anfang vom Projekttitel" — only while a
            // real thumbnail is showing (see the corner-badge removal
            // above); with no image the emoji already renders large,
            // centered, filling the whole tile, so prepending it here too
            // would show it twice.
            Text((thumbnailPath != nil && emoji?.isEmpty == false) ? "\(emoji!) \(title)" : title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            // 2026-08-05, Lino: "der pipeline status vom projekt kann nun
            // unter den projektname auf der projektübersicht" — moved off
            // the thumbnail's top-leading corner (see #319's own doc
            // comment above, now removed along with the overlay itself)
            // to directly under the title instead. No contrast/background
            // trick needed anymore now that it's sitting on the tile's
            // plain (non-photo) footer area rather than over an arbitrary
            // photo.
            if let pipelineStage {
                Text(pipelineStage.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pipelineStage.tintColor)
            }
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
    @Binding var showingTodoSidebar: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $creatingProject) {
                ProjectEditSheet(project: nil, defaultColor: viewModel.nextDefaultColor) { name, color, emoji, concept, scripting, postproduction, clientName in
                    if let project = await viewModel.create(
                        name: name, color: color, emoji: emoji, clientName: clientName,
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
                ProjectEditSheet(project: project) { name, color, emoji, concept, scripting, postproduction, clientName in
                    await viewModel.update(
                        project, name: name, color: color, emoji: emoji, clientName: clientName,
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
                NotificationsSheet(viewModel: viewModel) { project, entityKind, entityId in
                    if let entityKind, let entityId {
                        path.append(NotificationDeepLink(project: project, entityKind: entityKind, entityId: entityId))
                    } else {
                        path.append(project)
                    }
                }
            }
            .sheet(isPresented: $showingTodoSidebar) {
                TodoSidebarSheet(viewModel: viewModel) { project in
                    path.append(project)
                }
            }
    }
}

/// 2026-07-23 (#324) — a second, richer thing NavigationPath can carry to
/// ShotListView besides a plain Project (see the extra .navigationDestination
/// for this type, right next to Project.self's own). Only notification taps
/// that have a real entityKind/entityId push this instead of the plain
/// Project — every other "open a project" path (tapping a tile, creating
/// one) is untouched, still just path.append(project).
private struct NotificationDeepLink: Hashable {
    let project: Project
    let entityKind: String
    let entityId: String
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
