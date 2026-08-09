import SwiftUI
import PhotosUI
import AVFoundation

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

    /// One entry per Section, loaded once on appear then kept in sync
    /// locally after every upload/title/status/deadline change — no
    /// separate ShotListViewModel-published state, matching the same
    /// "video data stays local to this screen" precedent the old
    /// VideoPanelView already established.
    @State private var sectionVideos: [String: [Video]] = [:]
    @State private var isLoadingVideos = true
    @State private var errorMessage: String?

    /// Which (Section, optionally a specific already-existing Video)
    /// slot the PhotosPicker upload is for — captured at tap time so
    /// uploadPickedVideo knows exactly which Video row to attach the new
    /// version to (nil videoId = truly empty slot, create one first).
    private struct PickerTarget { let sectionId: String; let videoId: String? }
    @State private var pickerTarget: PickerTarget?
    /// 2026-07-26 (#334) — SAME target as `pickerTarget` above, captured a
    /// second time into an INDEPENDENT @State var. Root cause of "picking a
    /// video from the library did nothing, no upload indicator at all":
    /// `pickerTarget` also drives `.photosPicker`'s own `isPresented`
    /// binding below (`pickerTarget != nil`), whose dismissal setter nils
    /// `pickerTarget` out the instant an item is picked (the sheet auto-
    /// dismisses on selection) — racing with, and in practice beating,
    /// `.onChange(of: pickerItem)` below, whose `guard let target =
    /// pickerTarget` then saw nil and silently returned before ever
    /// calling uploadPickedVideo. This copy is never touched by that
    /// dismissal path, so it's still there when onChange reads it.
    @State private var pendingUploadTarget: PickerTarget?
    @State private var pickerItem: PhotosPickerItem?
    /// 2026-07-26 correction — was a single `uploadingSectionId: String?`,
    /// which made every tile under a multi-video Section (the "Hauptschnitt
    /// + Trailer" case, see this struct's own doc comment) show as
    /// "uploading" the instant ANY one of them got a new version, and made
    /// two concurrent uploads in the same Section race on one variable
    /// (whichever `defer` cleared it first hid the OTHER upload's still-
    /// in-flight indicator). Keyed by tile id instead — same id shape as
    /// `Tile.id` below (`video.id`, or `"empty-\(section.id)"` for a
    /// still-empty slot) — and a Set so multiple tiles can be mid-upload
    /// at once without clobbering each other.
    @State private var uploadingTileIds: Set<String> = []
    @State private var creatingUnplanned = false
    /// 2026-08-08 — guards the initialVideoId auto-open (see the
    /// `.task(id:)` below) so it only ever fires once, even though that
    /// task can legitimately re-run more than once now.
    @State private var didAutoOpenInitialVideo = false

    private func tileKey(for target: PickerTarget) -> String {
        target.videoId ?? "empty-\(target.sectionId)"
    }

    /// Title-edit alert (2026-07-21, #284) — admin/Projektleiter only,
    /// see canEditTitleAndDeadline.
    @State private var editingTitleVideo: Video?
    @State private var editingTitleText = ""

    @State private var playing: (video: Video, version: VideoVersion)?

    private var sections: [SceneSection] { viewModel.sections.filter(\.inPostproduction) }
    /// Status stays broadly editable (any real project role) — matches
    /// the backend's own patch_section_postproduction gating exactly
    /// (confirmed: any editor+ may change status there).
    private var canEditStatus: Bool { myRole == "editor" || myRole == "projektleiter" || myRole == "owner" }
    /// 2026-07-21, #284 — title editing uses the SAME gate as deadline.
    /// patch_section_postproduction's deadline check is confirmed
    /// admin/Projektleiter-only; the separate PATCH /videos/{id} title
    /// endpoint's own exact role requirement wasn't pinned down as
    /// precisely, so this errs conservative and matches this ticket's own
    /// explicit wording ("gated to admin/Projektleiter role only") rather
    /// than assuming title is as broadly editable as status.
    private var canEditTitleAndDeadline: Bool { myRole == "projektleiter" || myRole == "owner" }

    /// Local translation of PostproductionStatus.label — deliberately NOT
    /// changing Models.swift's own `.label` computed property (shared with
    /// other, un-migrated call sites like ShotListView's own status text;
    /// see AppLanguageStrings+Ideas.swift's top-of-file doc comment). Key
    /// names match web's own shared `postproductionStatus.*` keys exactly
    /// (see lib/i18n.tsx) — reused verbatim per this ticket's instructions.
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

    private var tiles: [Tile] {
        sections.flatMap { section -> [Tile] in
            let videos = sectionVideos[section.id] ?? []
            if videos.isEmpty {
                return [Tile(id: "empty-\(section.id)", section: section, video: nil)]
            }
            return videos.map { Tile(id: $0.id, section: section, video: $0) }
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if isLoadingVideos {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            ContentUnavailableView(
                language.t("postproductionListView.emptyTitle"),
                systemImage: "checklist",
                description: Text(language.t("postproductionListView.emptyDescription"))
            )
        } else {
            ScrollView {
                // 2026-07-26 (#331) — 12pt was cramped ("Kacheln zu eng
                // aneinander"); bumped to 16pt (ProjectListView's own grid
                // spacing convention). Same day, Lino re-reported "brauchen
                // mehr abstand zueinander" after actually testing that build
                // — 16pt still read as too tight to him in practice, bumped
                // again to 22pt (deliberately past ProjectListView's 16 now;
                // these tiles carry a lot more footer content — title,
                // status picker, deadline toggle — than a plain project
                // tile, so they benefit from more breathing room).
                // 2026-08-05, Lino: "die kacheln sollen nun die ganze breite
                // nutzen (jetzt haben wir ja zwei spalten), dies soll nur zu
                // einer spalte geändert werden, dann haben wir auf der
                // kachel mehr platz um texte ein wenig grösser darzustellen"
                // — single-column full-width tile, matches web's own
                // single-column flex-wrap layout (VideoTile.tsx) more
                // closely than the old 2-up grid did.
                LazyVGrid(columns: [GridItem(.flexible())], spacing: 22) {
                    ForEach(tiles) { tile in
                        PostproductionVideoTile(
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
                            }
                        )
                    }
                }
                .padding()
            }
        }
    }

    var body: some View {
        Group {
            if embedded {
                // No NavigationStack/own nav title here — ShotListView
                // already owns the surrounding NavigationStack when this
                // is the inline third workflow page (see #283).
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
            // 2026-07-21, #284 — separate from any per-tile upload tap:
            // this always creates a brand-new Section (start_in_
            // postproduction=true, matching web's is_unplanned "+ Video"
            // flow) rather than filling an existing planned slot. Same
            // role gate as status editing — any real project member with
            // an editor+ role, not admin/PL-only (uploading a video isn't
            // the same permission as changing a deadline).
            if canEditStatus {
                addUnplannedVideoButton
            }
        }
        // 2026-08-08 — same async-timing race class as the sections fix
        // right below (`viewModel.members` is loaded independently of
        // `viewModel.sections`, see ShotListViewModel.load()'s own
        // membersTask): a plain one-shot `.task` reading `viewModel.
        // members` here could resolve `me()` before `members` actually
        // populated, leaving `myRole` (and everything gated on it —
        // canEditStatus/canEditTitleAndDeadline, now also this file's new
        // Editor-picker) permanently nil/false. `.task(id:)` re-runs
        // whenever the member id list changes, so it self-corrects the
        // moment `members` actually arrives.
        .task(id: viewModel.members.map(\.userId)) {
            if let me = try? await APIClient.shared.me() {
                myRole = viewModel.members.first(where: { $0.userId == me.id })?.role
            }
        }
        // 2026-08-08, real bug found live (Lino: "es sind bei Dentalhygiene
        // - Oral B immer noch keine Videos zu sehen, man sieht nur die
        // leeren 'Ungeplantes Video' Kacheln") — this used to be part of
        // the plain `.task` above, which only ever runs ONCE right when
        // this view first appears. For a Postproduction-only project
        // (module_concept AND module_scripting both off — exactly
        // "Dentalhygiene - Oral B"'s real config), ShotListView's
        // `initialSection` picks `.postproduction` as the very FIRST
        // screen shown, so THIS view can mount and its `.task` can fire
        // before `viewModel.sections` (loaded asynchronously by the
        // PARENT view's own `viewModel.load()`) has finished — `sections`
        // here was reliably still empty at that exact moment.
        // `loadAllVideos()` then looped over zero sections (nothing to
        // fetch, so no error either — matches the reported "no alert, just
        // empty tiles"), and since the old plain `.task` never re-ran,
        // `sectionVideos` stayed empty forever even once `viewModel.
        // sections` finished loading moments later — every tile rendered
        // as the empty placeholder from then on. `.task(id:)` re-runs
        // automatically whenever the section id list actually changes
        // (e.g. the instant sections finish loading), fixing this without
        // a manual "is data ready yet" check. `didAutoOpenInitialVideo`
        // guards the deep-link auto-open so it still only ever fires once,
        // even though this task can legitimately re-run more than once now
        // (e.g. a section genuinely added/removed later).
        .task(id: sections.map(\.id)) {
            guard !sections.isEmpty else { return }
            await loadAllVideos()
            if !didAutoOpenInitialVideo, let initialVideoId,
               let video = sectionVideos.values.flatMap({ $0 }).first(where: { $0.id == initialVideoId }),
               let version = video.versions.last(where: { $0.status == "ready" }) {
                didAutoOpenInitialVideo = true
                playing = (video, version)
            }
        }
        .photosPicker(
            isPresented: Binding(get: { pickerTarget != nil }, set: { if !$0 { pickerTarget = nil } }),
            selection: $pickerItem, matching: .videos
        )
        .onChange(of: pickerItem) { _, newItem in
            // 2026-07-26 (#334) — reads `pendingUploadTarget`, NOT
            // `pickerTarget` (see that var's own doc comment above for why).
            guard let newItem, let target = pendingUploadTarget else { return }
            pendingUploadTarget = nil
            pickerItem = nil
            Task { await uploadPickedVideo(newItem, target: target) }
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
            VideoPlayerSheet(video: item.video, version: item.version, projectId: viewModel.projectId) { updated in
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

    private var addUnplannedVideoButton: some View {
        Button {
            Task { await createUnplannedVideo() }
        } label: {
            if creatingUnplanned {
                ProgressView()
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.accentColor))
            } else {
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
        }
        .disabled(creatingUnplanned)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    // MARK: - data loading

    /// 2026-08-05, Lino: "jegliche lade... prozesse müssen ein wenig
    /// schneller werden" — used to await each section's videos ONE AT A
    /// TIME in a plain for loop, so total load time scaled with section
    /// count (N sections = N sequential round trips) instead of the single
    /// round trip's worth of latency this could be. withTaskGroup fires
    /// every section's listVideos concurrently; results are only applied
    /// back to `sectionVideos` (a View's @State, implicitly MainActor) as
    /// each one resolves via `for await`, which resumes on this function's
    /// own calling context — safe, no concurrent-mutation risk despite the
    /// child tasks themselves running in parallel.
    private func loadAllVideos() async {
        isLoadingVideos = true
        defer { isLoadingVideos = false }
        await withTaskGroup(of: (String, Result<[Video], Error>).self) { group in
            for section in sections {
                group.addTask {
                    do {
                        return (section.id, .success(try await APIClient.shared.listVideos(sectionId: section.id)))
                    } catch {
                        return (section.id, .failure(error))
                    }
                }
            }
            for await (sectionId, result) in group {
                switch result {
                case .success(let videos): sectionVideos[sectionId] = videos
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - unplanned video ("+"), one step: create Section (already
    // in_postproduction) -> straight to the picker, no naming modal.

    private func createUnplannedVideo() async {
        guard !creatingUnplanned else { return }
        creatingUnplanned = true
        defer { creatingUnplanned = false }
        guard let section = await viewModel.createSection(name: "Video", startInPostproduction: true) else { return }
        sectionVideos[section.id] = []
        // 2026-08-05, Lino: "video hochladen... geht immer noch nicht" —
        // root cause: this only ever set `pickerTarget` (drives the
        // .photosPicker sheet's own isPresented binding), never
        // `pendingUploadTarget` — the ONE var .onChange(of: pickerItem)
        // actually reads to know what to upload to (see #334's own doc
        // comment on pendingUploadTarget for why it reads that copy, not
        // pickerTarget). Every per-tile onTapUpload sets BOTH; this "+"
        // FAB path (creating a brand-new unplanned video) only ever set
        // one of them — picking a video here opened the picker fine, but
        // silently did nothing at all afterward, no error, nothing.
        let target = PickerTarget(sectionId: section.id, videoId: nil)
        pickerTarget = target
        pendingUploadTarget = target
    }

    // MARK: - upload pipeline (same steps the old VideoPanelView.handlePicked used)

    private func uploadPickedVideo(_ item: PhotosPickerItem, target: PickerTarget) async {
        let key = tileKey(for: target)
        uploadingTileIds.insert(key)
        defer { uploadingTileIds.remove(key) }
        do {
            let video: Video
            if let videoId = target.videoId, let existing = sectionVideos[target.sectionId]?.first(where: { $0.id == videoId }) {
                video = existing
            } else if let firstExisting = sectionVideos[target.sectionId]?.first {
                // Truly-empty-tile tap (target.videoId == nil) on a
                // Section that already has a Video row but no ready
                // version yet — reuse it instead of creating a second one.
                video = firstExisting
            } else {
                video = try await APIClient.shared.createVideo(sectionId: target.sectionId, title: "Video", sortOrder: 0)
                sectionVideos[target.sectionId, default: []].append(video)
            }
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                errorMessage = language.t("postproductionListView.videoLoadFailed")
                return
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let filename = movie.url.lastPathComponent
            let contentType = movie.url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
            let versionDraft = try await APIClient.shared.createVideoVersion(videoId: video.id, filename: filename, contentType: contentType)
            guard let uploadURLString = versionDraft.playbackUrl, let uploadURL = URL(string: uploadURLString) else {
                errorMessage = language.t("postproductionListView.noUploadUrl")
                return
            }
            try await APIClient.shared.uploadVideoFile(to: uploadURL, fileURL: movie.url, contentType: contentType)
            let fileSize = try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? Int
            let duration = try? await AVURLAsset(url: movie.url).load(.duration).seconds
            let completed = try await APIClient.shared.completeVideoVersion(versionDraft.id, fileSizeBytes: fileSize, durationSeconds: duration)
            if let index = sectionVideos[target.sectionId]?.firstIndex(where: { $0.id == video.id }) {
                sectionVideos[target.sectionId]?[index].versions.append(completed)
            }
            pollForThumbnail(sectionId: target.sectionId, videoId: video.id, versionId: completed.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 2026-07-27, Lino: "lädt man ein video hoch bleibt es unendlich auf
    /// 'In Verarbeitung'... man muss die Seite reloaden" — mirrors web's
    /// postproduction/page.tsx pollForFilmstrip. `completed` above is
    /// captured straight from the `/complete` response, returned BEFORE the
    /// server's background job (video_processing.py) has generated
    /// thumbnail_key/filmstrip_key (~40s) — nothing here ever re-fetched
    /// afterward, so the tile stayed on "In Verarbeitung" (thumbnail's own
    /// doc comment already flagged this exact gap) until a full relaunch
    /// happened to re-fetch fresh data. Polls this section's video list
    /// until the new version's thumbnailUrl shows up, then merges the whole
    /// section back in. Gives up silently after ~1 minute, same window web
    /// uses — a manual pull-to-refresh still works as fallback.
    private func pollForThumbnail(sectionId: String, videoId: String, versionId: String) {
        Task {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    let videos = try await APIClient.shared.listVideos(sectionId: sectionId)
                    if let video = videos.first(where: { $0.id == videoId }),
                       let version = video.versions.first(where: { $0.id == versionId }),
                       version.thumbnailUrl != nil {
                        sectionVideos[sectionId] = videos
                        return
                    }
                } catch {
                    // network hiccup — just retry
                }
            }
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

    /// 2026-08-06 — long-press-on-thumbnail delete (see PostproductionVideoTile's
    /// contextMenu/confirmationDialog). Same scope as web's onDeleteVideo:
    /// only the Video itself (backend cascades to its VideoVersions/
    /// VideoComments), the Section and its real Scenes are untouched.
    private func deleteVideo(_ video: Video) async {
        do {
            try await APIClient.shared.deleteVideo(video.id)
            sectionVideos[video.sectionId]?.removeAll { $0.id == video.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 2026-08-08 — "kann der admin / projektleiter in der ios app den
    /// editor auf den videos ändern? (wie in der webb app)", ported from
    /// web's own updateVideoAssignee (postproduction/page.tsx). `userId ==
    /// nil` means "unassign", translated to `clearAssignee: true` — a plain
    /// nil `assigneeId` alone means "don't touch it" on the backend (see
    /// VideoPatch's own doc comment in schemas.py).
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
        onDeleteVideo: @escaping () -> Void, onChangeAssignee: @escaping (String?) -> Void
    ) {
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
        _deadline = State(initialValue: section.postproductionDeadline ?? .now)
    }

    private var assignedEditor: Member? { members.first(where: { $0.userId == video?.assigneeId }) }
    private var editorLabel: String {
        if let assignedEditor { return assignedEditor.name?.isEmpty == false ? assignedEditor.name! : assignedEditor.email }
        return language.t("videoTile.editorUnassigned")
    }

    private var readyVersion: VideoVersion? { video?.versions.last(where: { $0.status == "ready" }) }

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
                } else if let deadline = section.postproductionDeadline {
                    Text(language.t("postproductionListView.deadlineWithValue").replacingOccurrences(of: "{date}", with: deadline.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    ProgressView().tint(.white)
                    Text(language.t("postproductionListView.uploading"))
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
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
            if !uploading, let readyVersion {
                versionAndCommentBadge(readyVersion)
            }
        }
    }

    private func versionAndCommentBadge(_ version: VideoVersion) -> some View {
        let openCount = version.comments.filter { !$0.resolved }.count
        return HStack(spacing: 4) {
            Text("v\(version.versionNumber)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.5), in: Capsule())
            if openCount > 0 {
                Text("💬 \(openCount)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
        .padding(6)
    }
}
