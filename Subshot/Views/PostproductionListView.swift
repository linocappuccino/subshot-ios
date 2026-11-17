import SwiftUI
import Combine
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// #11 Schritt 6 (Postproduction-Tracking) — eigener Bereich pro Projekt
/// (2026-07-17, Lino: eigener Tab statt Einbau in die bestehende
/// Szenenübersicht). Listet jede Section, die per "Ab in die
/// Postproduction"-Aktion (ShotListView's Section-Kontextmenü) explizit
/// dorthin geschickt wurde.
///
/// 2026-07-21, #284 — full overhaul, 2-column grid of video tiles
/// (mirrors web's VideoTile.tsx layout) replacing the old List of
/// expandable Section rows + VideoPanelView (see that file's own doc
/// comment — superseded, not deleted). One Section can have zero, one, or
/// several Videos (0-n per backend Video's own doc comment; several is
/// the "Hauptschnitt + Trailer" exception) — a Section with zero Videos
/// still gets exactly ONE placeholder tile so its upload slot exists at
/// all; a Section with N videos gets N tiles. Status/deadline are Section-
/// level fields (patch_section_postproduction) shared across every tile
/// under that Section; a Video's own `title` is the one per-TILE editable
/// field (PATCH /videos/{id}).
struct PostproductionListView: View {
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    /// See ShotListView.body's `switch activeWorkflowSection` (#283) —
    /// true when this is the inline third workflow page rather than the
    /// toolbar's own "checklist.checked" sheet shortcut.
    var embedded: Bool = false
    /// 2026-07-23 (#324) — set only when this screen was reached via a
    /// "video"-kind notification deep link (see ShotListView's
    /// pendingDeepLinkKind); consumed exactly once in the .task below,
    /// mirrors web's autoOpenVideoId in postproduction/page.tsx.
    var initialVideoId: String? = nil

    @State private var myRole: String?
    @State private var showingShareLinkSheet = false
    @State private var shareLinkURL: URL?
    @State private var isPresentingShareSheet = false

    /// One entry per Section. 2026-11-17 (b113): loaded with ONE call for the whole project
    /// (`GET /projects/{id}/videos`, like the web) and grouped by section.
    @State private var sectionVideos: [String: [Video]] = [:]
    /// 2026-10-12 — web parity: Fassungen + licences per video, technical check per version,
    /// feedback rounds per video (internal page only)
    @State private var extras: [String: VideoExtras] = [:]
    @State private var qc: [String: VideoQC] = [:]
    @State private var rounds: FeedbackRounds?
    @State private var qcFor: Video?
    @State private var isLoadingVideos = true
    @State private var didLoadVideosOnce = false
    @State private var errorMessage: String?

    // MARK: 2026-11-17 (b113) — languages, filters, selection, multi-upload (web parity)
    @State private var langs: PostproLanguagesOverview = .empty
    @State private var filter = PostproFilter()
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var showingBulkDelete = false
    @State private var showingBulkPlatform = false
    @State private var deletingLanguage: PostproLanguagesOverview.Language?
    /// «Neue Sprache» from a badge / the selection bar: these videos get the new language
    @State private var pendingAssignIds: [String]?
    @State private var showingLanguageCatalog = false
    @State private var toast: String?
    @State private var uploads: [PPUploadItem] = []
    @State private var showingMultiPhotoPicker = false
    @State private var multiPhotoItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    /// nil = new videos; set = a new version for this tile
    @State private var fileImportVersionTarget: PickerTarget?
    /// tile key → upload fraction 0…1
    @State private var uploadFractions: [String: Double] = [:]
    /// version ids where «Erneut versuchen» was tapped (the hint stays away for 6 min, like the web)
    @State private var retryingVersionIds: Set<String> = []
    /// running counter for the sort order of new unplanned sections (parallel uploads)
    @State private var nextSectionOrder: Int?

    /// Which (Section, optionally a specific already-existing Video)
    /// slot the PhotosPicker upload is for — captured at tap time so
    /// uploadPickedVideo knows exactly which Video row to attach the new
    /// version to (nil videoId = truly empty slot, create one first).
    struct PickerTarget: Equatable { let sectionId: String; let videoId: String? }
    @State private var pickerTarget: PickerTarget?
    /// 2026-07-26 (#334) — SAME target as `pickerTarget` above, captured a
    /// second time into an INDEPENDENT @State var: `.photosPicker`'s dismissal
    /// setter nils `pickerTarget` the instant an item is picked, racing with
    /// `.onChange(of: pickerItem)` below. This copy is never touched by that path.
    @State private var pendingUploadTarget: PickerTarget?
    @State private var pickerItem: PhotosPickerItem?
    /// Keyed by tile id (`video.id`, or `"empty-\(section.id)"` for a still-empty slot) — a Set so
    /// multiple tiles can be mid-upload at once without clobbering each other.
    @State private var uploadingTileIds: Set<String> = []
    /// 2026-08-08 — guards the initialVideoId auto-open so it only ever fires once.
    @State private var didAutoOpenInitialVideo = false

    private func tileKey(for target: PickerTarget) -> String {
        target.videoId ?? "empty-\(target.sectionId)"
    }

    /// Title-edit alert (2026-07-21, #284) — admin/Projektleiter only.
    @State private var editingTitleVideo: Video?
    @State private var editingTitleText = ""

    @State private var playing: (video: Video, version: VideoVersion)?

    private var sections: [SceneSection] { viewModel.sections.filter(\.inPostproduction) }
    /// Status stays broadly editable (any real project role) — matches the backend's own
    /// patch_section_postproduction gating; also the web's gate for languages, selection, bulk
    /// actions and uploads (`canEditStatus`).
    private var canEditStatus: Bool { myRole == "editor" || myRole == "projektleiter" || myRole == "owner" }
    private var canEditTitleAndDeadline: Bool { myRole == "projektleiter" || myRole == "owner" }

    static func statusLabel(_ status: PostproductionStatus, language: AppLanguage) -> String {
        switch status {
        case .wartend: return language.t("postproductionStatus.wartend")
        case .inBearbeitung: return language.t("postproductionStatus.inBearbeitung")
        case .wartetAufFeedback: return language.t("postproductionStatus.wartetAufFeedback")
        case .abgeschlossen: return language.t("postproductionStatus.abgeschlossen")
        case .abgelehnt: return language.t("postproductionStatus.abgelehnt")
        }
    }

    private struct Tile: Identifiable {
        let id: String
        let section: SceneSection
        let video: Video?
    }

    private var filterContext: PostproFilter.Context {
        PostproFilter.Context(assignments: langs.assignments, formats: langs.formats ?? [:])
    }

    /// ONE universe (the videos of the sections this page renders) for counters AND tiles (web)
    private var shownVideos: [Video] { sections.flatMap { sectionVideos[$0.id] ?? [] } }
    private var facets: PostproFilter.FacetCounts { filter.facetCounts(shownVideos, filterContext) }
    private var allVideosById: [String: Video] {
        Dictionary(sectionVideos.values.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var tiles: [Tile] {
        let ctx = filterContext
        return sections.flatMap { section -> [Tile] in
            let all = sectionVideos[section.id] ?? []
            let videos = filter.filter(all, ctx)
            // a filter shows only its videos (no empty upload boxes of other sections)
            if filter.isActive && videos.isEmpty && !uploadingTileIds.contains("empty-\(section.id)") { return [] }
            if all.isEmpty {
                return [Tile(id: "empty-\(section.id)", section: section, video: nil)]
            }
            return videos.map { Tile(id: $0.id, section: section, video: $0) }
        }
    }

    private var emptyFilterMessage: String? {
        guard filter.isActive, filter.filter(shownVideos, filterContext).isEmpty else { return nil }
        if filter.plat != "all" { return language.t("pp.emptyPlatform") }
        if filter.fmt != "all" { return language.t("pp.emptyFormat") }
        if filter.lang == "none" { return language.t("pp.emptyUnassigned") }
        return language.t("pp.emptyLanguage")
    }

    // MARK: - header (language tabs, format + platform chips, actions, upload list)

    @ViewBuilder
    private var filterHeader: some View {
        let fc = facets
        VStack(alignment: .leading, spacing: 10) {
            LanguageTabsRow(
                overview: langs,
                counts: fc.lang,
                tab: $filter.lang,
                editable: canEditStatus,
                onCreate: { name, flag in Task { await createLanguage(name: name, flag: flag, assign: nil) } },
                onRename: { id, name, flag in Task { await renameLanguage(id, name: name, flag: flag) } },
                onDelete: { deletingLanguage = $0 }
            )
            if !(fc.presentFmt.isEmpty && filter.fmt == "all") {
                FacetChipsRow(title: language.t("pp.format"), present: fc.presentFmt, counts: fc.fmt, tab: $filter.fmt, idPrefix: "pp.formatTab") { k in
                    AnyView(HStack(spacing: 5) {
                        FormatShapeIcon(format: k)
                        Text(k == "other" ? language.t("pp.formatOther") : k)
                    })
                }
            }
            if fc.presentPlat.contains(where: { $0 != "none" }) || filter.plat != "all" {
                FacetChipsRow(title: language.t("pp.platform"), present: fc.presentPlat, counts: fc.plat, tab: $filter.plat, idPrefix: "pp.platformTab") { k in
                    if let p = VideoPlatform(rawValue: k) {
                        return AnyView(HStack(spacing: 5) {
                            Image(p.imageName).resizable().scaledToFit().frame(width: 14, height: 14)
                            Text(p.name)
                        })
                    }
                    return AnyView(Text(language.t("pp.platformNoneChip")))
                }
            }
            if canEditStatus {
                HStack(spacing: 10) {
                    Button {
                        selecting.toggle()
                        if !selecting { picked = [] }
                    } label: {
                        Label(selecting ? language.t("pp.cancel") : language.t("pp.select"), systemImage: selecting ? "xmark.circle" : "checkmark.circle")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pp.selectToggle")
                    Spacer()
                    uploadMenu(compact: true)
                }
                .padding(.horizontal, 16)
            }
            if let emptyFilterMessage {
                Text(emptyFilterMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 16)
            }
            if !uploads.isEmpty {
                UploadQueueView(items: uploads)
            }
        }
        .padding(.top, 12)
    }

    private func uploadMenu(compact: Bool) -> some View {
        Menu {
            Section(language.t("pp.uploadHint")) {
                Button { showingMultiPhotoPicker = true } label: { Label(language.t("pp.fromPhotos"), systemImage: "photo.on.rectangle") }
                Button {
                    fileImportVersionTarget = nil
                    showingFileImporter = true
                } label: { Label(language.t("pp.fromFiles"), systemImage: "folder") }
            }
        } label: {
            if compact {
                Label(language.t("pp.uploadVideos"), systemImage: "arrow.up.circle.fill")
                    .font(.subheadline.weight(.semibold))
            } else {
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
        }
        .accessibilityIdentifier(compact ? "pp.uploadMenu" : "pp.uploadFab")
    }

    @ViewBuilder
    private var gridContent: some View {
        if isLoadingVideos && !didLoadVideosOnce {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty && uploads.isEmpty {
            ContentUnavailableView(
                language.t("postproductionListView.emptyTitle"),
                systemImage: "checklist",
                description: Text(language.t("postproductionListView.emptyDescription"))
            )
        } else {
            ScrollView {
                filterHeader
                // single full-width column (Lino 2026-08-05), 22 pt spacing (#331)
                LazyVGrid(columns: [GridItem(.flexible())], spacing: 22) {
                    ForEach(tiles) { tile in
                        tileView(tile)
                    }
                }
                .padding()
                .padding(.bottom, selecting ? 80 : 0)
            }
        }
    }

    private func tileView(_ tile: Tile) -> some View {
        let lang = tile.video.flatMap { v in langs.languages.first(where: { $0.id == langs.assignments[v.id] }) }
        return PostproductionVideoTile(
            section: tile.section,
            video: tile.video,
            members: viewModel.members,
            canEditStatus: canEditStatus,
            canEditTitleAndDeadline: canEditTitleAndDeadline,
            uploading: uploadingTileIds.contains(tile.id),
            onTapUpload: {
                let target = PickerTarget(sectionId: tile.section.id, videoId: tile.video?.id)
                pickerTarget = target
                pendingUploadTarget = target
            },
            onPlay: { video, version in playing = (video, version) },
            onEditTitle: {
                guard let video = tile.video else { return }
                editingTitleVideo = video
                editingTitleText = video.title
            },
            onStatusChange: { status in
                Task { await viewModel.patchSectionPostproduction(tile.section, status: status) }
            },
            onDeadlineChange: { date in
                if let date {
                    Task { await viewModel.patchSectionPostproduction(tile.section, deadline: date) }
                } else {
                    Task { await viewModel.patchSectionPostproduction(tile.section, clearDeadline: true) }
                }
            },
            onDeleteVideo: {
                if let video = tile.video {
                    Task { await deleteVideo(video) }
                }
            },
            onChangeAssignee: { userId in
                guard let video = tile.video else { return }
                Task { await updateVideoAssignee(video, sectionId: tile.section.id, userId: userId) }
            },
            onChangePlatforms: !canEditStatus ? nil : { platforms in
                guard let video = tile.video else { return }
                Task { await updateVideoPlatforms(video, sectionId: tile.section.id, platforms: platforms) }
            },
            extras: tile.video.map { extras[$0.id] ?? .empty },
            onExtrasChange: { x in if let id = tile.video?.id { extras[id] = x } },
            onError: { errorMessage = $0 },
            qc: tile.video.flatMap { v in v.versions.last(where: { $0.status == "ready" }).flatMap { qc[$0.id] } },
            onOpenQC: canEditStatus ? Optional({ qcFor = tile.video }) : nil,
            rounds: tile.video.flatMap { rounds?.videos[$0.id] },
            onSetRoundLimit: !canEditStatus ? nil : { (limit: Int?) in
                guard let id = tile.video?.id else { return }
                Task {
                    do { try await APIClient.shared.setVideoRoundLimit(videoId: id, limit: limit) } catch { errorMessage = error.localizedDescription }
                    rounds = try? await APIClient.shared.feedbackRounds(projectId: viewModel.projectId)
                }
            },
            languageBadge: tile.video.map { video in
                AnyView(HStack(spacing: 4) {
                    LanguageBadgeView(
                        current: lang,
                        languages: langs.languages,
                        onChange: canEditStatus ? Optional({ (lid: String?) in Task { await assignLanguage([video.id], lid) } }) : nil,
                        onNew: canEditStatus ? Optional({
                            pendingAssignIds = [video.id]
                            showingLanguageCatalog = true
                        }) : nil
                    )
                    if let f = langs.formats?[video.id] { SmallInfoBadge(text: f) }
                    if let v = video.versions.last(where: { $0.status == "ready" }), let w = v.width, let h = v.height {
                        SmallInfoBadge(text: "\(w) × \(h)")
                    }
                })
            },
            selecting: selecting && tile.video != nil,
            checked: tile.video.map { picked.contains($0.id) } ?? false,
            onToggleSelect: {
                guard let id = tile.video?.id else { return }
                if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
            },
            uploadFraction: uploadFractions[tile.id],
            onUploadVersion: !canEditStatus || tile.video == nil ? nil : { fromPhotos in
                let target = PickerTarget(sectionId: tile.section.id, videoId: tile.video?.id)
                if fromPhotos {
                    pickerTarget = target
                    pendingUploadTarget = target
                } else {
                    fileImportVersionTarget = target
                    showingFileImporter = true
                }
            },
            onReprocess: !canEditStatus ? nil : { versionId in
                retryingVersionIds.insert(versionId)
                Task {
                    do { try await APIClient.shared.reprocessVersion(versionId) } catch { errorMessage = error.localizedDescription }
                    try? await Task.sleep(nanoseconds: 360_000_000_000)
                    retryingVersionIds.remove(versionId)
                }
            },
            retrying: tile.video.map { v in v.versions.contains(where: { retryingVersionIds.contains($0.id) }) } ?? false
        )
    }

    // MARK: - selection bar (web: data-lang-selection)

    private var selectionBar: some View {
        let count = picked.count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Text(language.t("pp.selected").replacingOccurrences(of: "{n}", with: "\(count)"))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("pp.selectedCount")
                Divider().frame(height: 18)
                Menu {
                    ForEach(langs.languages) { l in
                        Button("\(l.flag) \(l.name)") {
                            let ids = Array(picked)
                            Task { await assignLanguage(ids, l.id); picked = [] }
                        }
                    }
                    Button(language.t("pp.noLanguage")) {
                        let ids = Array(picked)
                        Task { await assignLanguage(ids, nil); picked = [] }
                    }
                    Divider()
                    Button {
                        pendingAssignIds = Array(picked)
                        showingLanguageCatalog = true
                    } label: { Label(language.t("pp.newLanguage"), systemImage: "plus") }
                } label: {
                    barPill(language.t("pp.assignLanguage"), prominent: true)
                }
                .accessibilityIdentifier("pp.bulkLanguage")
                Menu {
                    ForEach(viewModel.members) { m in
                        let name = m.name?.isEmpty == false ? m.name! : m.email
                        Button(name) { Task { await bulkUpdate(.editor(m.userId), what: "\(language.t("pp.editor")): \(name)") } }
                    }
                    Button(language.t("pp.noEditor")) { Task { await bulkUpdate(.editor(nil), what: language.t("pp.noEditor")) } }
                } label: { barPill(language.t("pp.editor")) }
                .accessibilityIdentifier("pp.bulkEditor")
                Menu {
                    ForEach(PostproductionStatus.allCases, id: \.self) { s in
                        let label = Self.statusLabel(s, language: language)
                        Button(label) { Task { await bulkUpdate(.status(s), what: "\(language.t("pp.status")): \(label)") } }
                    }
                } label: { barPill(language.t("pp.status")) }
                .accessibilityIdentifier("pp.bulkStatus")
                Button { showingBulkPlatform = true } label: { barPill(language.t("pp.platform")) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pp.bulkPlatform")
                Button { showingBulkDelete = true } label: {
                    Text(language.t("pp.deleteN").replacingOccurrences(of: "{n}", with: "\(count)"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.red))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pp.bulkDelete")
                Button(language.t("pp.cancel")) {
                    picked = []
                    selecting = false
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func barPill(_ text: String, prominent: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(prominent ? Color.blue : Color.white.opacity(0.12)))
        .opacity(picked.isEmpty ? 0.4 : 1)
    }

    /// processing ids of the tiles still waiting for the server (thumbnail job), for the auto-refresh
    private var processingKey: String {
        let now = Date()
        return shownVideos.compactMap { v -> String? in
            if uploadingTileIds.contains(v.id) { return nil }
            if let last = v.versions.last, last.status == "uploading" { return v.id }
            guard let ready = v.versions.last(where: { $0.status == "ready" }), ready.thumbnailUrl == nil else { return nil }
            return PostproductionVideoTile.processingStuck(ready, now: now) ? nil : v.id
        }
        .sorted()
        .joined(separator: ",")
    }

    var body: some View {
        Group {
            if embedded {
                gridContent
            } else {
                NavigationStack {
                    gridContent
                        .navigationTitle(language.t("postproductionListView.navTitle"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(language.t("postproductionListView.doneButton")) { dismiss() }
                            }
                            if canEditStatus {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button {
                                        showingShareLinkSheet = true
                                    } label: {
                                        Image(systemName: "link")
                                    }
                                }
                            }
                        }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if canEditStatus && !selecting {
                uploadMenu(compact: false)
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if canEditStatus && selecting {
                selectionBar
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("pp.toast")
            }
        }
        .task(id: viewModel.members.map(\.userId)) {
            if let me = try? await APIClient.shared.me() {
                myRole = viewModel.members.first(where: { $0.userId == me.id })?.role
            }
        }
        // 2026-08-08 — `.task(id:)` re-runs whenever the section id list changes (sections are
        // loaded by the PARENT view, possibly after this view mounted).
        .task(id: sections.map(\.id)) {
            guard !sections.isEmpty else { return }
            await reloadVideos()
            await loadExtras()
            if !didAutoOpenInitialVideo, let initialVideoId,
               let video = sectionVideos.values.flatMap({ $0 }).first(where: { $0.id == initialVideoId }),
               let version = video.versions.last(where: { $0.status == "ready" }) {
                didAutoOpenInitialVideo = true
                playing = (video, version)
            }
        }
        // 2026-11-17 (b113) — live processing state: refresh every 5 s while a tile is still
        // «In Warteschlange» / «Wird verarbeitet» (web: pollForFilmstrip + data-processing-state)
        .task(id: processingKey) {
            guard !processingKey.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                await reloadVideos()
                await reloadLanguages()
            }
        }
        .onChange(of: filter) { _, _ in picked = [] }
        .sheet(item: $qcFor) { video in
            let version = video.versions.last(where: { $0.status == "ready" })
            QCSheet(title: video.title, qc: version.flatMap { qc[$0.id] }, versionId: version?.id) {
                guard let id = version?.id else { return }
                try? await APIClient.shared.rerunVideoQC(versionId: id)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await loadExtras()
            }
        }
        .photosPicker(
            isPresented: Binding(get: { pickerTarget != nil }, set: { if !$0 { pickerTarget = nil } }),
            selection: $pickerItem, matching: .videos
        )
        .onChange(of: pickerItem) { _, newItem in
            // 2026-07-26 (#334) — reads `pendingUploadTarget`, NOT `pickerTarget`.
            guard let newItem, let target = pendingUploadTarget else { return }
            pendingUploadTarget = nil
            pickerItem = nil
            Task { await uploadPickedVideo(.photo(newItem), target: target) }
        }
        .background(
            Color.clear
                .photosPicker(isPresented: $showingMultiPhotoPicker, selection: $multiPhotoItems, maxSelectionCount: nil, matching: .videos)
        )
        .onChange(of: multiPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            multiPhotoItems = []
            Task { await uploadMany(items.map { .photo($0) }) }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            if let target = fileImportVersionTarget {
                fileImportVersionTarget = nil
                Task { await uploadPickedVideo(.file(urls[0]), target: target) }
            } else {
                Task { await uploadMany(urls.map { .file($0) }) }
            }
        }
        .sheet(isPresented: $showingBulkPlatform) {
            BulkPlatformSheet { platforms, mode in
                let what = platforms.isEmpty ? language.t("pp.platformNoIcons")
                    : "\(language.t("pp.platform")): " + platforms.compactMap { VideoPlatform(rawValue: $0)?.name }.joined(separator: ", ")
                Task { await bulkUpdate(.platforms(platforms, mode: mode), what: what) }
            }
        }
        .sheet(isPresented: $showingLanguageCatalog) {
            LanguageCatalogSheet(existing: langs.languages.map(\.name)) { name, flag in
                let ids = pendingAssignIds
                pendingAssignIds = nil
                Task { await createLanguage(name: name, flag: flag, assign: ids) }
            }
        }
        .alert(
            picked.count == 1 ? language.t("pp.deleteTitle1") : language.t("pp.deleteTitleN").replacingOccurrences(of: "{n}", with: "\(picked.count)"),
            isPresented: $showingBulkDelete
        ) {
            Button(language.t("pp.deleteConfirm").replacingOccurrences(of: "{n}", with: "\(picked.count)"), role: .destructive) {
                Task { await bulkDelete() }
            }
            .accessibilityIdentifier("pp.bulkDeleteConfirm")
            Button(language.t("pp.cancel"), role: .cancel) {}
        } message: {
            Text(bulkDeleteMessage)
        }
        .alert(language.t("pp.editLanguage"), isPresented: Binding(get: { deletingLanguage != nil }, set: { if !$0 { deletingLanguage = nil } })) {
            Button(language.t("pp.deleteLanguage"), role: .destructive) {
                if let l = deletingLanguage { Task { await deleteLanguage(l) } }
            }
            Button(language.t("pp.cancel"), role: .cancel) {}
        } message: {
            Text(language.t("pp.deleteLanguageMessage").replacingOccurrences(of: "{name}", with: deletingLanguage?.name ?? ""))
        }
        .alert(language.t("postproductionListView.titleAlertTitle"), isPresented: Binding(
            get: { editingTitleVideo != nil },
            set: { if !$0 { editingTitleVideo = nil } }
        )) {
            TextField(language.t("postproductionListView.titleAlertTitle"), text: $editingTitleText)
            Button(language.t("postproductionListView.cancelButton"), role: .cancel) {}
            Button(language.t("postproductionListView.saveButton")) {
                if let video = editingTitleVideo {
                    Task { await renameVideo(video, title: editingTitleText) }
                }
            }
        }
        .sheet(isPresented: $showingShareLinkSheet) {
            ShareLinkSheet(projectId: viewModel.projectId, kind: "video") { url in
                shareLinkURL = url
                isPresentingShareSheet = true
            }
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            if let shareLinkURL {
                ActivityView(activityItems: [shareLinkURL])
            }
        }
        .fullScreenCover(item: Binding(
            get: { playing.map { PlayingPostproductionVideo(video: $0.video, version: $0.version) } },
            set: { if $0 == nil { playing = nil } }
        )) { item in
            VideoPlayerSheet(
                video: item.video,
                version: item.version,
                projectId: viewModel.projectId,
                sectionStatus: sections.first(where: { $0.id == item.video.sectionId })?.postproductionStatus,
                canEditStage: canEditStatus
            ) { updated in
                updateVersion(updated, videoId: item.video.id)
            }
        }
        .alert(language.t("postproductionListView.errorAlertTitle"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
    }

    private var bulkDeleteMessage: String {
        let titles: [String] = shownVideos.filter { picked.contains($0.id) }.map { "• " + $0.title }
        var lines: [String] = Array(titles.prefix(12))
        if titles.count > 12 { lines.append("…") }
        return lines.joined(separator: "\n") + "\n\n" + language.t("pp.deleteEmphasis")
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if toast == text { withAnimation { toast = nil } }
        }
    }

    // MARK: - data loading

    /// 2026-10-12 — Fassungen, technical check, feedback rounds (all extra info: failures stay silent)
    private func loadExtras() async {
        let pid = viewModel.projectId
        let target = UserDefaults.standard.object(forKey: "subshot.qcTarget.\(pid)") as? Double ?? -14
        async let x = try? APIClient.shared.videoExtras(projectId: pid)
        async let q = try? APIClient.shared.videoQC(projectId: pid, target: target)
        async let r = try? APIClient.shared.feedbackRounds(projectId: pid)
        async let l = try? APIClient.shared.projectLanguages(projectId: pid)
        if let x = await x, x != extras { extras = x }
        if let q = await q, q != qc { qc = q }
        if let r = await r, r != rounds { rounds = r }
        if let l = await l, l != langs { langs = l }
    }

    private func reloadLanguages() async {
        if let l = try? await APIClient.shared.projectLanguages(projectId: viewModel.projectId), l != langs { langs = l }
    }

    /// 2026-11-17 (b113) — ONE call for the whole project, grouped by section (web: listProjectVideos).
    /// Videos with an upload still running on this device are kept as they are locally, so a
    /// reload in the middle of an upload doesn't drop or reset their tile.
    private func reloadVideos() async {
        if !didLoadVideosOnce { isLoadingVideos = true }
        defer { isLoadingVideos = false }
        do {
            let all = try await APIClient.shared.listProjectVideos(projectId: viewModel.projectId)
            var bySection: [String: [Video]] = [:]
            for v in all { bySection[v.sectionId, default: []].append(v) }
            for (sid, list) in bySection { bySection[sid] = list.sorted { $0.sortOrder < $1.sortOrder } }
            for (sid, local) in sectionVideos {
                for v in local where uploadingTileIds.contains(v.id) {
                    if let i = bySection[sid]?.firstIndex(where: { $0.id == v.id }) { bySection[sid]?[i] = v } else { bySection[sid, default: []].append(v) }
                }
            }
            if bySection != sectionVideos { sectionVideos = bySection }
            didLoadVideosOnce = true
            // sections created elsewhere (plugin, MCP, web) — their videos must get a place too
            let known = Set(viewModel.sections.map(\.id))
            if all.contains(where: { !known.contains($0.sectionId) }) {
                await viewModel.load(resetGeneration: false, includeSecondary: false)
            }
        } catch {
            if !didLoadVideosOnce { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - languages

    private func assignLanguage(_ videoIds: [String], _ languageId: String?) async {
        guard !videoIds.isEmpty else { return }
        do {
            langs = try await APIClient.shared.assignVideoLanguages(projectId: viewModel.projectId, videoIds: videoIds, languageId: languageId)
        } catch {
            errorMessage = language.t("pp.assignFailed")
        }
    }

    private func createLanguage(name: String, flag: String, assign ids: [String]?) async {
        do {
            let before = Set(langs.languages.map(\.id))
            let next = try await APIClient.shared.createProjectLanguage(projectId: viewModel.projectId, name: name, flag: flag)
            langs = next
            if let made = next.languages.first(where: { !before.contains($0.id) }), let ids, !ids.isEmpty {
                await assignLanguage(ids, made.id)
                picked = []
            }
        } catch {
            errorMessage = language.t("pp.createLanguageFailed")
        }
    }

    private func renameLanguage(_ id: String, name: String, flag: String) async {
        do {
            langs = try await APIClient.shared.updateProjectLanguage(id, name: name, flag: flag)
        } catch {
            errorMessage = language.t("pp.saveFailed")
        }
    }

    private func deleteLanguage(_ l: PostproLanguagesOverview.Language) async {
        do {
            langs = try await APIClient.shared.deleteProjectLanguage(l.id)
            if filter.lang == l.id { filter.lang = "all" }
        } catch {
            errorMessage = language.t("pp.deleteLanguageFailed")
        }
    }

    // MARK: - bulk actions

    private func bulkUpdate(_ change: APIClient.BulkChange, what: String) async {
        let ids = Array(picked)
        guard !ids.isEmpty else { return }
        do {
            let r = try await APIClient.shared.bulkUpdateVideos(projectId: viewModel.projectId, videoIds: ids, change: change)
            if case .status(let status) = change {
                let byId = allVideosById
                let sids = Set(r.updated.compactMap { byId[$0]?.sectionId })
                for i in viewModel.sections.indices where sids.contains(viewModel.sections[i].id) {
                    viewModel.sections[i].postproductionStatus = status
                }
            }
            await reloadVideos()
            if let first = r.failed.first {
                errorMessage = language.t("pp.bulkPartial")
                    .replacingOccurrences(of: "{what}", with: what)
                    .replacingOccurrences(of: "{ok}", with: "\(r.updated.count)")
                    .replacingOccurrences(of: "{failed}", with: "\(r.failed.count)")
                    .replacingOccurrences(of: "{error}", with: first.error)
            } else {
                let key = r.updated.count == 1 ? "pp.bulkDone1" : "pp.bulkDoneN"
                showToast(language.t(key).replacingOccurrences(of: "{what}", with: what).replacingOccurrences(of: "{n}", with: "\(r.updated.count)"))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bulkDelete() async {
        let ids = Array(picked)
        guard !ids.isEmpty else { return }
        do {
            let r = try await APIClient.shared.bulkDeleteVideos(projectId: viewModel.projectId, videoIds: ids)
            let gone = Set(r.deleted.map(\.video_id))
            for (sid, list) in sectionVideos { sectionVideos[sid] = list.filter { !gone.contains($0.id) } }
            dropEmptyUnplannedSections()
            picked = []
            selecting = false
            await reloadLanguages()
            if !r.failed.isEmpty {
                errorMessage = language.t("pp.deletedPartial").replacingOccurrences(of: "{ok}", with: "\(r.deleted.count)").replacingOccurrences(of: "{failed}", with: "\(r.failed.count)")
            } else {
                showToast(r.deleted.count == 1 ? language.t("pp.deleted1") : language.t("pp.deletedN").replacingOccurrences(of: "{n}", with: "\(r.deleted.count)"))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// the server deletes an unplanned section with its last video — mirror it locally
    private func dropEmptyUnplannedSections() {
        viewModel.sections.removeAll { s in
            s.isUnplanned == true && s.inPostproduction && (sectionVideos[s.id] ?? []).isEmpty && !uploadingTileIds.contains("empty-\(s.id)")
        }
    }

    // MARK: - multi-upload (web: uploadMany) — every file = its own NEW video, title from the file
    // name, its own unplanned section, straight to R2, 3 at a time, progress + error per file

    private func uploadMany(_ sources: [PPUploadSource]) async {
        guard !sources.isEmpty else { return }
        let base = UUID().uuidString
        var queue: [(id: String, source: PPUploadSource)] = []
        var items: [PPUploadItem] = []
        for (i, s) in sources.enumerated() {
            let id = "\(base)-\(i)"
            let name: String
            switch s {
            case .file(let url): name = url.lastPathComponent
            case .photo: name = "\(language.t("pp.fromPhotos")) \(i + 1)"
            }
            items.append(PPUploadItem(id: id, name: name))
            queue.append((id, s))
        }
        uploads = uploads.filter { $0.state == .up || $0.state == .wait } + items
        if nextSectionOrder == nil { nextSectionOrder = (viewModel.sections.map(\.sortOrder).max() ?? -1) + 1 }
        let box = PPUploadQueue(queue)
        let workers = (0..<min(3, queue.count)).map { _ in Task { await uploadWorker(box) } }
        for w in workers { await w.value }
        await reloadLanguages()
    }

    private func setUpload(_ id: String, _ change: (inout PPUploadItem) -> Void) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        change(&uploads[i])
    }

    private func loadFile(_ source: PPUploadSource) async throws -> NamedMovieFile? {
        switch source {
        case .photo(let item):
            return try await item.loadTransferable(type: NamedMovieFile.self)
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try NamedMovieFile(copying: url)
        }
    }

    private func uploadWorker(_ queue: PPUploadQueue) async {
        while let item = queue.next() {
            let id = item.id
            let source = item.source
            setUpload(id) { $0.state = .up }
            let file: NamedMovieFile
            do {
                guard let f = try await loadFile(source) else {
                    setUpload(id) { $0.state = .error(language.t("postproductionListView.videoLoadFailed")) }
                    continue
                }
                file = f
            } catch {
                setUpload(id) { $0.state = .error(language.t("postproductionListView.videoLoadFailed")) }
                continue
            }
            setUpload(id) { $0.name = file.url.lastPathComponent }
            guard file.isVideo else {
                file.cleanUp()
                setUpload(id) { $0.state = .error(language.t("pp.notAVideo")) }
                continue
            }
            var createdSection: SceneSection?
            var createdVideo = false
            do {
                let title = file.title
                let order = nextSectionOrder ?? 0
                nextSectionOrder = order + 1
                let section = try await APIClient.shared.createSection(projectId: viewModel.projectId, name: title, sortOrder: order, startInPostproduction: true)
                createdSection = section
                let video = try await APIClient.shared.createVideo(sectionId: section.id, title: title, sortOrder: 0)
                createdVideo = true
                uploadingTileIds.insert(video.id)
                defer { uploadingTileIds.remove(video.id); uploadFractions[video.id] = nil }
                sectionVideos[section.id] = [video]
                viewModel.sections.append(section)
                // new videos land in the language tab that is open (else «Nicht zugeordnet»)
                if filter.lang != "all" && filter.lang != "none" {
                    await assignLanguage([video.id], filter.lang)
                }
                let completed = try await uploadFile(file, to: video.id, progress: { fraction in
                    setUpload(id) { $0.progress = fraction }
                    uploadFractions[video.id] = fraction
                })
                if let i = sectionVideos[section.id]?.firstIndex(where: { $0.id == video.id }) {
                    sectionVideos[section.id]?[i].versions.append(completed)
                }
                setUpload(id) { $0.state = .done; $0.progress = 1 }
            } catch {
                setUpload(id) { $0.state = .error(error.localizedDescription.isEmpty ? language.t("pp.createVideoFailed") : error.localizedDescription) }
                // a failed upload into a freshly created unplanned section must not leave an empty box
                if let s = createdSection {
                    try? await APIClient.shared.deleteSection(s.id)
                    viewModel.sections.removeAll { $0.id == s.id }
                    sectionVideos[s.id] = nil
                    _ = createdVideo
                }
            }
            file.cleanUp()
        }
    }

    /// version draft → R2 PUT with progress → complete (the same 3 steps as the web)
    private func uploadFile(_ file: NamedMovieFile, to videoId: String, progress: @escaping (Double) -> Void) async throws -> VideoVersion {
        let draft = try await APIClient.shared.createVideoVersion(videoId: videoId, filename: file.url.lastPathComponent, contentType: file.contentType)
        guard let s = draft.playbackUrl, let uploadURL = URL(string: s) else {
            throw APIError.server(status: 0, message: language.t("postproductionListView.noUploadUrl"))
        }
        try await APIClient.shared.uploadVideoFile(to: uploadURL, fileURL: file.url, contentType: file.contentType) { fraction in
            Task { @MainActor in progress(fraction) }
        }
        let fileSize = try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int
        let duration = try? await AVURLAsset(url: file.url).load(.duration).seconds
        return try await APIClient.shared.completeVideoVersion(draft.id, fileSizeBytes: fileSize, durationSeconds: duration)
    }

    // MARK: - single tile upload («Video hochladen» on an empty slot, «Neue Version hochladen»)

    private func uploadPickedVideo(_ source: PPUploadSource, target: PickerTarget) async {
        let key = tileKey(for: target)
        uploadingTileIds.insert(key)
        defer { uploadingTileIds.remove(key); uploadFractions[key] = nil }
        do {
            let video: Video
            let isNewVersion: Bool
            if let videoId = target.videoId, let existing = sectionVideos[target.sectionId]?.first(where: { $0.id == videoId }) {
                video = existing
                isNewVersion = existing.versions.contains(where: { $0.status == "ready" })
            } else if let firstExisting = sectionVideos[target.sectionId]?.first {
                video = firstExisting
                isNewVersion = false
            } else {
                video = try await APIClient.shared.createVideo(sectionId: target.sectionId, title: "Video", sortOrder: 0)
                sectionVideos[target.sectionId, default: []].append(video)
                isNewVersion = false
            }
            guard let file = try await loadFile(source) else {
                errorMessage = language.t("postproductionListView.videoLoadFailed")
                return
            }
            defer { file.cleanUp() }
            let completed = try await uploadFile(file, to: video.id) { fraction in uploadFractions[key] = fraction }
            if let index = sectionVideos[target.sectionId]?.firstIndex(where: { $0.id == video.id }) {
                sectionVideos[target.sectionId]?[index].versions.append(completed)
            }
            if isNewVersion { showToast(language.t("pp.versionUploaded")) }
            await reloadLanguages()
        } catch {
            errorMessage = error.localizedDescription.isEmpty ? language.t("pp.uploadFailed") : error.localizedDescription
        }
    }

    private func renameVideo(_ video: Video, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let updated = try await APIClient.shared.patchVideo(video.id, title: trimmed)
            if let index = sectionVideos[video.sectionId]?.firstIndex(where: { $0.id == video.id }) {
                sectionVideos[video.sectionId]?[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 2026-08-06 — long-press-on-thumbnail delete. Same scope as web's onDeleteVideo: only the
    /// Video itself (backend cascades to its VideoVersions/VideoComments).
    private func deleteVideo(_ video: Video) async {
        do {
            try await APIClient.shared.deleteVideo(video.id)
            sectionVideos[video.sectionId]?.removeAll { $0.id == video.id }
            dropEmptyUnplannedSections()
            await reloadLanguages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateVideoAssignee(_ video: Video, sectionId: String, userId: String?) async {
        do {
            let updated = try await APIClient.shared.patchVideo(video.id, assigneeId: userId, clearAssignee: userId == nil)
            if let index = sectionVideos[sectionId]?.firstIndex(where: { $0.id == updated.id }) {
                sectionVideos[sectionId]?[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 2026-11-16 — several platforms per video (web parity): the list is replaced as a whole.
    private func updateVideoPlatforms(_ video: Video, sectionId: String, platforms: [String]) async {
        do {
            let updated = try await APIClient.shared.patchVideoPlatforms(video.id, platforms: platforms)
            if let index = sectionVideos[sectionId]?.firstIndex(where: { $0.id == updated.id }) {
                sectionVideos[sectionId]?[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateVersion(_ updated: VideoVersion, videoId: String) {
        for (sectionId, videos) in sectionVideos {
            if let vIndex = videos.firstIndex(where: { $0.id == videoId }),
               let verIndex = videos[vIndex].versions.firstIndex(where: { $0.id == updated.id }) {
                sectionVideos[sectionId]?[vIndex].versions[verIndex] = updated
            }
        }
    }
}

private struct PlayingPostproductionVideo: Identifiable {
    let video: Video
    let version: VideoVersion
    var id: String { version.id }
}

/// One grid tile — empty (no Video uploaded for this Section slot yet,
/// or a Video row exists but has no ready version) or filled. Status/
/// deadline shown here are the ENCLOSING SECTION's (shared across every
/// tile under it, see this file's own top-of-file doc comment) — only
/// the title belongs to this specific Video.
private struct PostproductionVideoTile: View {
    @ObservedObject private var language = AppLanguage.shared
    let section: SceneSection
    let video: Video?
    let members: [Member]
    let canEditStatus: Bool
    let canEditTitleAndDeadline: Bool
    let uploading: Bool
    let onTapUpload: () -> Void
    let onPlay: (Video, VideoVersion) -> Void
    let onEditTitle: () -> Void
    let onStatusChange: (PostproductionStatus) -> Void
    let onDeadlineChange: (Date?) -> Void
    let onDeleteVideo: () -> Void
    /// 2026-08-08 — "kann der admin / projektleiter in der ios app den
    /// editor auf den videos ändern? (wie in der webb app)". Mirrors web's
    /// VideoTileEditorPicker exactly, including its permission gate: reuses
    /// `canEditStatus` (any editor/Projektleiter/owner), NOT admin/PL-only
    /// — confirmed against postproduction/page.tsx's own
    /// `editable={canEditStatus}` rather than assuming from the question's
    /// wording alone.
    let onChangeAssignee: (String?) -> Void
    /// nil = read-only (no right to edit): icons only, no menu
    var onChangePlatforms: (([String]) -> Void)? = nil
    var extras: VideoExtras? = nil
    var onExtrasChange: ((VideoExtras) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    var qc: VideoQC? = nil
    var onOpenQC: (() -> Void)? = nil
    var rounds: FeedbackRounds.VideoRounds? = nil
    var onSetRoundLimit: ((Int?) -> Void)? = nil
    // 2026-11-17 (b113) — language / format / resolution badges, multi-select, upload progress,
    // «Neue Version hochladen» (true = from Photos), processing state + «Erneut versuchen»
    var languageBadge: AnyView? = nil
    var selecting: Bool = false
    var checked: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var uploadFraction: Double? = nil
    var onUploadVersion: ((Bool) -> Void)? = nil
    var onReprocess: ((String) -> Void)? = nil
    var retrying: Bool = false

    @State private var deadline: Date
    /// 2026-08-06, Lino: "wenn man feste oder lange auf ein video ... drückt,
    /// kann man das video löschen" — long-press (contextMenu) on the
    /// thumbnail offers "Video löschen", which then asks for confirmation
    /// here before actually calling onDeleteVideo. Matches web's confirm
    /// wording/scope exactly (VideoReviewModal's onDeleteVideo): only the
    /// Video itself (+ its versions/comments), NOT the Section or its Scenes.
    @State private var showingDeleteConfirm = false

    init(
        section: SceneSection, video: Video?, members: [Member], canEditStatus: Bool, canEditTitleAndDeadline: Bool, uploading: Bool,
        onTapUpload: @escaping () -> Void, onPlay: @escaping (Video, VideoVersion) -> Void, onEditTitle: @escaping () -> Void,
        onStatusChange: @escaping (PostproductionStatus) -> Void, onDeadlineChange: @escaping (Date?) -> Void,
        onDeleteVideo: @escaping () -> Void, onChangeAssignee: @escaping (String?) -> Void,
        onChangePlatforms: (([String]) -> Void)? = nil,
        extras: VideoExtras? = nil, onExtrasChange: ((VideoExtras) -> Void)? = nil, onError: ((String) -> Void)? = nil,
        qc: VideoQC? = nil, onOpenQC: (() -> Void)? = nil,
        rounds: FeedbackRounds.VideoRounds? = nil, onSetRoundLimit: ((Int?) -> Void)? = nil,
        languageBadge: AnyView? = nil, selecting: Bool = false, checked: Bool = false, onToggleSelect: (() -> Void)? = nil,
        uploadFraction: Double? = nil, onUploadVersion: ((Bool) -> Void)? = nil, onReprocess: ((String) -> Void)? = nil,
        retrying: Bool = false
    ) {
        self.languageBadge = languageBadge
        self.selecting = selecting
        self.checked = checked
        self.onToggleSelect = onToggleSelect
        self.uploadFraction = uploadFraction
        self.onUploadVersion = onUploadVersion
        self.onReprocess = onReprocess
        self.retrying = retrying
        self.extras = extras
        self.onExtrasChange = onExtrasChange
        self.onError = onError
        self.qc = qc
        self.onOpenQC = onOpenQC
        self.rounds = rounds
        self.onSetRoundLimit = onSetRoundLimit
        self.section = section
        self.video = video
        self.members = members
        self.canEditStatus = canEditStatus
        self.canEditTitleAndDeadline = canEditTitleAndDeadline
        self.uploading = uploading
        self.onTapUpload = onTapUpload
        self.onPlay = onPlay
        self.onEditTitle = onEditTitle
        self.onStatusChange = onStatusChange
        self.onDeadlineChange = onDeadlineChange
        self.onDeleteVideo = onDeleteVideo
        self.onChangeAssignee = onChangeAssignee
        self.onChangePlatforms = onChangePlatforms
        _deadline = State(initialValue: section.postproductionDeadline ?? .now)
    }

    private var assignedEditor: Member? { members.first(where: { $0.userId == video?.assigneeId }) }
    private var editorLabel: String {
        if let assignedEditor { return assignedEditor.name?.isEmpty == false ? assignedEditor.name! : assignedEditor.email }
        return language.t("videoTile.editorUnassigned")
    }

    private var readyVersion: VideoVersion? { video?.versions.last(where: { $0.status == "ready" }) }

    /// 2026-11-17 (b113, web VideoTile.tsx) — never an endless spinner: «nicht geklappt» only when
    /// the job failed, or 15 min after the job STARTED without a thumbnail; no job info → 15 min
    /// after upload. Waiting in the queue is never an error.
    static func processingStuck(_ v: VideoVersion, now: Date = Date()) -> Bool {
        guard v.status == "ready", v.thumbnailUrl == nil else { return false }
        let limit: TimeInterval = 15 * 60
        switch v.processing {
        case "failed": return true
        case "running": return now.timeIntervalSince(v.processingStartedDate ?? now) > limit
        case "queued": return false
        default: return now.timeIntervalSince(v.createdAt) > limit
        }
    }

    /// newest version still uploading (from another device, or this one before «complete»)
    private var remoteUploading: Bool { !uploading && video?.versions.last?.status == "uploading" }
    private var stillProcessing: Bool { !remoteUploading && readyVersion != nil && readyVersion?.thumbnailUrl == nil }
    private var processingFailed: Bool { stillProcessing && !retrying && readyVersion.map { Self.processingStuck($0) } == true }

    private var processingLabel: String {
        switch readyVersion?.processing {
        case "queued": return language.t("pp.queued")
        case "running": return language.t("pp.processingRunning")
        default: return language.t("pp.processing")
        }
    }

    @ViewBuilder
    private var newVersionMenuItems: some View {
        if let onUploadVersion {
            Menu {
                Button { onUploadVersion(true) } label: { Label(language.t("pp.fromPhotos"), systemImage: "photo.on.rectangle") }
                Button { onUploadVersion(false) } label: { Label(language.t("pp.fromFiles"), systemImage: "folder") }
            } label: {
                Label(language.t("pp.uploadNewVersion"), systemImage: "arrow.up.doc")
            }
        }
    }

    /// 2026-07-23 (#321) — same STATUS_GLOW_COLOR values web's VideoTile.tsx
    /// uses, see PostproductionStatus.glowColor's own doc comment.
    private var statusColor: Color { (section.postproductionStatus ?? .wartend).glowColor }

    /// Trailing hint that a pill opens a menu — same glyph
    /// `.pickerStyle(.menu)` draws itself, reused here since these two rows
    /// are now hand-built `Menu`s rather than an actual `Picker`.
    private var menuChevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusPill: some View {
        let status = section.postproductionStatus ?? .wartend
        let label = HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(PostproductionListView.statusLabel(status, language: language))
                .font(.subheadline.weight(.medium))
            if canEditStatus { menuChevron }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.16), in: Capsule())

        if canEditStatus {
            Menu {
                ForEach(PostproductionStatus.allCases, id: \.self) { candidate in
                    Button {
                        onStatusChange(candidate)
                    } label: {
                        if candidate == status {
                            Label(PostproductionListView.statusLabel(candidate, language: language), systemImage: "checkmark")
                        } else {
                            Text(PostproductionListView.statusLabel(candidate, language: language))
                        }
                    }
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    @ViewBuilder
    private var editorPill: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: "person.crop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(editorLabel)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 100, alignment: .leading)
            if canEditStatus { menuChevron }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: Capsule())

        // Same permission gate as the status pill above (canEditStatus),
        // matching web's own VideoTileEditorPicker `editable={canEditStatus}`
        // exactly rather than admin/Projektleiter-only.
        if canEditStatus {
            Menu {
                Button {
                    onChangeAssignee(nil)
                } label: {
                    if assignedEditor == nil {
                        Label(language.t("videoTile.editorUnassigned"), systemImage: "checkmark")
                    } else {
                        Text(language.t("videoTile.editorUnassigned"))
                    }
                }
                ForEach(members) { member in
                    Button {
                        onChangeAssignee(member.userId)
                    } label: {
                        let name = member.name?.isEmpty == false ? member.name! : member.email
                        if member.userId == assignedEditor?.userId {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    var body: some View {
        // 2026-08-05, Lino: single-column full-width tile now has real
        // room to breathe — every footer text bumped one step up from the
        // 2-column sizes above (subheadline->headline, caption->subheadline,
        // caption2->caption), padding 8->12, status dot 7->9.
        // 2026-08-09, Lino: "gib allen elementen ein wenig mehr platz
        // vertikal" — 8 -> 12 between rows, outer padding 12 -> 14.
        VStack(alignment: .leading, spacing: 12) {
            thumbnail
            if let video {
                HStack(spacing: 6) {
                    // 2026-08-05, Lino: "hier können die titel in der
                    // kachel grösser dargestellt werden" — headline -> title3.
                    Text(video.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if canEditTitleAndDeadline {
                        Button(action: onEditTitle) {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if canEditStatus && !selecting {
                        Menu {
                            newVersionMenuItems
                            Button(role: .destructive) { showingDeleteConfirm = true } label: {
                                Label(language.t("postproductionListView.deleteVideo"), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 30)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("pp.tileMenu")
                    }
                }
                // 2026-08-08, Lino: "können wir die statusauswahl und
                // editor auswahl noch schöner und typisch apple machen?" —
                // replaced the bare Picker/Menu-with-plain-text rows (which
                // read as loose, unstyled text next to the real title/
                // buttons) with a row of proper capsule pills: colored
                // dot/icon + label + a chevron.up.chevron.down affordance
                // (the standard system hint that a control opens a menu,
                // same glyph SwiftUI's own .pickerStyle(.menu) draws) inside
                // a tinted rounded background — the native "filter pill"
                // pattern iOS apps like Photos/Files/Reminders use, and the
                // same silhouette web's own Pill/VideoTileEditorPicker
                // capsules converged on independently.
                // 2026-08-09, Lino: "status rechtsbündig auf der rechten
                // Seite" + "editor auf die linke Seite und links bündig" —
                // was a plain leading HStack with both pills bunched
                // together; editorPill now anchors the row's leading edge,
                // a Spacer pushes statusPill all the way to the trailing
                // edge.
                // 2026-10-12 — the Fassungen right on the tile (web parity)
                if let extras, let onExtrasChange {
                    FassungenChipsRow(videoId: video.id, extras: extras, canEdit: canEditStatus, onChange: onExtrasChange, onError: { onError?($0) })
                }
                HStack(spacing: 8) {
                    editorPill
                    Spacer(minLength: 8)
                    statusPill
                }
                if canEditTitleAndDeadline {
                    Toggle(language.t("postproductionListView.deadlineLabel"), isOn: Binding(
                        get: { section.postproductionDeadline != nil },
                        set: { onDeadlineChange($0 ? deadline : nil) }
                    ))
                    .font(.subheadline)
                    if section.postproductionDeadline != nil {
                        DatePicker(language.t("postproductionListView.dateLabel"), selection: Binding(
                            get: { deadline },
                            set: { deadline = $0; onDeadlineChange($0) }
                        ), displayedComponents: .date)
                        .labelsHidden()
                        .font(.subheadline)
                    }
                }
                // 2026-09-25, Lino: "in der Postproduction-Übersicht muss der
                // momentan ausgewählte Stand rechts unten, wo auch die anderen
                // Infos stehen, angezeigt werden" (web-parity, VideoTile's
                // PostStageLabel) — shares the read-only deadline's row.
                let stage = PostStage.effective(version: readyVersion, video: video, sectionStatus: section.postproductionStatus)
                let readOnlyDeadline = canEditTitleAndDeadline ? nil : section.postproductionDeadline
                if let readOnlyDeadline {
                    Text(language.t("postproductionListView.deadlineWithValue").replacingOccurrences(of: "{date}", with: readOnlyDeadline.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 2026-10-12, Lino: "working on ... gib dem mehr platz" — its own line at the very
                // bottom: "WORKING ON" left, the stage right (web parity)
                if let stage {
                    Divider().opacity(0.6)
                    HStack {
                        WorkingOnKicker()
                            .opacity(stage == .abgenommen ? 0 : 1)
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(stage == .abgenommen ? Color.green : Color.primary.opacity(0.8))
                                .frame(width: 7, height: 7)
                            Text(language.t(stage.labelKey))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(stage == .abgenommen ? Color.green : Color.primary.opacity(0.85))
                        }
                    }
                }
            } else {
                Text(section.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(language.t("postproductionListView.noVideoYet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            // multi-select: the whole tile toggles (web: selectBox), other controls are paused
            if selecting {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(checked ? Color.blue : Color.clear, lineWidth: 2.5)
                    .background(Color.black.opacity(checked ? 0 : 0.001))
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleSelect?() }
                    .accessibilityElement()
                    .accessibilityLabel(video?.title ?? section.name)
                    .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("pp.selectTile")
            }
        }
        // 2026-08-05, Lino: "den glow nehmen wir hier ganz weg" — removes
        // the #321 per-status shadow glow entirely (the small status dot
        // above, statusColor's other use, stays).
        // 2026-08-09, Lino: "dieser [Lösch-Dialog] muss immer in der Mitte
        // des Screens auftauchen" — `.confirmationDialog` renders as a
        // bottom action sheet on iPhone, not centered; `.alert` is SwiftUI's
        // centered-on-screen dialog style, same button/role shape otherwise.
        .alert(
            language.t("postproductionListView.deleteVideo"),
            isPresented: $showingDeleteConfirm
        ) {
            Button(language.t("common.delete"), role: .destructive) {
                onDeleteVideo()
            }
            Button(language.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.t("postproductionListView.deleteVideoMessage").replacingOccurrences(of: "{title}", with: video?.title ?? ""))
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.tertiarySystemFill))
            // 2026-07-23 (#321, Lino: "hier müssen die Thumbnails dargestellt
            // werden") — real poster frame instead of a bare gray box; stays
            // nil (falls through to the plain fill above) until
            // video_processing.py's ffmpeg pass finishes, same gap web has.
            //
            // 2026-07-26 (#331, Lino: "der Ausschnitt von den Thumbnails ist
            // viel zu gross ins Bild gezoomed") — was `.aspectRatio(16/9,
            // contentMode: .fill).clipped()` applied directly on top of
            // AsyncShotThumbnail(size: nil) with NO definite frame for that
            // fill computation to run against, so it negotiated against
            // AsyncShotThumbnail's own unconstrained/intrinsic (image-pixel-
            // size-driven) ideal size instead of this tile's actual visible
            // box — over-cropping the frame. Same root cause, same fix as
            // #336 in IdeaGridView.swift: give it an explicit greedy
            // `.frame(...)` and let AsyncShotThumbnail's OWN internal
            // `.aspectRatio(contentMode: .fill)` do the (single) fill
            // computation against that now-definite frame.
            if let thumbnailUrl = readyVersion?.thumbnailUrl {
                AsyncShotThumbnail(path: thumbnailUrl, size: nil, lockAspectRatio: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            if uploading {
                // 2026-07-26 (#334) — was a bare ProgressView() with no
                // label and no scrim, easy to miss against the plain tile
                // fill/an already-showing older thumbnail; now matches the
                // legibility treatment the ready/play state below already
                // gets (dark scrim + white foreground).
                Color.black.opacity(0.4)
                VStack(spacing: 6) {
                    if let uploadFraction {
                        Text("\(language.t("pp.uploading")) \(Int((uploadFraction * 100).rounded())) %")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        ProgressView(value: uploadFraction)
                            .tint(.blue)
                            .frame(maxWidth: 220)
                    } else {
                        ProgressView().tint(.white)
                        Text(language.t("postproductionListView.uploading"))
                            .font(.caption2)
                            .foregroundStyle(.white)
                    }
                }
            } else if remoteUploading {
                Color.black.opacity(0.5)
                Text(language.t("pp.uploading"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            } else if let video, let readyVersion {
                // Filled slot — tap opens the fullscreen player (#284).
                // Translucent scrim so the play icon stays legible over a
                // bright thumbnail photo, not just over the plain gray fill.
                //
                // 2026-07-26 (#333, Lino: "es passiert aber nichts" beim
                // Klick aufs Thumbnail) — the tap gesture used to sit ONLY
                // on the small `play.circle.fill` glyph itself (its own
                // tiny intrinsic size), so tapping anywhere else on the
                // (much larger) thumbnail did nothing. `Color` has no
                // intrinsic size, so as an unconstrained ZStack layer it
                // already fills the WHOLE tile — moving the gesture there
                // instead makes the entire thumbnail tappable. The icon on
                // top stays purely decorative (no gesture of its own, so it
                // doesn't shadow the Color layer's hit target underneath).
                Color.black.opacity(readyVersion.thumbnailUrl != nil ? 0.15 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { onPlay(video, readyVersion) }
                    .contextMenu {
                        if canEditStatus {
                            newVersionMenuItems
                            Button(role: .destructive) {
                                showingDeleteConfirm = true
                            } label: {
                                Label(language.t("postproductionListView.deleteVideo"), systemImage: "trash")
                            }
                        }
                    }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white, Color.accentColor)
                    .opacity(stillProcessing ? 0 : 1)
                if processingFailed {
                    Color.black.opacity(0.6)
                    VStack(spacing: 8) {
                        Text(language.t("pp.processingFailed"))
                            .font(.caption)
                            .foregroundStyle(Color(red: 1, green: 0.93, blue: 0.8))
                        if let onReprocess {
                            Button(language.t("pp.retry")) { onReprocess(readyVersion.id) }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .accessibilityIdentifier("pp.processingFailed")
                } else if stillProcessing {
                    // the player already plays the original meanwhile — taps go through
                    Color.black.opacity(0.5).allowsHitTesting(false)
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).controlSize(.small)
                        Text(processingLabel).font(.caption).foregroundStyle(.white.opacity(0.85))
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("pp.processingState")
                } else if readyVersion.previewStatus == "pending" {
                    VStack {
                        Spacer()
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini).tint(.white)
                            Text(language.t("pp.previewOptimizing")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.bottom, 36)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                    }
                    .allowsHitTesting(false)
                }
            } else {
                // 2026-07-21, #284 — both the true empty slot (no Video
                // row at all) AND a Video row still waiting on its first
                // ready version tap straight into the file picker, no
                // intermediate modal/menu, matching this ticket's
                // explicit spec for the empty-tile placeholder.
                VStack(spacing: 4) {
                    Image(systemName: video == nil ? "plus.circle" : "arrow.up.circle")
                        .font(.system(size: 28))
                    Text(video == nil ? language.t("postproductionListView.uploadVideo") : language.t("postproductionListView.processing"))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapUpload)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // 2026-07-26 (#332) — version number + open-comment count, mirrors
        // web's VideoTile.tsx exactly ("v{n}" + "💬 {n}" pills, top-right,
        // comment count counting only status=="open" i.e. !resolved).
        // Deliberately gated on `!uploading` — web's equivalent badge div
        // sits earlier in DOM order than its stillUploading/stillProcessing
        // overlay, so that overlay visually paints over/obscures it during
        // an upload; hiding it here during our own `uploading` state
        // matches that same effective behavior (and avoids showing a STALE
        // version's badge while a newer one is mid-upload).
        .overlay(alignment: .topTrailing) {
            // 2026-11-16 — platform icons stacked vertically below the version badge (web: right, below QC)
            VStack(alignment: .trailing, spacing: 6) {
                if !uploading, let readyVersion {
                    versionAndCommentBadge(readyVersion)
                }
                if let video, !uploading {
                    VideoPlatformStack(platforms: video.platformList, onChange: onChangePlatforms)
                        .padding(.trailing, 10)
                        .padding(.top, -4)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let languageBadge, !uploading {
                languageBadge.padding(8)
            }
        }
        .overlay(alignment: .topLeading) {
            // 2026-10-12 — technical check + feedback rounds (internal only, web parity)
            HStack(spacing: 4) {
                if selecting {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(checked ? Color.white : Color.white.opacity(0.85), checked ? Color.blue : Color.black.opacity(0.35))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
                if let qc, qc.status != "none" {
                    Button { onOpenQC?() } label: { QCBadge(qc: qc) }
                        .buttonStyle(.plain)
                        .disabled(onOpenQC == nil)
                }
                if let rounds, rounds.used > 0 || rounds.limit != nil {
                    RoundsBadge(rounds: rounds, canEdit: onSetRoundLimit != nil) { onSetRoundLimit?($0) }
                }
            }
            .padding(10)
        }
    }

    private func versionAndCommentBadge(_ version: VideoVersion) -> some View {
        let openCount = version.comments.filter { !$0.resolved }.count
        // 2026-10-12, Lino: "die versions zahl geht immer leicht über die rundung hinaus" — inset
        // far enough from the thumbnail's rounded corner, compact rounded badge
        return HStack(spacing: 4) {
            Text("V\(version.versionNumber)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            if openCount > 0 {
                Label("\(openCount)", systemImage: "bubble.left.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            }
        }
        .padding(10)
    }
}

/// 2026-11-16 (web parity, VideoTile.tsx) — the video's platform icons, stacked vertically. With
/// `onChange` (editors) a tap opens a menu to switch platforms on and off (several allowed) or
/// remove all; empty + editable shows a small «+».
struct VideoPlatformStack: View {
    @ObservedObject private var language = AppLanguage.shared
    let platforms: [String]
    let onChange: (([String]) -> Void)?

    var body: some View {
        if let onChange {
            Menu {
                ForEach(VideoPlatform.allCases) { p in
                    Button {
                        var next = platforms
                        if let i = next.firstIndex(of: p.rawValue) { next.remove(at: i) } else { next.append(p.rawValue) }
                        onChange(next)
                    } label: {
                        if platforms.contains(p.rawValue) {
                            Label(p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name)
                        }
                    }
                }
                if !platforms.isEmpty {
                    Divider()
                    Button(language.t("videoTile.platformNone"), role: .destructive) { onChange([]) }
                }
            } label: {
                // 36-pt tap area (the icons are 22 pt): otherwise the thumbnail's own tap (play)
                // often won and the menu only opened on the second try
                icons(showAdd: true)
                    .frame(minWidth: 36, minHeight: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(language.t("videoTile.platform"))
            .accessibilityIdentifier("videoTile.platforms")
        } else if !platforms.isEmpty {
            icons(showAdd: false)
        }
    }

    @ViewBuilder
    private func icons(showAdd: Bool) -> some View {
        if platforms.isEmpty {
            if showAdd {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
        } else {
            VStack(spacing: 4) {
                ForEach(platforms, id: \.self) { raw in
                    if let p = VideoPlatform(rawValue: raw) {
                        Image(p.imageName)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .accessibilityLabel(p.name)
                    }
                }
            }
        }
    }
}
