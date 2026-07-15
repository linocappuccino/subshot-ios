import SwiftUI
import UIKit

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
    case .optional: return Color(red: 0x3d / 255.0, green: 0x84 / 255.0, blue: 0xd8 / 255.0)
    case nil: return Color(.systemGray3)
    }
}

private extension View {
    /// Conditionally attaches .draggable() — used to suppress sceneTile's
    /// reorder-drag while swipeableCard's own gesture is active (see
    /// swipingSceneIds' doc comment on ShotListView for why: both being
    /// live at once produced two overlapping renders during a swipe).
    @ViewBuilder
    func draggableIf(_ condition: Bool, _ payload: String, @ViewBuilder preview: () -> some View) -> some View {
        if condition {
            self.draggable(payload) { preview() }
        } else {
            self
        }
    }

    /// Conditionally attaches .contextMenu(menuItems:preview:) — 2026-07-14,
    /// second attempt at the Tinder-swipe "card doubles/grows" bug: Lino
    /// confirmed the draggableIf fix above (from a fresh build) made NO
    /// visible difference at all, which means .draggable() was never the
    /// (sole) real cause. The other gesture recognizer stacked on this same
    /// card is .contextMenu's own long-press-triggered preview lift
    /// (sceneContextMenuPreview) — same class of conflict, different
    /// recognizer: a long-press starting to register at the same time as
    /// the swipe's DragGesture would show ITS OWN elevated snapshot of the
    /// tile on top of the swipe transform, which matches "two overlapping
    /// renderings, one bigger than the other" far better than a drag-lift
    /// preview would (a context menu preview visibly SCALES UP, a drag
    /// preview does not). UNVERIFIED — reasoned from re-reading the code a
    /// second time after the first fix failed, no new video was available
    /// this round (see conversation).
    @ViewBuilder
    func contextMenuIf<MenuItems: View, Preview: View>(
        _ condition: Bool,
        @ViewBuilder menuItems: () -> MenuItems,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        if condition {
            self.contextMenu(menuItems: menuItems, preview: preview)
        } else {
            self
        }
    }

    /// Conditionally attaches .scrollTargetBehavior(.viewAligned) — 2026-07-14,
    /// Lino: "smoother tiktok scroll effekt" was only ever meant for the
    /// single-column list ("wir brauchen den swipe effect nur bei der
    /// einzel kachel ansicht" applied to the same distinction elsewhere),
    /// but the snap behavior had been applied unconditionally to the whole
    /// ScrollView regardless of isCompactTileMode/isGridMode/iPad-regular
    /// grid — snapping between top-level LazyVStack children (whole
    /// sections) makes sense scrolling a single column of full-width cards,
    /// not a 2-column grid of small tiles.
    @ViewBuilder
    func scrollTargetBehaviorIf(_ condition: Bool) -> some View {
        if condition {
            self.scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }
}

/// Collapses a row of toolbar buttons into a single icon, expanding with a
/// bounce when tapped (2026-07-14, Lino: "können wir diese schliessen? und
/// wenn man drückt geht sie schnell auf mit einem überstrecht effect? ...
/// soll sich nach 3 sekunden selber wieder schliessen"). A plain SwiftUI
/// HStack instead of conditionally showing/hiding separate ToolbarItems —
/// UINavigationBar (which actually lays out toolbar items under the hood)
/// doesn't reliably animate items appearing/disappearing at all, so the
/// expand/collapse has to happen entirely inside ONE ToolbarItem's own
/// view tree to get a real, controllable spring animation.
private struct ExpandableToolbar<Content: View>: View {
    @State private var expanded = false
    @State private var collapseWork: DispatchWorkItem?
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            if expanded {
                content
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            Button {
                toggle()
            } label: {
                Image(systemName: expanded ? "xmark.circle.fill" : "ellipsis.circle")
            }
        }
        // A little breathing room before the revealed buttons when expanded
        // (2026-07-14, Lino: "mehr platz links") — without it the leftmost
        // button sits right up against the nav bar's leading content/title.
        .padding(.leading, expanded ? 8 : 0)
        // Low dampingFraction is what actually produces the visible
        // overshoot ("überstrecht") on expand — a value at/above ~0.7 would
        // just ease in with no bounce at all. Kept as a fallback for any
        // other implicit change, but toggle() below now ALSO wraps the
        // mutation in an explicit withAnimation — ToolbarItem content is
        // UIKit-bridged (hosted as real UIBarButtonItems on the
        // navigation bar, not a plain SwiftUI subview), and that bridge is
        // known to drop transitions/animations driven purely by an
        // implicit `.animation(value:)` on state mutated outside
        // withAnimation, especially on REMOVAL — which is exactly what
        // "keine Schliess-Animation, öffnen unsauber" (open shaky, close
        // has none at all) describes: expand happened to mostly work,
        // collapse silently snapped instead of animating.
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: expanded)
    }

    private func toggle() {
        collapseWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
            expanded.toggle()
        }
        if expanded { scheduleAutoCollapse() }
    }

    private func scheduleAutoCollapse() {
        let work = DispatchWorkItem {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { expanded = false }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

struct ShotListView: View {
    @StateObject private var viewModel: ShotListViewModel
    let projectName: String
    /// .regular (iPad, full-width Split View) gets the adjustable-column
    /// grid (see ipadColumnCount + columnCountPopover); .compact iPad
    /// (narrow Slide Over/multitasking) keeps the simple 1-vs-2 isGridMode
    /// toggle. Neither is offered on iPhone at all — a phone-width screen
    /// has no useful multi-column layout, and the toggle itself was
    /// reported as confusing clutter there.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// `.compact` alone can't tell an iPhone from an iPad in narrow Slide
    /// Over/multitasking (both report it) — the grid/column controls below
    /// need to distinguish those two, so they check the actual device idiom
    /// instead of just the size class.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @State private var addingToScene: String??  // nil = not adding; .some(nil) = "no scene"; .some(id) = that scene
    @State private var newShotText = ""
    @State private var selectedShot: Shot?
    @State private var showingTeamSheet = false
    /// Drives SceneAssigneeSheet (2026-07-14, multi-select) — see
    /// sceneAssigneeMenu, replacing the old single-pick native Menu (which
    /// can't stay open across multiple taps; SwiftUI's Menu dismisses on
    /// every Button action with no built-in persistent mode).
    @State private var assigneeSheetScene: Scene?
    @State private var editingScene: Scene??      // nil = sheet closed; .some(nil) = creating; .some(scene) = renaming
    /// Only meaningful while editingScene == .some(nil) (creating) — which
    /// FAB menu option was tapped. Not persisted anywhere; a reduced-field
    /// SceneEditSheet is purely a creation-time UI choice, see its own doc
    /// comment.
    @State private var creatingIntermediateStep = false
    @State private var editingSection: SceneSection??  // same nesting convention as editingScene
    @State private var sectionToDelete: SceneSection?
    /// "Ohne Abschnitt" has no SceneSection id of its own to key off of (see
    /// isSectionCollapsed/toggleSectionCollapse) — this sentinel stands in
    /// for it so the same Set can track every section's collapsed state,
    /// including the unsectioned bucket.
    private let unassignedSectionKey = "__unassigned__"
    @State private var collapsedSections: Set<String> = []
    /// The section the user most recently expanded (unassignedSectionKey for
    /// "Ohne Abschnitt", nil if none has been opened this session) — "the
    /// section you currently have open and are looking at" (Lino), used so
    /// the bottom-right "+" button's new Szene/Zwischenschritt/Info lands at
    /// the end of THAT section instead of always in "Ohne Abschnitt". Set in
    /// toggleSectionCollapse whenever a section transitions collapsed→open.
    @State private var lastOpenedSectionKey: String?
    /// Delete-confirmation target — the actual Bearbeiten/Löschen menu itself
    /// is .contextMenu now (see sceneTile etc.), triggered by the same
    /// long-press. Two custom approaches were tried and rejected before
    /// this, both confirmed broken on-device:
    /// 1. Plain .contextMenu with its default auto-preview: visually
    ///    enlarges/snapshots the source view, which distorted this app's
    ///    custom card layout ("nicht vergrössern, sonst zerstört").
    /// 2. A hand-rolled long-press via .onLongPressGesture, later
    ///    .simultaneousGesture(LongPressGesture(...)): the menu never
    ///    appeared at all with plain .onLongPressGesture (.draggable's own
    ///    internal recognizer won every time, exclusive gestures compete);
    ///    switching to .simultaneousGesture made the menu appear but then
    ///    broke dragging itself (a bare LongPressGesture doesn't cancel on
    ///    movement, so it kept firing mid-drag on any drag that took longer
    ///    than minimumDuration — reported as "kann nicht mehr nach unten
    ///    verschieben", which downward drags hit more since they typically
    ///    cover more distance/time than a one-tile-up drag).
    /// Landed on .contextMenu(menuItems:preview:) instead — Apple's actual
    /// supported combo for this (UIKit's UIContextMenuInteraction and
    /// UIDragInteraction are explicitly built to disambiguate "hold still"
    /// vs "hold and move" on the same view), with a small custom `preview:`
    /// (reusing sceneDragPreview, the same compact view already used for
    /// the drag lift) instead of the default full-tile auto-snapshot, which
    /// is what fixes the "enlarge/destroy" complaint without giving up the
    /// native disambiguation.
    @State private var sceneToDelete: Scene?
    /// Which scene tile is currently hovered by an in-flight drag — drives
    /// the thin accent-color landing indicator above that tile (see
    /// sceneCard). Not "which scene is being dragged": .draggable() doesn't
    /// expose a drag-started callback, only drop-target hover does.
    @State private var dropTargetSceneId: String?
    /// Debounces dropTargetSceneId's CLEARING only (never its activation,
    /// which stays instant) — 2026-07-11, Lino: "wenn die Drop-Zone
    /// angezeigt wird, muss man mit dem ganzen Finger in der Dropzone
    /// herumfahren können... erst wenn man eine gewisse Distanz von der
    /// Dropzone weg geht, schliesst die Dropzone". SwiftUI's own
    /// `isTargeted` is a hard boundary crossing (in/out of the current hit
    /// area, no margin) — without this, brushing the exact edge of an
    /// already-expanded indicator toggles it shut and immediately reopens
    /// it as the finger wobbles by even a point, reading as constant
    /// flicker. Cancelled on every re-entry, so a genuine "moved away and
    /// stayed away" is still the only thing that actually closes it.
    @State private var pendingSceneClearWork: DispatchWorkItem?
    // draggedSceneId + direction-aware indicator (before/after the target,
    // depending on drag direction) were here briefly, 2026-07-11 — both
    // reverted the same day. Tracking "which scene is being dragged" via
    // onAppear/onDisappear on the drag-lift preview view was NOT reliable
    // in practice (the indicator ended up always showing "before"
    // regardless of actual direction, and the extra state churn made the
    // pick-up animation itself feel broken). reorderScene is back to
    // always-insert-before-the-target (see its own doc comment) — simple,
    // no direction/state tracking needed, indicator always matches exactly
    // what happens. Also switched from a thin line to a dashed rectangle
    // placeholder per Lino's explicit request (2026-07-11: "ich möchte das
    // blau gestrichelte Rechteck... zeigt wo die Kachel landet, das ist
    // übersichtlicher") — see sceneDropIndicator below.
    /// Same idea as dropTargetSceneId, for section headers — drives the one
    /// blue-line indicator in sectionGroup for BOTH a section being dragged
    /// (reorder) AND a scene being dragged onto a section's header to file
    /// it in (2026-07-11: unified onto one indicator/one drop target per
    /// header, see sectionHeader/sectionGroup — used to also have a
    /// separate dashed-rectangle sectionDropZone that competed with scene
    /// tiles' own drop targets for the same touch region). Uses
    /// unassignedSectionKey for "Ohne Abschnitt", same sentinel convention
    /// as isSectionCollapsed.
    @State private var dropTargetSectionId: String?
    /// Same debounced-clear idea as pendingSceneClearWork, for the section
    /// header's own indicator.
    @State private var pendingSectionClearWork: DispatchWorkItem?
    /// Which completed ("im Kasten") scenes are temporarily expanded back to
    /// full detail — collapsed is the default for any completed scene (see
    /// sceneCard/sceneCollapsedRow), tapping one adds it here to "peek" at
    /// full detail again. Deliberately session-local UI state, not persisted
    /// — a fresh load always starts every completed scene collapsed.
    @State private var expandedCompletedSceneIds: Set<String> = []
    /// Dialog list on a scene tile, collapsed by tapping its "Dialog" label
    /// (2026-07-11, matches the web app) — expanded by default (empty set),
    /// same session-local-only reasoning as expandedCompletedSceneIds.
    @State private var collapsedDialogSceneIds: Set<String> = []
    @State private var collapsedDescriptionSceneIds: Set<String> = []
    @State private var collapsedShotsSceneIds: Set<String> = []
    /// Tinder-style swipe (2026-07-13, Lino: "genau so wie bei Tinder
    /// aussehen") — horizontal drag offset per scene, keyed like the
    /// collapse-state Sets above. Left past the threshold deletes
    /// (immediately, no confirm dialog — the full-throw animation IS the
    /// confirmation, exactly like Tinder's reject swipe); right marks "im
    /// Kasten". Both are purely ADDITIVE — the existing long-press-menu
    /// delete and the imKastenButton keep working exactly as before.
    ///
    /// UNVERIFIED ON DEVICE (2026-07-13, no simulator available here) —
    /// attached via .simultaneousGesture (not .gesture/.highPriorityGesture)
    /// specifically because this file has a DOCUMENTED case of a second
    /// exclusive gesture recognizer stacked on this exact card hierarchy
    /// breaking .contextMenu entirely on-device (see regularSceneCard's
    /// "No dropDestination here anymore" comment) — simultaneous should be
    /// far less likely to steal the touch from .draggable/.contextMenu, but
    /// this is a reasoned guess, not a tested one. If the long-press menu
    /// or scene reordering stops working after this, that's the first
    /// place to look, and reverting this swipe gesture is a legitimate fix.
    @State private var sceneSwipeOffsets: [String: CGFloat] = [:]
    @State private var sceneSwipeExiting: Set<String> = []
    /// Set the instant a horizontal swipe is recognized (see swipeableCard's
    /// onChanged), cleared on release — sceneTile reads this to suppress its
    /// own .draggable() while true. Root-caused 2026-07-14 from a screen
    /// recording Lino sent: what looked like the card "growing weirdly
    /// toward the text" was actually TWO overlapping renders — the custom
    /// swipe transform on top of the system's own .draggable() drag-lift
    /// preview, both live at once because .simultaneousGesture (see above)
    /// deliberately lets both recognizers run together. This only ever
    /// suppresses .draggable() during a swipe that's ALREADY past the
    /// horizontal-vs-vertical threshold, so reordering via long-press+drag
    /// when NOT swiping is untouched.
    @State private var swipingSceneIds: Set<String> = []
    @State private var isExportingPdf = false
    @State private var exportedPdfURL: URL?
    @State private var shareLinkURL: URL?
    @State private var isPresentingShareSheet = false
    @State private var showingShareLinkSheet = false
    /// List (current, one full-width tile per row) vs. grid (2 columns) —
    /// per-device preference, not project state, so it doesn't need a
    /// backend round trip and each person on set can pick what fits their
    /// phone/how they like to scan the board.
    @AppStorage("shotListGridMode") private var isGridMode = false
    /// Independent of isGridMode/ipadColumnCount above (those control column
    /// *count* for the same full-detail card) — this switches to an entirely
    /// different, reduced-info 2-column tile (photo + number/title/priority +
    /// timer only, no dialogues/address/good-take/assignee/description) for a
    /// fast visual overview. Available on every device, not iPad-gated like
    /// the column controls, since a phone-width quick scan is exactly the
    /// point of this mode.
    @AppStorage("sceneCompactTileMode") private var isCompactTileMode = false
    /// Mirrors sceneGrid's own single-column-vs-grid branching exactly (see
    /// its else branch) — the TikTok-style scroll-snap only makes sense
    /// scrolling one full-width card at a time, not a multi-column grid of
    /// small tiles (2026-07-14, see scrollTargetBehaviorIf's doc comment).
    private var wantsScrollSnap: Bool {
        !isCompactTileMode && !(isPad && isGridMode) && horizontalSizeClass != .regular
    }
    /// iPad-only column count, adjustable via a slider (see
    /// columnCountPopover) — 1...4, stored as Double since Slider needs a
    /// floating-point binding; always rounded before use as a grid column
    /// count or an array-repeat argument.
    @AppStorage("shotListIpadColumnCount") private var ipadColumnCountRaw: Double = 3
    @State private var showingColumnCountPopover = false
    private var ipadColumnCount: Int { Int(ipadColumnCountRaw.rounded()) }
    /// Quick good-take entry always available on a scene's main tile — see
    /// sceneGoodTakeButton.
    @State private var editingGoodTakeScene: Scene?
    @State private var goodTakeText = ""
    /// Dialog-line text correction (2026-07-11) — long-press a dialogue row
    /// > Bearbeiten (see dialogueRow's .contextMenu). Needs both the
    /// dialogue AND its owning scene (updateDialogue looks the scene up by
    /// id), same two-piece-state shape as editingGoodTakeScene above.
    @State private var editingDialogue: (dialogue: SceneDialogue, scene: Scene)?
    @State private var editingDialogueText = ""
    @FocusState private var newRowFocused: Bool
    private let projectId: String

    init(projectId: String, projectName: String) {
        self.projectId = projectId
        _viewModel = StateObject(wrappedValue: ShotListViewModel(projectId: projectId))
        self.projectName = projectName
    }

    var body: some View {
        ScrollView {
            // TikTok-style scroll (2026-07-13, Lino: "wenn man einmal
            // schnell... wischt kommt man direkt zur nächsten Kachel...
            // wenn man langsam wischt kann man... langsam scrollen") —
            // .scrollTargetLayout()+.scrollTargetBehavior(.viewAligned)
            // (standard SwiftUI/iOS 17+ API, not a custom gesture) gives
            // exactly this for free: a fast flick's own momentum carries
            // it past the nearest boundary to snap on the NEXT one, a slow
            // deliberate drag scrolls freely and only settles to the
            // nearest boundary once released. Snaps between every TOP-
            // LEVEL child of this LazyVStack — ProjectInfoBox, the
            // unassigned-scenes block, each whole section block — not
            // individual scene cards nested inside a section (Lino chose
            // this simpler "between every element, headers included" scope
            // over a per-card-only version, which would need scroll
            // targets nested inside each section's own scene list instead
            // of just this one top-level container).
            LazyVStack(alignment: .leading, spacing: 16) {
                // Scrolls with the rest of the content again — the earlier
                // hang/crash turned out to be the general iOS-26.5-Simulator
                // rendering bug (see project memory), not MapKit itself, so
                // scene tiles below do use a real MKMapSnapshotter thumbnail
                // (SceneMapThumbnail, cached like AsyncShotThumbnail so
                // LazyVStack recycling doesn't regenerate one per re-render).
                ProjectInfoBox(viewModel: viewModel, projectId: projectId)

                // 2026-07-14: was unconditional — with zero unassigned
                // shots (the common case) this still rendered an empty,
                // near-invisible ~32pt VStack (just its own vertical
                // padding, no content). As a direct LazyVStack child it's
                // ALSO a .scrollTargetLayout() snap target (see the
                // TikTok-scroll doc comment above), so that empty sliver
                // sat as a real scroll-snap boundary wedged between
                // ProjectInfoBox and the first actual section — right
                // where Lino reported the top section becoming
                // unclickable/undraggable/uncollapsible (a snap target
                // with nothing in it still competes for the ScrollView's
                // own pan-gesture arbitration at that boundary). Guarding
                // it the same way sectionGroup(section: nil) already
                // guards its own empty case (below) removes that phantom
                // target entirely when there's nothing to show.
                if !viewModel.shots(in: nil).isEmpty {
                    unassignedSection()
                }

                // Sections are opt-in — a project that's never created one
                // renders exactly like before (flat scene list, no headers).
                // Only once at least one section exists does grouping (with
                // an explicit "Ohne Abschnitt" bucket for the rest) kick in.
                if viewModel.sections.isEmpty {
                    // scenes(in: nil), not the raw array — a project with no
                    // sections yet still has every scene's sectionId == nil,
                    // so this is equivalent to the unsectioned bucket below,
                    // just without its own header.
                    sceneGrid(viewModel.scenes(in: nil))
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
            .scrollTargetLayout()
        }
        .scrollTargetBehaviorIf(wantsScrollSnap)
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottomTrailing) {
            addSceneButton
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 2026-07-14, Lino: "momentan ist die icon bar oben ja immer
            // offen, können wir diese schliessen? und wenn man drückt geht
            // sie schnell auf mit einem überstrecht effect? ... das stretch
            // menü oben soll sich nach 3 sekunden selber wieder schliessen."
            // Every button that used to be its own always-visible
            // ToolbarItem now lives inside ONE ExpandableToolbar, collapsed
            // to a single icon by default — see its own doc comment for why
            // this needs a custom view instead of native ToolbarItems (the
            // overshoot animation has to be a plain SwiftUI view
            // transition, not a UINavigationBar-managed item
            // insertion/removal, which doesn't reliably animate at all).
            ToolbarItem(placement: .navigationBarTrailing) {
                ExpandableToolbar {
                    // 2026-07-13, Lino: "können wir das oben zur Iconbar
                    // hinzufügen? (so ein Rückgängig Pfeil?)" — same undo
                    // the bottom toast already offers (undoToast below),
                    // just also reachable from the toolbar. Extended
                    // 2026-07-14 to also cover viewModel.undoStack, not
                    // just the shot-delete toast — see performUndo()'s doc
                    // comment for how the two mechanisms share this button.
                    if viewModel.pendingUndoShot != nil || !viewModel.undoStack.isEmpty {
                        Button {
                            Task { await viewModel.performUndo() }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                    }
                    // Reduced-info 2-column tile overview vs. today's full-detail
                    // cards — orthogonal to the iPad-only column controls below
                    // (those change how many full cards fit per row; this changes
                    // how much detail each tile shows at all), so it's offered on
                    // every device including iPhone.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isCompactTileMode.toggle() }
                    } label: {
                        Image(systemName: isCompactTileMode ? "checklist" : "square.grid.2x2")
                    }
                    if isPad {
                        if horizontalSizeClass == .regular {
                            Button {
                                showingColumnCountPopover = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .popover(isPresented: $showingColumnCountPopover) {
                                columnCountPopover
                            }
                        } else {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { isGridMode.toggle() }
                            } label: {
                                Image(systemName: isGridMode ? "rectangle.grid.1x2" : "square.grid.2x2")
                            }
                        }
                    }
                    if let exportedPdfURL {
                        ShareLink(item: exportedPdfURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    } else if isExportingPdf {
                        ProgressView()
                    } else {
                        // 2026-07-13, Lino: "beim Klick auf PDF Export soll
                        // zuerst gefragt werden, ob Kachelansicht oder
                        // Tabellenansicht exportiert werden soll" — was a
                        // single tap straight to the (card-only) export before.
                        Menu {
                            Button("Kachelansicht") { Task { await exportPdf(view: "cards") } }
                            Button("Tabellenansicht") { Task { await exportPdf(view: "table") } }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    // Opens the management sheet (link + optional password)
                    // instead of sharing straight away — password protection
                    // needs a place to live, and folding it into a quick-share
                    // one-tap button would either bury it or turn every share
                    // into a two-tap flow either way, so it's its own sheet now.
                    Button {
                        showingShareLinkSheet = true
                    } label: {
                        Image(systemName: "link")
                    }
                    Button { showingTeamSheet = true } label: {
                        Image(systemName: "person.2")
                    }
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        // Lightweight "live updates" (2026-07-10): polls every 12s while
        // this screen is open so a teammate's edits show up without anyone
        // pulling to refresh — deliberately NOT a websocket/real-time typing
        // sync (overkill for a shot list: people mostly toggle checkboxes/
        // add shots, not co-edit the same text field char-by-char). `load()`
        // already replaces state via whole-array assignment matched by
        // Identifiable id, which SwiftUI diffs in place with no flicker/
        // loading-spinner flash (no isLoading gate anywhere in this view) —
        // confirmed that's what makes this safe to do silently in the
        // background. Separate `.task` from the initial load above so a
        // pull-to-refresh or the first load isn't affected by this timer's
        // own lifecycle.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if Task.isCancelled { break }
                await viewModel.load()
            }
        }
        .sheet(item: $selectedShot) { shot in
            ShotDetailSheet(shot: shot, viewModel: viewModel)
        }
        .sheet(item: $assigneeSheetScene) { scene in
            SceneAssigneeSheet(scene: scene, viewModel: viewModel)
        }
        .sheet(isPresented: $showingTeamSheet) {
            TeamSheet(projectId: projectId)
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            if let shareLinkURL {
                ActivityView(activityItems: [shareLinkURL])
            }
        }
        .sheet(isPresented: $showingShareLinkSheet) {
            ShareLinkSheet(projectId: projectId) { url in
                shareLinkURL = url
                isPresentingShareSheet = true
            }
        }
        // Every failed API call in this screen (including a scene/shot image
        // upload that didn't make it — e.g. a dropped connection mid-upload)
        // only ever set viewModel.errorMessage; nothing displayed it, so
        // those failures were completely silent — "the image just doesn't
        // show up" with no error at all. This is the single alert for all of
        // them.
        .alert("Fehler", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Good Take", isPresented: Binding(
            get: { editingGoodTakeScene != nil },
            set: { if !$0 { editingGoodTakeScene = nil } }
        )) {
            TextField("Dateiname, z.B. A003_C012", text: $goodTakeText)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                if let scene = editingGoodTakeScene {
                    let trimmed = goodTakeText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await viewModel.setSceneGoodTake(scene, filename: trimmed.isEmpty ? nil : trimmed) }
                }
            }
        } message: {
            Text("Dateiname der guten Aufnahme für diese Szene.")
        }
        .alert("Dialogzeile bearbeiten", isPresented: Binding(
            get: { editingDialogue != nil },
            set: { if !$0 { editingDialogue = nil } }
        )) {
            TextField("Dialogtext", text: $editingDialogueText)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                if let (dialogue, scene) = editingDialogue {
                    Task { await viewModel.updateDialogue(dialogue, in: scene, text: editingDialogueText) }
                }
            }
        }
        // "Timing der App" (2026-07-11) — offers to shift every later
        // same-day scene's start by the same delta the just-edited scene's
        // start moved by. Never applied silently — see
        // applyTimeCascade/pendingTimeCascade. Exact wording per Lino's
        // spec (2026-07-13): "Möchtest du die nachfolgenden Szenen
        // zeitlich angleichen? Bestätigen / nicht angleichen."
        .confirmationDialog(
            "Möchtest du die nachfolgenden Szenen zeitlich angleichen?",
            isPresented: Binding(
                get: { viewModel.pendingTimeCascade != nil },
                set: { if !$0 { viewModel.pendingTimeCascade = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Bestätigen") {
                Task { await viewModel.applyTimeCascade() }
            }
            Button("Nicht angleichen", role: .cancel) {
                viewModel.pendingTimeCascade = nil
            }
        }
        .alert("Alles im Kasten?", isPresented: $viewModel.showAllTimedScenesDoneConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Alle Shots wirklich im Kasten, hast du auch wirklich keine Aussage oder Szene vergessen?")
        }
        // All 5 of these (Abschnitt/Szene-löschen alerts, Szene/Abschnitt/
        // Delete-confirmation alerts for Abschnitt/Szene — used to be inline
        // modifiers right here — Xcode's "unable to type-check in
        // reasonable time" on this file was this modifier chain (already
        // long before these were added: sheets, other alerts, toolbar,
        // task, etc., all on the same body expression) finally tipping
        // over. Moved into their own ViewModifier below so the compiler
        // only has to type-check one `.modifier(...)` call here.
        .modifier(TileActionDialogs(
            viewModel: viewModel,
            sectionToDelete: $sectionToDelete,
            sceneToDelete: $sceneToDelete
        ))
        .sheet(isPresented: Binding(
            get: { editingScene != nil },
            set: { if !$0 { editingScene = nil } }
        )) {
            if case .some(let existing) = editingScene {
                SceneEditSheet(existing: existing, isIntermediateStep: creatingIntermediateStep, viewModel: viewModel) { name, color, description, dialogue, scheduledAt, durationMinutes, priority in
                    if let existing {
                        await viewModel.renameScene(existing, name: name, color: color, description: description, dialogue: dialogue, scheduledAt: scheduledAt, durationMinutes: durationMinutes, priority: priority)
                        return existing
                    } else {
                        return await viewModel.createScene(
                            name: name.isEmpty ? "Unbenannte Szene" : name, color: color,
                            description: description.isEmpty ? nil : description,
                            dialogue: dialogue.isEmpty ? nil : dialogue,
                            scheduledAt: scheduledAt,
                            durationMinutes: durationMinutes,
                            sectionId: targetSectionIdForNewScene,
                            priority: priority,
                            isIntermediateStep: creatingIntermediateStep
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
    /// iPad-only: lets someone pick how many columns of scene tiles fit
    /// side by side — more columns naturally means smaller tiles, there's no
    /// separate "tile size" knob since the two are the same thing once the
    /// grid is fixed-width.
    private var columnCountPopover: some View {
        VStack(spacing: 12) {
            Text("\(ipadColumnCount) Spalten")
                .font(.headline)
            Slider(value: $ipadColumnCountRaw, in: 1...4, step: 1)
                .frame(width: 220)
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }

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
            Button {
                // NEVER auto-creates a Section (2026-07-11 fix — used to
                // create a Section with add_project_info set, which is
                // wrong: "möchte man eine Projektinfo hinzufügen, wird ein
                // Abschnitt hinzugefügt, das ist falsch"). A Projektinfo is
                // just a scene tile now (see Scene.isProjectInfo) — lands at
                // the end of the currently-open section (see
                // targetSectionIdForNewScene), "Ohne Abschnitt" only if none
                // is open, same as Neue Szene/Zwischenschritt below.
                Task { await viewModel.createProjectInfoScene(sectionId: targetSectionIdForNewScene) }
            } label: {
                Label("Info", systemImage: "info.circle")
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

    /// Renders a set of scene cards either as today's single full-width
    /// column, or as a 2-column grid — see isGridMode. Grid mode owns the
    /// horizontal padding + inter-column gap itself (sceneCard skips its own
    /// side padding in that mode, see sceneCard's modifier chain) so columns
    /// and the row spacing above/below read as one consistent gap, not a
    /// doubled-up one.
    @ViewBuilder
    private func sceneGrid(_ scenes: [Scene]) -> some View {
        if isCompactTileMode {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(scenes) { scene in
                    // A Projektinfo tile has no name/priority/image to show
                    // in the reduced compact layout — same full-width card
                    // as every other mode instead (LazyVGrid has no column-
                    // span, so this still only occupies one of the two
                    // cells; a pre-existing limitation of this grid, not
                    // something 2026-07-11's stacking/drag fixes address).
                    if scene.isProjectInfo {
                        // 2026-07-13, Lino: "hier sollen die Info und
                        // Szenenkacheln immer gleich gross aussehen... sonst
                        // hat man zu viel leeren Raum" — collapsed, this tile
                        // used to be just a thin single-row header sitting in
                        // a grid cell as tall as its full-size neighbors,
                        // leaving a big empty gap under it. compactGrid
                        // matches it to the same 4:5 box as sceneCompactTile.
                        projectInfoSceneCard(scene: scene, compactGrid: true)
                    } else {
                        sceneCompactTile(scene: scene)
                    }
                }
            }
            .padding(.horizontal, 16)
        } else if horizontalSizeClass == .regular {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: ipadColumnCount), spacing: 12) {
                ForEach(scenes) { scene in
                    sceneCard(scene: scene, columnLayout: ipadColumnCount > 1)
                }
            }
            .padding(.horizontal, 16)
        } else if isPad && isGridMode {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(scenes) { scene in
                    sceneCard(scene: scene, columnLayout: true)
                }
            }
            .padding(.horizontal, 16)
        } else {
            ForEach(scenes) { scene in
                sceneCard(scene: scene, columnLayout: false)
            }
        }
    }

    /// `section == nil` renders the "Ohne Abschnitt" bucket — only shown at
    /// all once at least one real section exists (see body above). Uses
    /// unassignedSectionKey to participate in the same collapse tracking as
    /// real sections (see isSectionCollapsed/toggleSectionCollapse) even
    /// though it has no SceneSection id of its own.
    @ViewBuilder
    private func sectionGroup(section: SceneSection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Landing indicator — ONE indicator type everywhere now, same
            // dashed-rectangle style as scenes (see sceneDropIndicator's
            // doc comment for the full history: was a thin capsule line,
            // before that a second competing dashed-rectangle drop zone).
            // Covers both a dragged SECTION being reordered AND a scene
            // being filed into a section via its header (see
            // sectionHeader) — same key (dropTargetSectionId,
            // unassignedSectionKey for "Ohne Abschnitt") for both cases.
            //
            // CRITICAL fix (2026-07-11): this used to be a plain VStack
            // sibling that grew 0→60pt in the layout itself. Since the
            // actual .dropDestination/isTargeted lives on sectionHeader
            // right below it (not on this rectangle), growing this sibling
            // physically PUSHED the header down and out from under the
            // finger the instant isTargeted flipped true — which
            // immediately flipped isTargeted back to false, shrinking this
            // back to 0, snapping the header back up under the finger,
            // flipping isTargeted true again... an infinite feedback loop
            // (Lino: "wackelt sehr stark herum und zerkleinert und
            // vergrössert sich die ganze Zeit"), and a release landing
            // mid-oscillation could miss the header's bounds entirely,
            // which is why the whole section appeared to "spring back" to
            // its original position instead of actually moving. Fix: keep
            // a CONSTANT-height spacer in the layout flow (so the header
            // below never moves, regardless of drag state) and render the
            // growing rectangle as an `.overlay` on top of it — overlays
            // don't affect their parent's layout size, so the visual
            // grow/shrink animation no longer displaces the actual drop
            // target underneath it.
            // Height is a CONSTANT 0 always — not just "small at rest" — so
            // the header below it never moves by so much as a point,
            // whether idle, hovered, or mid-animation (2026-07-11, second
            // pass: a nonzero resting height here, even a small one, is a
            // permanent gap between every section whether anything is being
            // dragged or not, which Lino explicitly does NOT want — "ich
            // will keine Abstände sondern die sollen breiter werden wenn
            // ein Indikator dazwischen rutscht"). The whole visual (dashed
            // rectangle growing to 60pt on hover) lives entirely in the
            // `.overlay`, which — unlike `.frame` — never contributes to
            // this view's own layout size, so it can render taller than its
            // own 0pt box without pushing anything.
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .center) {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .frame(height: (dropTargetSectionId == (section?.id ?? unassignedSectionKey)) ? 60 : 12)
                        .opacity(dropTargetSectionId == (section?.id ?? unassignedSectionKey) ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dropTargetSectionId)
            sectionHeader(section: section)
            if let section {
                sectionProjectInfoArea(section: section)
            }
            if !isSectionCollapsed(section) {
                sceneGrid(viewModel.scenes(in: section))
            }
        }
    }

    private func isSectionCollapsed(_ section: SceneSection?) -> Bool {
        collapsedSections.contains(section?.id ?? unassignedSectionKey)
    }

    /// Resolves lastOpenedSectionKey to an actual section id for new-scene
    /// creation (nil for "Ohne Abschnitt" — createScene's own default — and
    /// also nil if nothing's been opened yet this session, or the
    /// previously-opened section was deleted meanwhile/no longer exists).
    private var targetSectionIdForNewScene: String? {
        guard let key = lastOpenedSectionKey, key != unassignedSectionKey else { return nil }
        return viewModel.sections.contains { $0.id == key } ? key : nil
    }

    private func toggleSectionCollapse(_ section: SceneSection?) {
        let key = section?.id ?? unassignedSectionKey
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            if collapsedSections.contains(key) {
                collapsedSections.remove(key)
                lastOpenedSectionKey = key
            } else {
                collapsedSections.insert(key)
            }
        }
    }

    /// Multi-day shoots (2026-07-10): shows the section's SectionInfoBox
    /// once it has one. No more per-section "+ Projektinfo hinzufügen"
    /// button (same day, Lino: it showed above every single section
    /// regardless of whether that section had one yet, which read as
    /// clutter once "Projektinfo" became its own option in the main "+"
    /// menu — that menu creates a section with project info already
    /// attached in one step, so there's no "plain section, add info later"
    /// path to support here anymore). Never shown for the unsectioned
    /// "Ohne Abschnitt" bucket (that one has no SceneSection of its own to
    /// attach an info box to, only the project-level ProjectInfoBox exists
    /// there).
    @ViewBuilder
    private func sectionProjectInfoArea(section: SceneSection) -> some View {
        if section.hasProjectInfo {
            SectionInfoBox(viewModel: viewModel, section: section, projectId: projectId)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func sectionHeader(section: SceneSection?) -> some View {
        let row = sectionHeaderRow(section: section)
        if let section {
            // Long-press-and-hold the header row to pick the whole section
            // up and drop it on another section's header to reorder — same
            // haptic drag idiom as project/scene tiles. The SAME header is
            // also the only drop target for filing a scene INTO this
            // section now (see dropDestination below) — replaces the old
            // separate dashed-rectangle sectionDropZone entirely (2026-07-11,
            // see sectionGroup's comment on why: two competing drop targets
            // caused drops to sometimes land on the wrong handler).
            row
                .contextMenu {
                    Button {
                        editingSection = .some(section)
                    } label: {
                        Label("Umbenennen", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        sectionToDelete = section
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                    Divider()
                    sortMenuItems(sectionId: section.id)
                } preview: {
                    // Was just Text(name) — read as the row "collapsing"
                    // down to a bare label on hold, same complaint/fix as
                    // sceneContextMenuPreview above. Reusing the actual row
                    // at natural width keeps holding visually a no-op aside
                    // from the lift.
                    sectionHeaderRow(section: section)
                        .frame(width: 320)
                        .background(Color(.secondarySystemGroupedBackground))
                }
                .draggable("section:\(section.id)")
                .dropDestination(for: String.self) { ids, _ in
                    guard let raw = ids.first else { return false }
                    if raw.hasPrefix("section:") {
                        let draggedId = String(raw.dropFirst("section:".count))
                        guard draggedId != section.id else { return false }
                        Task { await viewModel.reorderSection(draggedId, before: section.id) }
                        return true
                    } else if raw.hasPrefix("scene:") {
                        // Files the scene into this section — no "before"
                        // target on a header, so it just lands via
                        // assignSceneToSection (matches what the old
                        // sectionDropZone did). Works identically whether
                        // this section already has scenes or is empty —
                        // dropping directly onto one of its existing scene
                        // tiles (see sceneTile's own dropDestination) is
                        // still the way to also control exact position.
                        let sceneId = String(raw.dropFirst("scene:".count))
                        guard let dragged = viewModel.scenes.first(where: { $0.id == sceneId }) else { return false }
                        Task { await viewModel.assignSceneToSection(dragged, sectionId: section.id) }
                        return true
                    }
                    return false
                } isTargeted: { targeted in
                    setSectionDropTarget(section.id, targeted: targeted)
                }
        } else {
            // "Ohne Abschnitt" — no rename/delete/reorder (not a real
            // SceneSection), but still a valid target for filing a scene
            // OUT of any section back to unassigned. Auto-sort still
            // applies here (2026-07-13), via a plain contextMenu (no
            // rename/delete to combine it with).
            row
                .contextMenu { sortMenuItems(sectionId: nil) }
                .dropDestination(for: String.self) { ids, _ in
                    guard let raw = ids.first, raw.hasPrefix("scene:") else { return false }
                    let sceneId = String(raw.dropFirst("scene:".count))
                    guard let dragged = viewModel.scenes.first(where: { $0.id == sceneId }) else { return false }
                    Task { await viewModel.assignSceneToSection(dragged, sectionId: nil) }
                    return true
                } isTargeted: { targeted in
                    setSectionDropTarget(unassignedSectionKey, targeted: targeted)
                }
        }
    }

    /// Auto-sort button (2026-07-13, Lino) — shared between the named-
    /// section context menu and the "Ohne Abschnitt" one.
    @ViewBuilder
    private func sortMenuItems(sectionId: String?) -> some View {
        Button {
            Task { await viewModel.sortScenes(sectionId: sectionId, by: .number) }
        } label: {
            Label("Nach Identifikationsnummer sortieren", systemImage: "number")
        }
        Button {
            Task { await viewModel.sortScenes(sectionId: sectionId, by: .time) }
        } label: {
            Label("Nach Zeit sortieren", systemImage: "clock")
        }
        Button {
            Task { await viewModel.sortScenes(sectionId: sectionId, by: .location) }
        } label: {
            Label("Nach Ort sortieren", systemImage: "mappin.and.ellipse")
        }
        Button {
            Task { await viewModel.sortScenes(sectionId: sectionId, by: .priority) }
        } label: {
            Label("Nach Priorität sortieren", systemImage: "exclamationmark.circle")
        }
    }

    /// Debounced-activation helper for the section header's indicator — see
    /// pendingSectionClearWork's own doc comment for why the CLEAR (not the
    /// activate) side needs the delay. Shared by both the named-section and
    /// "Ohne Abschnitt" header branches above.
    private func setSectionDropTarget(_ key: String, targeted: Bool) {
        pendingSectionClearWork?.cancel()
        if targeted {
            withAnimation(.easeOut(duration: 0.15)) { dropTargetSectionId = key }
        } else {
            let work = DispatchWorkItem {
                withAnimation(.easeOut(duration: 0.15)) {
                    if dropTargetSectionId == key { dropTargetSectionId = nil }
                }
            }
            pendingSectionClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    /// Same idea as setSectionDropTarget, for scene-tile drop gaps.
    private func setSceneDropTarget(_ id: String, targeted: Bool) {
        pendingSceneClearWork?.cancel()
        if targeted {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dropTargetSceneId = id }
        } else {
            let work = DispatchWorkItem {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if dropTargetSceneId == id { dropTargetSceneId = nil }
                }
            }
            pendingSceneClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    /// Whole row (chevron + name, "Ohne Abschnitt" included) toggles
    /// collapse on tap now, not just the small chevron hit target — and
    /// long-press opens Umbenennen/Löschen via .contextMenu, attached in
    /// sectionHeader (see sceneToDelete's doc comment on why .contextMenu,
    /// not a hand-rolled gesture). "Ohne Abschnitt" has nothing to
    /// rename/delete, so it only gets the tap-to-collapse behavior, no
    /// long-press menu.
    @ViewBuilder
    private func sectionHeaderRow(section: SceneSection?) -> some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isSectionCollapsed(section) ? 0 : 90))
                .frame(width: 30, height: 30)
            Text(section?.name ?? "Ohne Abschnitt")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let section {
                let scenes = viewModel.scenes(in: section)
                let done = scenes.filter(\.completed).count
                Text("\(done)/\(scenes.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        // Was sized purely by its content (~30pt, just the chevron's own
        // frame) — well under the 44pt tap target this app uses everywhere
        // else (see e.g. MemberAvatar/initialsCircle comments), and far
        // smaller than a whole scene tile. A long-press-to-drag gesture
        // needs the initial press to land and hold on the target; a strip
        // this thin made that unreliable, which likely explains "Abschnitte
        // haben nie einen Indikator" (2026-07-11) — scenes, with their much
        // bigger tile area, don't have this problem.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { toggleSectionCollapse(section) }
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
            // Same fix as regularSceneCard's own shot dropDestination —
            // explicitly reject non-shot payloads instead of silently
            // no-op'ing them, so a "scene:"-prefixed drop that resolves
            // here can fall through instead of vanishing.
            guard let dragged = ids.first, !dragged.hasPrefix("scene:") else { return false }
            Task { await viewModel.moveShot(dragged, toScene: nil) }
            return true
        } isTargeted: { _ in }
    }

    /// A completed scene that isn't currently expanded (see
    /// expandedCompletedSceneIds) — collapsed is the default state for any
    /// "im Kasten" scene.
    private func isCollapsed(_ scene: Scene) -> Bool {
        scene.completed && !expandedCompletedSceneIds.contains(scene.id)
    }

    /// Landing placeholder — a dashed rectangle instead of a thin line
    /// (2026-07-11, Lino's explicit preference: "ich möchte das blau
    /// gestrichelte Rechteck... das ist übersichtlicher"), always rendered
    /// ABOVE the hovered tile, matching reorderScene's own always-insert-
    /// before behavior exactly (see its doc comment) — no direction
    /// tracking needed, so nothing here depends on knowing which scene is
    /// being dragged (that turned out to have no reliable signal — see the
    /// removed draggedSceneId/dragWillLandAfter, reverted the same day).
    ///
    /// `isActive` toggles opacity, NOT presence — conditionally adding/
    /// removing this from the view tree (the old `if dropTargetSceneId ==
    /// scene.id { ... }` at every call site) changes the VStack's total
    /// layout height every time hover enters/leaves ANY tile during a
    /// drag, reflowing every tile around the hover point mid-gesture and
    /// moving the actual drop target's on-screen bounds out from under the
    /// finger continuously ("man muss die Linie super genau treffen...
    /// sonst springt alles ein wenig herum", 2026-07-11) — not insufficient
    /// hit-testing tolerance, a self-inflicted moving target. Always
    /// reserving this exact space keeps every tile's height constant for
    /// the whole drag.
    /// The gap ITSELF is the drop target now (2026-07-11: "ich will ja
    /// dass man in den Zwischenraum draggen kann... man muss sie genau
    /// über das blaue Rechteck draggen und loslassen damit es richtig
    /// platziert wird") — not just a decoration next to the tile's own
    /// dropDestination. Collapsed to zero height by default (no permanent
    /// gap between tiles — "die Kacheln haben jetzt immer einen
    /// unschönen Abstand"), only expands to a real drop target while a
    /// drag is hovering directly over it, animated so neighboring tiles
    /// visibly move apart to make room — same "live reflow" idea already
    /// proven on the web client (see project memory). `target` is the
    /// scene this gap sits directly before.
    /// `showsVisual: false` (2026-07-14, 2-column compact grid only, see
    /// sceneCompactTile) keeps the exact same invisible hit-test/dropDestination
    /// behavior below but never draws the dashed rectangle itself — a gap
    /// growing ABOVE one specific grid cell reads as "insert directly above
    /// me" in a single column, but is actively misleading in 2 columns
    /// (Lino: "die Indikatoren auf der 2 Spalten Ansicht machen keinen
    /// Sinn") since it can never express landing to a tile's LEFT/RIGHT,
    /// only above its own cell regardless of where the finger actually is.
    /// sceneCompactTile shows a border-highlight on the TARGET tile itself
    /// instead (edge-agnostic "lands next to this one", same idea as
    /// ProjectListView's folderTile drop highlight) — same underlying
    /// dropDestination/gesture setup, just a different visual for the
    /// identical activation state, so none of the gesture-recognizer
    /// fragility called out below is touched.
    private func sceneDropIndicator(before target: Scene, showsVisual: Bool = true) -> some View {
        let isActive = dropTargetSceneId == target.id && showsVisual
        // NEVER truly zero height — a view with zero size has zero hit-
        // testable area, so a drag could never hover over it in the first
        // place to trigger the expansion to begin with (a real bug found
        // live, 2026-07-11: "das Indikator Rechteck erscheint nie zwischen
        // Kacheln" — it wasn't misplaced, it was permanently stuck
        // collapsed with nothing able to ever activate it).
        //
        // Resting height stays 12pt (2026-07-11, second pass tried 28pt to
        // address "man muss den oberen Rand exakt treffen" — that DID
        // widen the hit area, but a taller RESTING frame is also a bigger
        // permanent gap between every tile even when nothing is being
        // dragged, which Lino explicitly rejected: "ich will keine
        // Abstände sondern die sollen breiter werden wenn ein Indikator
        // dazwischen rutscht"). Fixed properly instead by widening ONLY the
        // invisible hit-test region (contentShape, beyond the visible frame
        // on every side) without touching the frame itself — that costs
        // nothing in idle layout, since contentShape never contributes to a
        // view's own size. Combined with setSceneDropTarget's debounced-
        // clear (a genuine "moved away and stayed away" grace period, not
        // just a bigger boundary), that's the actual fix for "geht immer
        // auf und zu".
        //
        // Widened from 10pt to 50pt (2026-07-13, Lino: same "50%
        // oben/unten" precision he wanted from a drop-directly-on-the-tile
        // redesign) — deliberately NOT the drop-on-tile-with-CGPoint
        // architecture itself, which was already tried once in this exact
        // codebase and reverted (broke the tile's own long-press
        // .contextMenu on a real device via too many stacked gesture
        // recognizers, see swipeableCard's docs for the same class of
        // bug). This keeps the proven safe mechanism (gap-based
        // dropDestination, never on the tile itself) and just makes its
        // invisible catch zone generous enough that landing anywhere in
        // roughly the top/bottom half of a neighboring tile reaches it.
        return RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .frame(height: isActive ? 60 : 12)
            .padding(.horizontal, 4)
            .opacity(isActive ? 1 : 0)
            .contentShape(Rectangle().inset(by: -50))
            .dropDestination(for: String.self) { ids, _ in
                guard let raw = ids.first, raw.hasPrefix("scene:") else { return false }
                let draggedId = String(raw.dropFirst("scene:".count))
                Task { await viewModel.handleSceneDroppedOnTile(draggedId, targetScene: target) }
                return true
            } isTargeted: { targeted in
                setSceneDropTarget(target.id, targeted: targeted)
            }
    }

    /// `columnLayout` is true whenever this card renders inside a 2+ column
    /// grid (see sceneGrid) rather than the default single full-width
    /// column — at half (or less) width, sceneTile's normally-unlimited
    /// description/dialogue text wrapped into far more lines than in the
    /// single-column layout, and since LazyVGrid does NOT equalize row
    /// heights across cells the way a description list would, cards ended
    /// up wildly different heights depending on how much text each scene
    /// happened to have. See sceneTile's own columnLayout handling for the
    /// line-limit/fixed-height fix. The per-scene shot list + "Einstellung
    /// hinzufügen" row is hidden here too in that mode, for the same
    /// reason (an arbitrary number of shot cards would defeat any attempt
    /// at a uniform tile height) — full detail incl. shots is still one tap
    /// away via the edit sheet, same reasoning sceneCompactTile already uses.
    @ViewBuilder
    private func sceneCard(scene: Scene, columnLayout: Bool) -> some View {
        if scene.isProjectInfo {
            projectInfoSceneCard(scene: scene)
        } else {
            regularSceneCard(scene: scene, columnLayout: columnLayout)
        }
    }

    /// A "Projektinfo" tile (2026-07-11 redesign, see Scene.isProjectInfo) —
    /// reuses the ordinary scene drag/reorder/delete machinery (same
    /// .draggable/.dropDestination/.contextMenu shape as sceneTile below),
    /// but renders SceneProjectInfoTile's own content/chrome instead of a
    /// normal scene card — no image/priority/timer/shots/dialogue apply
    /// here, so none of sceneTile's/regularSceneCard's machinery for those
    /// is reused (would need its own padding/background double-applied on
    /// top of SceneProjectInfoTile's, which already looks like a tile).
    @ViewBuilder
    private func projectInfoSceneCard(scene: Scene, compactGrid: Bool = false) -> some View {
        // 2026-07-14: showsVisual/border-highlight follows the exact same
        // reasoning as sceneCompactTile's own drop indicator — see its doc
        // comment. This tile was missing that treatment even though it
        // renders inside the very same 2-column compact grid.
        VStack(alignment: .leading, spacing: 14) {
            sceneDropIndicator(before: scene, showsVisual: !compactGrid)
            SceneProjectInfoTile(viewModel: viewModel, scene: scene, projectId: projectId, compactGrid: compactGrid)
        }
        .padding(.horizontal, ((isPad && isGridMode) || horizontalSizeClass == .regular) ? 0 : 16)
        .overlay {
            if compactGrid && dropTargetSceneId == scene.id {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        // 2026-07-14: was a plain .contextMenu { } stacked directly with
        // .draggable() below — the same broken combination already found
        // and fixed on ProjectListView's project/folder tiles and
        // diagnosed originally on ShotListView's own scene tiles (see
        // sceneToDelete's doc comment): a bare .contextMenu's default
        // auto-preview competes with .draggable's long-press recognizer,
        // which can silently kill dragging. This tile — shown inside the
        // very same 2-column compact grid as sceneCompactTile — never got
        // the .contextMenu(menuItems:preview:) fix those other two did.
        .contextMenu {
            Button(role: .destructive) {
                sceneToDelete = scene
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        } preview: {
            Label("Info", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .draggable("scene:\(scene.id)") {
            Label("Info", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        // No dropDestination on this tile itself anymore (2026-07-11) —
        // reordering/refiling a Projektinfo tile goes through
        // sceneDropIndicator's own dropDestination exclusively now (the
        // gap above this tile, not the tile), same as regularSceneCard/
        // sceneCompactTile.
    }

    @ViewBuilder
    private func regularSceneCard(scene: Scene, columnLayout: Bool) -> some View {
        let collapsed = isCollapsed(scene)
        // Indicator is a SIBLING of the card now, not a child sharing its
        // background/clipShape (2026-07-11: "das blaue Rechteck wird beim
        // Verschieben immer IN EINER KACHEL dargestellt, es muss aber
        // zwischen Kacheln... dargestellt werden") — it used to be the
        // first child INSIDE the same VStack the card's own
        // .background()/.clipShape(RoundedRectangle) applied to, so it
        // visually rendered as part of that one tile's own rounded card
        // instead of a distinct placeholder sitting in the gap before it.
        VStack(alignment: .leading, spacing: 8) {
            sceneDropIndicator(before: scene)
            // swipeableCard wraps OUTSIDE the card's own glassEffect/
            // contextMenu/draggable stack (see its own doc comment) so the
            // whole card — background included — moves together, same as
            // Tinder, without touching the gesture stack living further in.
            swipeableCard(scene: scene) {
            VStack(alignment: .leading, spacing: 14) {
                if collapsed {
                    sceneCollapsedRow(scene: scene)
                } else {
                    sceneTile(scene: scene, columnLayout: columnLayout, suppressDrag: swipingSceneIds.contains(scene.id))
                    // Zwischenschritt: no shot list at all, not even the add-row
                    // — it's a lightweight connective beat, not a shootable
                    // scene. Also hidden while collapsed above, along with
                    // everything else — a collapsed "im Kasten" row is meant to
                    // be a one-line summary, not a partial card.
                    if !scene.isIntermediateStep, !columnLayout {
                        let shots = viewModel.shots(in: scene)
                        if !shots.isEmpty {
                            // Same collapsible-header idea as "Beschreibung"/
                            // "Dialog" above (Lino: "die Einstellungen muss
                            // man dann aber auch auf und zuklappen können"),
                            // mirrors the web app's shots-list collapse.
                            let shotsCollapsed = collapsedShotsSceneIds.contains(scene.id)
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if shotsCollapsed {
                                        collapsedShotsSceneIds.remove(scene.id)
                                    } else {
                                        collapsedShotsSceneIds.insert(scene.id)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text("Einstellungen")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(shots.count)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(shotsCollapsed ? 0 : 90))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if !shotsCollapsed {
                                ForEach(shots) { shot in
                                    shotCardView(shot: shot, sceneId: scene.id)
                                }
                            }
                        }
                        addRow(sceneId: scene.id)
                    }
                }
            }
            .padding(collapsed ? 10 : 14)
            // Real Apple "Liquid Glass" material (iOS 26), not an imitation
            // via gradients/blur — deliberately a DIFFERENT look than the
            // folder/project tiles' opaque colored-glow treatment
            // (ProjectListView.tileBody): Lino explicitly asked for "den
            // typischen schaumigen Glaseffekt mit Glaskanten, typische
            // Apple" on scene cards specifically, not the same effect
            // reused. glassEffect(in:) supplies its own frosted background,
            // refractive edge highlight, AND shape/clipping all at once —
            // no separate .background()/.clipShape() needed underneath.
            .glassEffect(scene.completed ? .regular.tint(.green.opacity(0.35)) : .regular, in: RoundedRectangle(cornerRadius: 16))
            .animation(.easeInOut(duration: 0.3), value: scene.completed)
            .animation(.easeInOut(duration: 0.25), value: collapsed)
            .modifier(ScenePulseOnElapse(scene: scene))
            .modifier(SceneTimerRunningGlow(scene: scene))
            }
        }
        // Grid mode owns its own outer horizontal padding + inter-column gap
        // (see sceneGrid) — a card shouldn't also pad itself in that case, or
        // the gap between the two columns would be twice as wide as the gap
        // above/below.
        .padding(.horizontal, ((isPad && isGridMode) || horizontalSizeClass == .regular) ? 0 : 16)
        // No dropDestination here anymore (2026-07-11) — this view wraps
        // AROUND sceneTile (nested, not siblings — see the VStack above),
        // and sceneTile has its OWN .contextMenu/.draggable/.dropDestination
        // for scene reordering. Stacking a SECOND, independent drop
        // interaction on the ENCLOSING view on top of that turned out to be
        // a real problem on-device, not just a "which one wins the drop"
        // ambiguity: reported live as long-press/.contextMenu itself no
        // longer responding AT ALL, even after fixing the drop-swallowing
        // issue this used to have (a Bool-returning dropDestination should
        // in principle coexist fine with an inner one, but two nested
        // UIDropInteraction-backed recognizers plus a UIContextMenuInteraction
        // plus a UIDragInteraction all stacked across two view levels in the
        // same touch region is exactly the kind of thing that can silently
        // break UIKit gesture arbitration in ways that don't show up from
        // reading the SwiftUI code). Filing a shot into this scene by drag
        // now goes through sceneTile's own single dropDestination instead
        // (see its own doc comment) — one recognizer per tile, not two.
    }

    /// See swipeableCard's 2026-07-15 "fourth attempt" doc comment for the
    /// full reasoning — .drawingGroup() only while actively mid-swipe,
    /// .compositingGroup() (safe, already-shipped baseline) the rest of the
    /// time, so the Liquid Glass look is never at risk for a card sitting
    /// still in the list.
    private struct SwipeCompositingModifier: ViewModifier {
        let isSwiping: Bool
        func body(content: Content) -> some View {
            if isSwiping {
                content.drawingGroup()
            } else {
                content.compositingGroup()
            }
        }
    }

    /// Tinder-style swipe wrapper — used by regularSceneCard only (2026-07-13,
    /// Lino: "den swipe effect brauchen wir nur bei der 'einzel kachel'
    /// ansicht!" — deliberately NOT the 2-column compact grid). See
    /// sceneSwipeOffsets' doc comment for the full risk/reasoning writeup.
    /// Applies the horizontal offset/rotation/exit-fade to whatever
    /// `content` is (the card's own glass background moves WITH it, same
    /// as Tinder — this wraps OUTSIDE the card's own
    /// .glassEffect()/.contextMenu()/.draggable() stack, not inside it).
    @ViewBuilder
    private func swipeableCard<Content: View>(scene: Scene, @ViewBuilder content: () -> Content) -> some View {
        let offset = sceneSwipeOffsets[scene.id] ?? 0
        let isExiting = sceneSwipeExiting.contains(scene.id)
        // Rotation capped at ±16° (2026-07-13, Lino: "die kachel verzieht und
        // vergrössert sich noch komplett komisch") — uncapped, a fast/long
        // swipe (easy to overshoot past the ~110pt threshold before letting
        // go) could rotate the card 20-30°+, and a rotated rectangle's
        // corners spill outside its own layout frame (SwiftUI doesn't
        // reserve extra space for that), which reads as the card bleeding
        // into/over its neighbors above and below in the list - not an
        // actual size change, but exactly what "vergrössert sich" describes.
        let rotation = max(-16, min(16, Double(offset) / 20))
        content()
            // 2026-07-14, third attempt — Lino finally pinned down the actual
            // visual precisely: "die kachel im hintergrund winkelt sich auch,
            // aber sie wird AUCH grösser, viel grösser" (the glass background
            // angles correctly, like the content, but ALSO grows much bigger
            // — two separate observations, not one). The 2026-07-13 rotation
            // cap and this session's two earlier attempts (suppressing
            // .draggable/.contextMenu during the swipe) all targeted GESTURE
            // conflicts or overflow-from-rotation, not this: content() here
            // already carries .glassEffect() (Liquid Glass, its own
            // blur/refraction compositing pass) plus ScenePulseOnElapse's
            // shadow and SceneTimerRunningGlow's blurred, padding(-20)
            // oversized background — several DIFFERENT visual-effect layers
            // that SwiftUI may recompute/resample independently as
            // .offset/.rotationEffect below animate, instead of transforming
            // one single already-rendered picture. .compositingGroup() is
            // the standard fix for exactly this class of bug: it forces
            // every effect above (glass, blur, shadow, opacity) to flatten
            // into ONE fixed-size rasterized layer at the content's own
            // (untransformed) size, so .offset/.rotationEffect afterward
            // rotate/move that single flat picture instead of letting any
            // individual effect's own rendering rescale mid-transform.
            //
            // 2026-07-15, FOURTH attempt — Lino confirmed compositingGroup()
            // alone made ZERO visible difference. UNVERIFIED (still no
            // Xcode/simulator here), reasoned guess: compositingGroup()
            // only flattens the LAYER TREE for compositing (correct
            // blend/opacity as one unit) but does NOT force a fixed-pixel
            // GPU raster — during a live, fast-changing DragGesture offset,
            // SwiftUI/UIKit can still resample a cached bitmap of that
            // flattened layer at the wrong scale while it's actively being
            // transformed, which would read as "grows" exactly during the
            // swipe. .drawingGroup() forces a real fixed-resolution Core
            // Image/Metal raster instead, which is the stronger, more
            // deterministic version of this fix.
            //
            // RISK, flagged explicitly per Lino's own call to try this
            // anyway (2026-07-15): .glassEffect() (Liquid Glass) samples
            // its backdrop live for the refraction look — .drawingGroup()
            // could in principle flatten that into a dead/opaque bitmap
            // instead, i.e. this fix could trade the swipe bug for a worse
            // one (glass effect breaking). Scoped to ONLY apply while
            // offset != 0 (i.e. only during an active swipe) specifically
            // to contain that risk to the brief moment a card is being
            // thrown, not to the list's normal at-rest appearance where the
            // glass look matters far more and for far longer.
            .modifier(SwipeCompositingModifier(isSwiping: offset != 0))
            .offset(x: offset)
            .rotationEffect(.degrees(rotation), anchor: .bottom)
            // Draws above its neighbors while actively being dragged, so the
            // now-smaller rotation overflow never gets visually clipped
            // behind/under the card above or below it in the list.
            .zIndex(offset == 0 ? 0 : 1)
            .opacity(isExiting ? 0 : 1)
            .overlay(alignment: .leading) {
                // Vertically centered (Lino, 2026-07-14: "muss immer
                // vertikal mittig erscheinen und nicht oben bei der
                // kachel") — was .topLeading, which pinned it to the
                // tile's top edge instead of the middle.
                if offset < -16 {
                    swipeStamp(text: "LÖSCHEN", systemImage: "trash.fill", color: .red, rotation: -12)
                        .opacity(min(1, Double(-offset) / 100))
                }
            }
            .overlay(alignment: .trailing) {
                if offset > 16 {
                    swipeStamp(text: "IM KASTEN", systemImage: "checkmark", color: .green, rotation: 12)
                        .opacity(min(1, Double(offset) / 100))
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        let h = value.translation.width
                        let v = value.translation.height
                        // Only react once the drag is CLEARLY more
                        // horizontal than vertical — anything ambiguous is
                        // left alone entirely (no state write at all) so a
                        // vertical scroll that starts on a card is never
                        // touched by this gesture in the first place.
                        guard abs(h) > abs(v) * 1.5 else { return }
                        sceneSwipeOffsets[scene.id] = h
                        // See swipingSceneIds' doc comment — this is the fix
                        // for the "card doubles/grows weirdly" bug: suppress
                        // sceneTile's own .draggable() for as long as we're
                        // clearly mid-swipe, so its system drag-lift preview
                        // never renders on top of this transform at the same
                        // time. Insert is idempotent, cheap to call every
                        // onChanged tick.
                        swipingSceneIds.insert(scene.id)
                    }
                    .onEnded { value in
                        let h = value.translation.width
                        let v = value.translation.height
                        guard abs(h) > abs(v) * 1.5 else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                sceneSwipeOffsets[scene.id] = 0
                            }
                            swipingSceneIds.remove(scene.id)
                            return
                        }
                        let threshold: CGFloat = 110
                        if h < -threshold {
                            // Immediate, no confirm dialog — the full-throw-
                            // off-screen animation itself IS the
                            // confirmation, exactly like Tinder's reject
                            // swipe. The long-press "Löschen" menu item
                            // still goes through the normal confirm dialog
                            // for anyone who prefers that safer path.
                            withAnimation(.easeIn(duration: 0.3)) {
                                sceneSwipeOffsets[scene.id] = -1000
                                sceneSwipeExiting.insert(scene.id)
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 280_000_000)
                                await viewModel.deleteScene(scene)
                                sceneSwipeOffsets[scene.id] = nil
                                sceneSwipeExiting.remove(scene.id)
                                swipingSceneIds.remove(scene.id)
                            }
                        } else if h > threshold {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                sceneSwipeOffsets[scene.id] = 0
                            }
                            Task { await viewModel.setSceneCompleted(scene, completed: true) }
                            swipingSceneIds.remove(scene.id)
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                sceneSwipeOffsets[scene.id] = 0
                            }
                            swipingSceneIds.remove(scene.id)
                        }
                    }
            )
    }

    /// A filled capsule + icon (2026-07-13, Lino: "den Text der erscheint
    /// schöner machen") — was a plain bordered rectangle of text, which read
    /// as a placeholder debug label rather than a deliberate Tinder-style
    /// like/reject stamp.
    private func swipeStamp(text: String, systemImage: String, color: Color, rotation: Double) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.gradient, in: Capsule())
            .shadow(color: color.opacity(0.5), radius: 10, y: 3)
            .rotationEffect(.degrees(rotation))
            .padding(18)
            .allowsHitTesting(false)
    }

    /// Collapsed "im Kasten" summary — just number/title/priority plus the
    /// start date if there is one, on the same green tint as the full card's
    /// completed background. Tap expands back to the full sceneTile (see
    /// isCollapsed/expandedCompletedSceneIds); editing still needs to work
    /// without expanding first, so it's reachable via long-press (.contextMenu)
    /// here too, same as the full tile once completed.
    @ViewBuilder
    private func sceneCollapsedRow(scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(scene.displayNumber)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(sceneAccentColor(scene.priority))
                    .clipShape(Capsule())
                Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !scene.isIntermediateStep, let priority = scene.priority {
                    Text(priority.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(sceneAccentColor(priority))
                        .clipShape(Capsule())
                }
            }
            if let scheduledAt = scene.scheduledAt {
                Text("Start: \(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) { _ = expandedCompletedSceneIds.insert(scene.id) }
        }
        .contextMenu {
            Button {
                editingScene = .some(scene)
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            Button {
                Task { await viewModel.setSceneCompleted(scene, completed: false) }
            } label: {
                Label("Nicht mehr im Kasten", systemImage: "arrow.uturn.backward")
            }
            Button {
                Task { await viewModel.duplicateScene(scene) }
            } label: {
                Label("Duplizieren", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                sceneToDelete = scene
            } label: {
                Label("Löschen", systemImage: "trash")
            }
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
    // suppressDrag now also suppresses .contextMenu (2026-07-14, second
    // attempt at the Tinder-swipe bug — see contextMenuIf's doc comment)
    // — name kept as-is to avoid touching every call site, but it really
    // means "suppress every OTHER gesture recognizer on this tile while a
    // swipe is active", not literally just drag anymore.
    @ViewBuilder
    private func sceneTile(scene: Scene, columnLayout: Bool = false, suppressDrag: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageUrl = scene.imageUrl {
                AsyncShotThumbnail(path: imageUrl, size: nil, lockAspectRatio: true)
                    .frame(maxWidth: .infinity)
                    // Fixed image height in column layout (same value
                    // sceneCompactTile already uses) — at half tile width the
                    // aspect-locked thumbnail would otherwise still vary in
                    // height card to card depending on the source photo's
                    // aspect ratio, working against "immer gleich gross".
                    .frame(height: columnLayout ? 100 : nil)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            sceneHeader(scene: scene)
            SceneTimerInfo(scene: scene)
            // Separates the header/timer block above from the content below —
            // always shown (not conditional on description existing) so the
            // card reads as two clearly separated zones at a glance.
            Divider().opacity(0.6)
            // Grouped into one Group so this whole block (up to 5 conditional
            // sub-views) counts as a single child of the outer VStack's
            // ViewBuilder — the outer VStack already has a header, timer, two
            // new dividers, and the bottom row as siblings, so ungrouped this
            // would push past ViewBuilder's per-block child limit.
            Group {
                // No lineLimit in the single-column layout — description/
                // dialogue show in full there, with whatever line breaks the
                // person typed. In column layout (2+ columns, see sceneCard)
                // the same amount of text wraps into far more lines at half
                // width, which is what made grid-mode cards balloon to wildly
                // different heights — capped here instead so every card in
                // that mode reaches a similar, predictable size (full detail
                // is always one tap away via the edit sheet regardless).
                if let description = scene.description, !description.isEmpty {
                    // Same collapsible-header idea as "Dialog" below (Lino:
                    // Titel "Beschreibung" darüber, auf-/zuklappbar wie bei
                    // Dialoge).
                    let descriptionCollapsed = collapsedDescriptionSceneIds.contains(scene.id)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if descriptionCollapsed {
                                collapsedDescriptionSceneIds.remove(scene.id)
                            } else {
                                collapsedDescriptionSceneIds.insert(scene.id)
                            }
                        }
                    } label: {
                        HStack {
                            Label("Beschreibung", systemImage: "text.alignleft")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(descriptionCollapsed ? 0 : 90))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !descriptionCollapsed {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(columnLayout ? 3 : nil)
                            .fixedSize(horizontal: false, vertical: !columnLayout)
                    }
                }
                if let description = scene.description, !description.isEmpty,
                   let dialogue = scene.dialogue, !dialogue.isEmpty {
                    Divider()
                }
                if let dialogue = scene.dialogue, !dialogue.isEmpty {
                    Label(dialogue, systemImage: "quote.bubble")
                        .font(.subheadline.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(columnLayout ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: !columnLayout)
                }
                // Individually-checkable dialogue lines, stacked under the
                // legacy single-dialogue field above — read-only here on
                // purpose. Adding a new line only happens in SceneEditSheet
                // (tap into the scene first) so the main tile isn't cluttered
                // with an inline text field; this list just shows what's
                // already there so it can be checked off without opening the
                // sheet. Capped to the first 2 in column layout, same
                // reasoning as description/dialogue above.
                if !scene.isIntermediateStep, !scene.dialogues.isEmpty {
                    let dialogCollapsed = collapsedDialogSceneIds.contains(scene.id)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if dialogCollapsed {
                                collapsedDialogSceneIds.remove(scene.id)
                            } else {
                                collapsedDialogSceneIds.insert(scene.id)
                            }
                        }
                    } label: {
                        HStack {
                            Label("Dialog", systemImage: "quote.bubble")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("\(scene.dialogues.count)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(dialogCollapsed ? 0 : 90))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !dialogCollapsed {
                        ForEach(Array((columnLayout ? Array(scene.dialogues.prefix(2)) : scene.dialogues).enumerated()), id: \.element.id) { index, dialogue in
                            dialogueRow(dialogue: dialogue, scene: scene, colorIndex: index)
                        }
                        if columnLayout && scene.dialogues.count > 2 {
                            Text("+\(scene.dialogues.count - 2) weitere")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let address = scene.locationAddress, let lat = scene.locationLat, let lng = scene.locationLng {
                    HStack(spacing: 10) {
                        SceneMapThumbnail(lat: lat, lng: lng, size: 56)
                        // 2026-07-14, Lino: "adressen text soll immer
                        // linksbündig sein" — explicit leading alignment +
                        // a full-width leading frame, so a wrapped 2-line
                        // address can't end up reading as centered/ragged
                        // next to the fixed-width map thumbnail.
                        Text(address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            // Separates the content above from the bottom action row below —
            // reads as its own little strip (good take / assignee / im Kasten).
            Divider().opacity(0.6)
            // Good Take (left) / assignee (center) / "Im Kasten" (right) — two
            // spacers distribute the three roughly evenly instead of clumping
            // assignee+imKasten together at the trailing edge.
            HStack(spacing: 8) {
                if !scene.isIntermediateStep {
                    sceneGoodTakeButton(scene: scene)
                }
                Spacer()
                sceneAssigneeMenu(scene: scene)
                Spacer()
                imKastenButton(scene: scene)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // A completed scene shown expanded (the user tapped its
            // collapsed row to peek) taps back to collapsed instead of
            // opening the edit sheet — editing it goes through the
            // long-press menu below instead, same as the collapsed row.
            if scene.completed {
                withAnimation(.easeInOut(duration: 0.25)) { _ = expandedCompletedSceneIds.remove(scene.id) }
            } else {
                editingScene = .some(scene)
            }
        }
        .contextMenuIf(!suppressDrag, menuItems: {
            Button {
                editingScene = .some(scene)
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            if scene.completed {
                Button {
                    Task { await viewModel.setSceneCompleted(scene, completed: false) }
                } label: {
                    Label("Nicht mehr im Kasten", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                Task { await viewModel.duplicateScene(scene) }
            } label: {
                Label("Duplizieren", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                sceneToDelete = scene
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }, preview: {
            sceneContextMenuPreview(scene: scene)
        })
        .draggableIf(!suppressDrag, "scene:\(scene.id)") {
            sceneDragPreview(scene: scene)
        }
        // Handles a SHOT being filed into this scene (unprefixed id), PLUS
        // a Projektinfo scene being refiled into THIS scene's section
        // specifically (2026-07-11: "die Projektinfo kann man wieder in
        // keinen Abschnitt schieben" — the thin indicator gap and the
        // section header were technically both still valid targets, but
        // evidently too easy to miss in practice) — so ANY tile already in
        // the target section is a perfectly valid, much larger, much
        // easier-to-hit place to drop an Info tile onto, landing right
        // before whichever tile it's dropped on (handleSceneDroppedOnTile
        // positions it exactly like any other scene now — see its own
        // updated doc comment — this is purely a wider TARGET, not
        // just the header or the gap). Deliberately NOT extended to
        // regular (non-Projektinfo) scene drags — those still need exact
        // position, which only the indicator gap can express; broadening
        // this to accept ALL scene reordering here again would resurrect
        // the earlier nested-dropDestination gesture-conflict bug this
        // same view already had fixed for it once today.
        .dropDestination(for: String.self) { ids, _ in
            guard let raw = ids.first else { return false }
            if raw.hasPrefix("scene:") {
                let draggedId = String(raw.dropFirst("scene:".count))
                guard let dragged = viewModel.scenes.first(where: { $0.id == draggedId }), dragged.isProjectInfo else { return false }
                Task { await viewModel.handleSceneDroppedOnTile(draggedId, targetScene: scene) }
                return true
            }
            Task { await viewModel.moveShot(raw, toScene: scene.id) }
            return true
        }
    }

    /// Reduced-info counterpart to sceneTile for isCompactTileMode — photo,
    /// number/title/priority, and the timer only. Deliberately leaves out
    /// dialogues, address, good take, and assignee (all still one tap away:
    /// tapping the tile opens the same edit sheet as the full card) so a
    /// 2-column grid of these reads as a fast visual overview, not a smaller
    /// version of the same dense card. Reuses SceneTimerInfo/ScenePulseOnElapse
    /// as-is rather than duplicating the countdown/elapse logic.
    @ViewBuilder
    private func sceneCompactTile(scene: Scene) -> some View {
        // Indicator pulled out into a sibling, same reasoning as
        // regularSceneCard's own restructure — see its doc comment. Used
        // to be the first child inside the SAME VStack the tile's own
        // .background()/.clipShape() applied to, so it rendered as part of
        // that tile's own card instead of a distinct placeholder in the
        // gap before it.
        VStack(alignment: .leading, spacing: 6) {
            sceneDropIndicator(before: scene, showsVisual: false)
            // No swipeableCard here (2026-07-13, Lino: "den swipe effect
            // brauchen wir nur bei der 'einzel kachel' ansicht!") — Tinder-
            // swipe is single-column (regularSceneCard) only, deliberately
            // not the 2-column compact grid.
            VStack(alignment: .leading, spacing: 8) {
                if let imageUrl = scene.imageUrl {
                    AsyncShotThumbnail(path: imageUrl, size: nil, lockAspectRatio: true)
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                // "NICHTS ist IN einer Kachel nebeneinander, ALLES IST
                // UNTEREINANDER" (2026-07-11) still applies below — EXCEPT
                // this one row, which Lino explicitly asked to make an
                // exception for in the 2-column redesign ("Prio... rechts-
                // bündig zur Identifikationsnummer legen") — spelled-out
                // priority, right-aligned against the ID badge.
                HStack {
                    Text(scene.displayNumber)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(sceneAccentColor(scene.priority))
                        .clipShape(Capsule())
                    Spacer()
                    if let priority = scene.priority {
                        Text(priority.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sceneAccentColor(scene.priority))
                    }
                }
                Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                SceneTimerInfo(scene: scene, stacked: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same Liquid Glass material as regularSceneCard — see its doc
            // comment for why this differs from the folder/project tiles'
            // treatment.
            .glassEffect(scene.completed ? .regular.tint(.green.opacity(0.35)) : .regular, in: RoundedRectangle(cornerRadius: 14))
            .modifier(ScenePulseOnElapse(scene: scene))
            .modifier(SceneTimerRunningGlow(scene: scene))
            // Uniform card size across the 2-column grid, format 4:5 (Lino:
            // "jede Kachel die gleiche Grösse in der Höhe... Format von
            // 4:5"). .fit against a fixed grid-column width fixes the
            // height identically for every card in the common case. NOT
            // combined with .clipped() — a scene with an unusually long
            // 2-line name + full timer info could still need more than the
            // strict 4:5 height, and silently cutting text off mid-word
            // would be a worse failure mode than that one tile being
            // marginally taller than its neighbors. Worth an on-device
            // check with a deliberately long scene name.
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .contentShape(Rectangle())
            // Edge-agnostic drop highlight replacing sceneDropIndicator's
            // (now invisible in this mode, see showsVisual above) dashed
            // rectangle — border around the actual target tile makes sense
            // regardless of which column it's in, unlike a gap growing only
            // above one cell.
            .overlay {
                if dropTargetSceneId == scene.id {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .onTapGesture { editingScene = .some(scene) }
            .contextMenu {
                Button {
                    editingScene = .some(scene)
                } label: {
                    Label("Bearbeiten", systemImage: "pencil")
                }
                Button {
                    Task { await viewModel.duplicateScene(scene) }
                } label: {
                    Label("Duplizieren", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    sceneToDelete = scene
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            } preview: {
                sceneContextMenuPreview(scene: scene)
            }
            .draggable("scene:\(scene.id)") {
                sceneDragPreview(scene: scene)
            }
            // No dropDestination here anymore (2026-07-11) — reordering
            // moved to sceneDropIndicator's own dropDestination exclusively
            // (the gap before a tile). Compact tiles never showed a shot
            // list to file a shot into either, so there's nothing left for
            // this view itself to accept as a drop.
        }
    }

    /// Preview shown while holding for the Bearbeiten/Löschen menu — used to
    /// reuse sceneDragPreview (the small pill below), which visually read as
    /// the whole tile shrinking down into that pill the instant you started
    /// holding ("die Kachel soll sich dann nicht zusammenklappen, sondern
    /// einfach so bleiben", 2026-07-11). Mirrors the tile's own top section
    /// (image/header/timer) at natural width instead, so holding reads as a
    /// subtle lift, not a squash. Deliberately not the WHOLE card (shot
    /// list/dialogue/etc.) — a contextMenu preview isn't scrollable, so it
    /// stays to the identifying portion, same amount of content the
    /// collapsed row already shows.
    @ViewBuilder
    private func sceneContextMenuPreview(scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageUrl = scene.imageUrl {
                AsyncShotThumbnail(path: imageUrl, size: nil, lockAspectRatio: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            sceneHeader(scene: scene)
            SceneTimerInfo(scene: scene)
        }
        .padding(14)
        .frame(width: 320)
        .background(scene.completed ? Color.green.opacity(0.18) : Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
        HStack(alignment: .top, spacing: 8) {
            Text(scene.displayNumber)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(sceneAccentColor(scene.priority))
                .clipShape(Capsule())
            Text(scene.name?.isEmpty == false ? scene.name! : "Unbenannte Szene")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            if !scene.isIntermediateStep, let priority = scene.priority {
                Text(priority.label)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(sceneAccentColor(priority))
                    .clipShape(Capsule())
            }
        }
    }

    /// Responsible person for this scene — same quick Menu pattern as todo
    /// item assignment (ProjectInfoBox.TodoItemRow), not tucked into the full
    /// edit sheet, so setting/changing it is a one-tap action from the list.
    @ViewBuilder
    /// 2026-07-14, Lino: "mehrere Personen auswählen können und auch wieder
    /// entfernen können" — opens SceneAssigneeSheet instead of a native
    /// Menu (which auto-dismisses on every tap, so it can't stay open
    /// across multiple picks/removals — see assigneeSheetScene's doc
    /// comment). Trigger shows an overlapping avatar stack, same idea as
    /// web's SceneCard.tsx.
    private func sceneAssigneeMenu(scene: Scene) -> some View {
        let assignees = viewModel.members.filter { scene.assigneeIds.contains($0.userId) }
        Button {
            assigneeSheetScene = scene
        } label: {
            if assignees.isEmpty {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: -12) {
                    ForEach(assignees.prefix(3)) { member in
                        MemberAvatar(member: member, size: 32)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    }
                    if assignees.count > 3 {
                        Text("+\(assignees.count - 3)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// "Im Kasten" ("it's a wrap" — scene fully shot): tapping it toggles
    /// `completed`, which tints the whole card green and collapses it to
    /// sceneCollapsedRow in place (see isCollapsed/sceneCard) — it used to
    /// also move the scene to the end of the list, removed since it made
    /// the list jump around mid-scroll while checking scenes off on set.
    /// A plain Button nested here so its tap takes priority over the
    /// surrounding tile's own onTapGesture/draggable.
    @ViewBuilder
    private func imKastenButton(scene: Scene) -> some View {
        Button {
            Task { await viewModel.setSceneCompleted(scene, completed: !scene.completed) }
        } label: {
            Label("Im Kasten", systemImage: scene.completed ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(scene.completed ? Color.green.opacity(0.25) : Color(.tertiarySystemGroupedBackground))
                .foregroundStyle(scene.completed ? .green : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: scene.completed)
    }

    /// Good-take filename entry, always on the scene's own main tile — lives
    /// on the scene itself (not a shot), so it's there whether the scene has
    /// zero, one, or several shots. A shot's own detail sheet has its own
    /// separate good-take field for per-shot logging; this one is the
    /// scene-level "the take we're keeping" note.
    @ViewBuilder
    private func sceneGoodTakeButton(scene: Scene) -> some View {
        let hasGoodTake = scene.goodTakeFilename?.isEmpty == false
        Button {
            goodTakeText = scene.goodTakeFilename ?? ""
            editingGoodTakeScene = scene
        } label: {
            Label(hasGoodTake ? scene.goodTakeFilename! : "Good Take", systemImage: "sdcard.fill")
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(hasGoodTake ? Color.green.opacity(0.25) : Color(.tertiarySystemGroupedBackground))
                .foregroundStyle(hasGoodTake ? .green : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shotCardView(shot: Shot, sceneId: String?) -> some View {
        ShotCard(shot: shot) {
            Task { await viewModel.toggleDone(shot) }
        }
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

    /// One checkable spoken line — tapping the checkmark marks it recorded
    /// (strikethrough), long-press to remove it entirely.
    @ViewBuilder
    private func dialogueRow(dialogue: SceneDialogue, scene: Scene, colorIndex: Int) -> some View {
        // 2026-07-14, Lino: "in der web app haben wir die dialoge ja
        // farblich unterschieden, dies auch auf der ios app umsetzen" —
        // mirrors SceneCard.tsx exactly: cycle the shared subshotPalette by
        // line INDEX (not per-speaker, SceneDialogue has no speaker field),
        // just enough to tell consecutive lines apart at a glance. Same
        // ~8%-fill / ~50%-border opacities as web's `${lineColor}14` /
        // `${lineColor}80` hex-alpha suffixes.
        let lineColor = Color(hex: Color.subshotPalette[colorIndex % Color.subshotPalette.count])
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.toggleDialogue(dialogue, in: scene) }
            } label: {
                Image(systemName: dialogue.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(dialogue.done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            Text(dialogue.text)
                .font(.subheadline.italic())
                .foregroundStyle(.secondary)
                .strikethrough(dialogue.done)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(lineColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(lineColor.opacity(0.5))
                .frame(width: 2)
        }
        .contextMenu {
            Button {
                editingDialogueText = dialogue.text
                editingDialogue = (dialogue, scene)
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await viewModel.deleteDialogue(dialogue, in: scene) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
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
        let text = newShotText
        newShotText = ""
        // 2026-07-14, Lino: "sobald man der einstellung einen namen gegeben
        // hat" muss die kamera-info direkt eingebbar sein — straight into
        // ShotDetailSheet (same sheet as tapping an existing shot, see
        // selectedShot above) right after naming it, instead of leaving the
        // user to find and reopen it later just to add camera settings.
        if let shot = await viewModel.createShot(description: text, sceneId: sceneId) {
            selectedShot = shot
        }
    }

    /// Downloads the project's PDF once and caches it at a temp URL — the
    /// toolbar swaps to a `ShareLink` for that URL afterward so re-tapping
    /// doesn't re-download; `.task`/`.onDisappear` isn't used to invalidate
    /// it since a stale PDF from a few edits ago is harmless to re-share.
    private func exportPdf(view: String) async {
        isExportingPdf = true
        defer { isExportingPdf = false }
        do {
            let data = try await APIClient.shared.projectPdf(projectId, view: view)
            let safeName = projectName.isEmpty ? "shotlist" : projectName
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).pdf")
            try data.write(to: url, options: .atomic)
            exportedPdfURL = url
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    /// Public, no-login link to this project's storyboard (see GET /share/
    /// {token} — server-rendered, responsive HTML, 7-day expiry). Server-side
    /// idempotent, so tapping this again later just extends the same link
    /// rather than creating a second, different URL to confuse whoever
    /// already has the first one.
}

/// Bundles the Abschnitt/Szene delete-confirmation alerts — pulled out of
/// ShotListView.body (see the `.modifier(TileActionDialogs(...))` call
/// there) purely to keep the compiler's job smaller; body was already a
/// long chain of sheets/alerts/toolbar/task modifiers on one expression,
/// and adding more inline pushed Xcode into "unable to type-check this
/// expression in reasonable time". The Bearbeiten/Löschen/Umbenennen menus
/// themselves are .contextMenu now, attached directly on each tile (see
/// sceneToDelete's doc comment in ShotListView for why) — only the actual
/// "really delete?" confirmation lives here.
private struct TileActionDialogs: ViewModifier {
    @ObservedObject var viewModel: ShotListViewModel
    @Binding var sectionToDelete: SceneSection?
    @Binding var sceneToDelete: Scene?

    func body(content: Content) -> some View {
        content
            .alert("Abschnitt löschen?", isPresented: Binding(
                get: { sectionToDelete != nil },
                set: { if !$0 { sectionToDelete = nil } }
            )) {
                Button("Abbrechen", role: .cancel) {}
                Button("Löschen", role: .destructive) {
                    if let section = sectionToDelete {
                        Task { await viewModel.deleteSection(section) }
                    }
                }
            } message: {
                Text(sectionDeleteMessage)
            }
            .alert("Szene löschen?", isPresented: Binding(
                get: { sceneToDelete != nil },
                set: { if !$0 { sceneToDelete = nil } }
            )) {
                Button("Abbrechen", role: .cancel) {}
                Button("Löschen", role: .destructive) {
                    if let scene = sceneToDelete {
                        Task { await viewModel.deleteScene(scene) }
                    }
                }
            } message: {
                Text(sceneDeleteMessage)
            }
    }

    // Scenes ARE deleted along with their section now (2026-07-11, Lino) —
    // backend deletes every Scene with this section_id (and their shots)
    // before deleting the section itself, no more falling back to "Ohne
    // Abschnitt". A section's own Projektinfo (Drehdatum/Ort/Todo-Listen)
    // was already deleted for good either way (TodoList.section_id is
    // ON DELETE CASCADE).
    private var sectionDeleteMessage: String {
        guard let section = sectionToDelete else { return "" }
        return "\"\(section.name)\" wird gelöscht. Jegliche Szenen oder Kacheln im Abschnitt werden auch gelöscht."
    }

    private var sceneDeleteMessage: String {
        let name = sceneToDelete?.name?.isEmpty == false ? sceneToDelete!.name! : "Unbenannte Szene"
        return "\"\(name)\" wird endgültig gelöscht, inklusive aller Einstellungen darin."
    }
}

/// Thin wrapper so the share sheet can be triggered programmatically
/// (`.sheet(isPresented:)`) the instant the link URL is ready — SwiftUI's own
/// `ShareLink` only presents in response to a tap on itself, which is exactly
/// what forced the old two-tap flow (tap to fetch the URL, tap again on the
/// now-swapped-in `ShareLink` to actually see the share sheet).
private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Storyboard-style card: big photo (if one's been added) on top, description
/// and metadata below — replaces the old compact list row so the picture
/// itself carries the weight, matching how a shot list is actually used on
/// set (glance at the frame, not the text).
private struct ShotCard: View {
    let shot: Shot
    /// Lets the checkmark itself toggle done/open directly — previously the
    /// only way to do that was the long-press context menu ("Erledigt"),
    /// with this same checkmark shown purely as a static status icon right
    /// next to it. A nested Button here takes tap priority over the card's
    /// own onTapGesture (which opens the full detail sheet), same pattern as
    /// the scene tile's "Im Kasten" button.
    var onToggleDone: () -> Void

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
                    Button(action: onToggleDone) {
                        Image(systemName: shot.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(shot.status == .done ? .green : .white)
                            .font(.title3)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)

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
                    Label("Good Take: \(goodTake)", systemImage: "sdcard.fill")
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
/// - before start: static "Geplante Zeit: Xmin"
/// - during [start, start+duration): live mm:ss countdown, grey more than
///   15min out, fading through yellow at 15min, red at 10min
/// - after end: "Drehzeit abgelaufen" — the one-time whole-card pulse on
///   crossing into this state lives on SceneCard's ScenePulseOnElapse,
///   not here.
private struct SceneTimerInfo: View {
    let scene: Scene
    /// True only in the 2-column compact tile overview (see
    /// sceneCompactTile) — date and planned/remaining time side-by-side in
    /// an HStack was reported as wrong specifically there ("NICHTS ist IN
    /// einer Kachel nebeneinander, ALLES IST UNTEREINANDER", 2026-07-11,
    /// asked for repeatedly) — a half-width compact tile has much less
    /// horizontal room than the full single-column card, where the HStack
    /// stays as-is (not requested/needed there).
    var stacked: Bool = false

    var body: some View {
        if let scheduledAt = scene.scheduledAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                let end = scene.durationMinutes.map { scheduledAt.addingTimeInterval(TimeInterval($0) * 60) }
                let isRunning = end.map { now >= scheduledAt && now < $0 } ?? false

                let startLabel = Label("Start: \(scheduledAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(isRunning ? Color.yellow : Color(.secondaryLabel))
                    .animation(.easeInOut(duration: 0.4), value: isRunning)

                let durationView: AnyView = {
                    guard let end else { return AnyView(EmptyView()) }
                    if now < scheduledAt {
                        return AnyView(
                            Label("Geplante Zeit: \(scene.durationMinutes.map { "\($0) Min." } ?? "")", systemImage: "timer")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        )
                    } else if isRunning {
                        return AnyView(LiveSceneBadge(remaining: end.timeIntervalSince(now)))
                    } else {
                        return AnyView(
                            Label("Drehzeit abgelaufen", systemImage: "timer")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        )
                    }
                }()

                if stacked {
                    VStack(alignment: .leading, spacing: 4) {
                        startLabel
                        durationView
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        startLabel
                        Spacer(minLength: 8)
                        durationView
                    }
                }
            }
        }
    }
}

/// Live mm:ss countdown while a scene is rolling — grey more than 15min from
/// the end, fading through yellow at the 15min mark, solid red from the 5min
/// mark on (previously only reached full red at 0 — now the whole badge also
/// pulses once it's solid red, not just the small "live" dot, so the last 5
/// minutes read as unmistakably urgent). The small white dot pulses
/// continuously the whole time as a general "live" indicator (unrelated to
/// the one-time whole-card pulse fired when the timer hits 0, see
/// ScenePulseOnElapse).
private struct LiveSceneBadge: View {
    let remaining: TimeInterval
    @State private var pulse = false

    private var isUrgent: Bool { remaining > 0 && remaining <= 300 }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.5 : 0.85)
                .opacity(pulse ? 0.35 : 1.0)
            Text("Verbleibend: \(Self.format(remaining))")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Self.color(for: remaining))
        .clipShape(Capsule())
        .scaleEffect(isUrgent && pulse ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.4), value: remaining <= 900)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private static func color(for remaining: TimeInterval) -> Color {
        if remaining <= 300 {
            return .red
        } else if remaining <= 600 {
            return Color.yellow.interpolated(to: .red, fraction: 1 - ((remaining - 300) / 300))
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
///
/// A spring (instead of the old linear easeInOut) gives the scale a natural
/// overshoot-and-settle instead of a hard snap back to 1.0, paired with a
/// brief red glow so the "pop" reads as an alert, not just a size change.
/// Also fires a haptic (vibration) at the exact same moment — the visual
/// pulse alone is easy to miss if the phone isn't being looked at right when
/// time runs out.
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
                    .scaleEffect(pulse ? 1.045 : 1.0)
                    .shadow(color: .red.opacity(pulse ? 0.4 : 0), radius: pulse ? 16 : 0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.55), value: pulse)
                    .onChange(of: context.date) { oldDate, newDate in
                        if oldDate < end && newDate >= end {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            pulse = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { pulse = false }
                        }
                    }
            }
        )
    }
}

/// Mirrors web's `useSceneTimerRunning` (SceneCard.tsx): true from
/// `scheduledAt` until `scheduledAt + durationMinutes`, re-checked every 15s
/// via TimelineView so the glow starts/stops on its own. Subtle white glow
/// OUTSIDE the tile edges only (large blur + negative padding so it never
/// overlaps the card's own content) — same restrained tuning as web
/// (opacity 0.06→0.18→0.06, 3.6s cycle) after Lino's "nur aussen glowen und
/// nicht so stark wie jetzt" correction.
private struct SceneTimerRunningGlow: ViewModifier {
    let scene: Scene
    @State private var pulse = false

    private func isRunning(at now: Date) -> Bool {
        guard !scene.completed,
              let start = scene.scheduledAt,
              let duration = scene.durationMinutes else { return false }
        let end = start.addingTimeInterval(TimeInterval(duration) * 60)
        return now >= start && now < end
    }

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let running = isRunning(at: context.date)
            content
                .background {
                    if running {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white)
                            .blur(radius: 20)
                            .padding(-20)
                            .opacity(pulse ? 0.18 : 0.06)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: running) { _, newValue in
                    if newValue {
                        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    } else {
                        pulse = false
                    }
                }
                .onAppear {
                    if running {
                        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                }
        }
    }
}

/// Multi-select "Zuständig" picker (2026-07-14, Lino: "mehrere Personen
/// auswählen können und auch wieder entfernen können") — a sheet instead of
/// a native Menu because SwiftUI's Menu dismisses on every Button tap with
/// no built-in way to keep it open across several picks, which a genuine
/// multi-select needs (tap several members, then explicitly close).
/// Was its own file (SceneAssigneeSheet.swift) — folded in here (2026-07-14)
/// after Xcode reported "Cannot find 'SceneAssigneeSheet' in scope", most
/// likely a target-membership gap for the new file rather than anything
/// wrong with its content; consolidating into this always-compiling file
/// removes that risk entirely rather than relying on Xcode picking up a
/// new file automatically.
struct SceneAssigneeSheet: View {
    let scene: Scene
    @ObservedObject var viewModel: ShotListViewModel
    @Environment(\.dismiss) private var dismiss

    /// Looks the scene up fresh from viewModel.scenes on every render
    /// instead of using the captured `scene` parameter directly — that
    /// parameter is a value-type snapshot from whenever the sheet was
    /// presented, so checkmarks would otherwise freeze at whatever the
    /// selection was at that moment instead of updating live as this same
    /// sheet session toggles members in/out.
    private var currentAssigneeIds: [String] {
        (viewModel.scenes.first { $0.id == scene.id } ?? scene).assigneeIds
    }

    var body: some View {
        NavigationStack {
            List(viewModel.members) { member in
                Button {
                    Task { await viewModel.toggleSceneAssignee(scene, userId: member.userId) }
                } label: {
                    HStack {
                        MemberAvatar(member: member, size: 32)
                        Text(member.name?.isEmpty == false ? member.name! : member.email)
                            .foregroundStyle(.primary)
                        Spacer()
                        if currentAssigneeIds.contains(member.userId) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary.opacity(0.4))
                        }
                    }
                }
            }
            .navigationTitle("Zuständig")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
