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
                // aneinander"); 16pt matches ProjectListView's own grid
                // spacing convention (its `columns`/LazyVGrid both use 16).
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(tiles) { tile in
                        PostproductionVideoTile(
                            section: tile.section,
                            video: tile.video,
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
        .task {
            if let me = try? await APIClient.shared.me() {
                myRole = viewModel.members.first(where: { $0.userId == me.id })?.role
            }
            await loadAllVideos()
            if let initialVideoId,
               let video = sectionVideos.values.flatMap({ $0 }).first(where: { $0.id == initialVideoId }),
               let version = video.versions.last(where: { $0.status == "ready" }) {
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
            VideoPlayerSheet(video: item.video, version: item.version) { updated in
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

    private func loadAllVideos() async {
        isLoadingVideos = true
        defer { isLoadingVideos = false }
        for section in sections {
            do {
                sectionVideos[section.id] = try await APIClient.shared.listVideos(sectionId: section.id)
            } catch {
                errorMessage = error.localizedDescription
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
        pickerTarget = PickerTarget(sectionId: section.id, videoId: nil)
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
        } catch {
            errorMessage = error.localizedDescription
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
    let canEditStatus: Bool
    let canEditTitleAndDeadline: Bool
    let uploading: Bool
    let onTapUpload: () -> Void
    let onPlay: (Video, VideoVersion) -> Void
    let onEditTitle: () -> Void
    let onStatusChange: (PostproductionStatus) -> Void
    let onDeadlineChange: (Date?) -> Void

    @State private var deadline: Date

    init(
        section: SceneSection, video: Video?, canEditStatus: Bool, canEditTitleAndDeadline: Bool, uploading: Bool,
        onTapUpload: @escaping () -> Void, onPlay: @escaping (Video, VideoVersion) -> Void, onEditTitle: @escaping () -> Void,
        onStatusChange: @escaping (PostproductionStatus) -> Void, onDeadlineChange: @escaping (Date?) -> Void
    ) {
        self.section = section
        self.video = video
        self.canEditStatus = canEditStatus
        self.canEditTitleAndDeadline = canEditTitleAndDeadline
        self.uploading = uploading
        self.onTapUpload = onTapUpload
        self.onPlay = onPlay
        self.onEditTitle = onEditTitle
        self.onStatusChange = onStatusChange
        self.onDeadlineChange = onDeadlineChange
        _deadline = State(initialValue: section.postproductionDeadline ?? .now)
    }

    private var readyVersion: VideoVersion? { video?.versions.last(where: { $0.status == "ready" }) }

    /// 2026-07-23 (#321) — same STATUS_GLOW_COLOR values web's VideoTile.tsx
    /// uses, see PostproductionStatus.glowColor's own doc comment.
    private var statusColor: Color { (section.postproductionStatus ?? .wartend).glowColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            if let video {
                HStack(spacing: 4) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if canEditTitleAndDeadline {
                        Button(action: onEditTitle) {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    if canEditStatus {
                        Picker(language.t("postproductionListView.statusLabel"), selection: Binding(
                            get: { section.postproductionStatus ?? .wartend },
                            set: { onStatusChange($0) }
                        )) {
                            ForEach(PostproductionStatus.allCases, id: \.self) { status in
                                Text(PostproductionListView.statusLabel(status, language: language)).tag(status)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.caption)
                    } else {
                        Text(PostproductionListView.statusLabel(section.postproductionStatus ?? .wartend, language: language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if canEditTitleAndDeadline {
                    Toggle(language.t("postproductionListView.deadlineLabel"), isOn: Binding(
                        get: { section.postproductionDeadline != nil },
                        set: { onDeadlineChange($0 ? deadline : nil) }
                    ))
                    .font(.caption)
                    if section.postproductionDeadline != nil {
                        DatePicker(language.t("postproductionListView.dateLabel"), selection: Binding(
                            get: { deadline },
                            set: { deadline = $0; onDeadlineChange($0) }
                        ), displayedComponents: .date)
                        .labelsHidden()
                        .font(.caption)
                    }
                } else if let deadline = section.postproductionDeadline {
                    Text(language.t("postproductionListView.deadlineWithValue").replacingOccurrences(of: "{date}", with: deadline.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(section.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(language.t("postproductionListView.noVideoYet"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        // 2026-07-23 (#321) — soft per-status glow, cheap iOS equivalent of
        // web's VideoTile.tsx glow border (a CSS box-shadow using the same
        // STATUS_GLOW_COLOR). Only once a real video exists — an empty
        // upload-slot tile has no status to glow yet.
        .shadow(color: video != nil ? statusColor.opacity(0.35) : .clear, radius: 8)
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
