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
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploadingSectionId: String?
    @State private var creatingUnplanned = false

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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(tiles) { tile in
                        PostproductionVideoTile(
                            section: tile.section,
                            video: tile.video,
                            canEditStatus: canEditStatus,
                            canEditTitleAndDeadline: canEditTitleAndDeadline,
                            uploading: uploadingSectionId == tile.section.id,
                            onTapUpload: {
                                pickerTarget = PickerTarget(sectionId: tile.section.id, videoId: tile.video?.id)
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
            guard let newItem, let target = pickerTarget else { return }
            pickerTarget = nil
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
        uploadingSectionId = target.sectionId
        defer { uploadingSectionId = nil }
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
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.tertiarySystemFill))
            if uploading {
                ProgressView()
            } else if let video, let readyVersion {
                // Filled slot — tap opens the fullscreen player (#284).
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white, Color.accentColor)
                    .contentShape(Rectangle())
                    .onTapGesture { onPlay(video, readyVersion) }
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
    }
}
