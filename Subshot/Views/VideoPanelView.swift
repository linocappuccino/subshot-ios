import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Video-Feedback-Tool (2026-07-17, #11 Schritt 7) — war eingebettet in
/// PostproductionListView (ein Video "gehört" zu einer Section, siehe
/// backend Video's Doc-Kommentar). Ein Video pro Section im Normalfall,
/// "+ weiteres Video" deckt den Ausnahmefall ab (Hauptschnitt + Trailer),
/// mirrors web's VideoPanel.tsx. Upload läuft direkt Geraet -> R2
/// (presigned PUT, siehe APIClient.createVideoVersion/uploadVideoFile) —
/// diese App sieht den Video-Body selbst nie ausser beim lokalen Kopieren
/// aus der Fotomediathek.
///
/// 2026-07-21, #284 — SUPERSEDED: PostproductionListView.swift's full
/// grid overhaul reimplements this exact upload pipeline (and the
/// per-section video list it drove) inline, matching web's VideoTile.tsx
/// 2-column-grid layout instead of a List of expandable rows. `VideoRow`
/// and `VideoPanelView` below are no longer referenced anywhere. Left in
/// place rather than deleted — removing a source file from the Xcode
/// project without Xcode itself (just deleting off disk) risks a
/// dangling project-file reference with no compiler here to catch it;
/// safe for Lino to delete via Xcode once he's confirmed the new grid
/// view on his Mac. `MovieFile` below is NOT dead — the new grid view
/// reuses it directly (now internal, not private, for exactly that
/// reason).
struct VideoPanelView: View {
    @ObservedObject private var language = AppLanguage.shared
    let sectionId: String
    let canEdit: Bool

    @State private var videos: [Video] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var uploadingVideoId: String?
    @State private var pickerTargetVideoId: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var playing: (video: Video, version: VideoVersion)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(videos) { video in
                    VideoRow(
                        video: video,
                        canEdit: canEdit,
                        uploading: uploadingVideoId == video.id,
                        onUploadTap: { pickerTargetVideoId = video.id },
                        onPlay: {
                            if let version = latestReady(video) { playing = (video, version) }
                        },
                        onDelete: { Task { await deleteVideo(video) } }
                    )
                }
                if canEdit {
                    Button {
                        Task { await addVideo() }
                    } label: {
                        Label(videos.isEmpty ? language.t("videoPanelView.video") : language.t("videoPanelView.anotherVideo"), systemImage: "plus")
                            .font(.subheadline)
                    }
                } else if videos.isEmpty {
                    Text(language.t("videoPanelView.noVideosYet"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task { await load() }
        .photosPicker(
            isPresented: Binding(get: { pickerTargetVideoId != nil }, set: { if !$0 { pickerTargetVideoId = nil } }),
            selection: $pickerItem, matching: .videos
        )
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem, let videoId = pickerTargetVideoId else { return }
            pickerTargetVideoId = nil
            pickerItem = nil
            Task { await handlePicked(newItem, videoId: videoId) }
        }
        .fullScreenCover(item: Binding(
            get: { playing.map { PlayingVideo(video: $0.video, version: $0.version) } },
            set: { if $0 == nil { playing = nil } }
        )) { item in
            VideoPlayerSheet(video: item.video, version: item.version) { updated in
                if let index = videos.firstIndex(where: { $0.id == item.video.id }),
                   let vIndex = videos[index].versions.firstIndex(where: { $0.id == updated.id }) {
                    videos[index].versions[vIndex] = updated
                }
            }
        }
    }

    private func latestReady(_ video: Video) -> VideoVersion? {
        video.versions.last(where: { $0.status == "ready" })
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            videos = try await APIClient.shared.listVideos(sectionId: sectionId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addVideo() async {
        do {
            let created = try await APIClient.shared.createVideo(sectionId: sectionId, title: "\(language.t("videoPanelView.video")) \(videos.count + 1)", sortOrder: videos.count)
            videos.append(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteVideo(_ video: Video) async {
        do {
            try await APIClient.shared.deleteVideo(video.id)
            videos.removeAll { $0.id == video.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handlePicked(_ item: PhotosPickerItem, videoId: String) async {
        uploadingVideoId = videoId
        defer { uploadingVideoId = nil }
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                errorMessage = language.t("videoPanelView.videoLoadFailed")
                return
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let filename = movie.url.lastPathComponent
            let contentType = movie.url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
            let version = try await APIClient.shared.createVideoVersion(videoId: videoId, filename: filename, contentType: contentType)
            guard let uploadURLString = version.playbackUrl, let uploadURL = URL(string: uploadURLString) else {
                errorMessage = language.t("videoPanelView.noUploadUrl")
                return
            }
            try await APIClient.shared.uploadVideoFile(to: uploadURL, fileURL: movie.url, contentType: contentType)
            let fileSize = try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? Int
            let duration = try? await AVURLAsset(url: movie.url).load(.duration).seconds
            let completed = try await APIClient.shared.completeVideoVersion(version.id, fileSizeBytes: fileSize, durationSeconds: duration)
            if let index = videos.firstIndex(where: { $0.id == videoId }) {
                videos[index].versions.append(completed)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PlayingVideo: Identifiable {
    let video: Video
    let version: VideoVersion
    var id: String { version.id }
}

/// PhotosPicker's Data-loading Transferable would pull an entire video into
/// memory at once — for anything beyond a few seconds of footage that's
/// both slow and a likely memory-pressure crash. This FileRepresentation-
/// based Transferable copies the picked video straight to a temp file
/// instead, so upload can stream from disk (see APIClient.uploadVideoFile's
/// own doc comment on why it uses `upload(for:fromFile:)`).
/// Not `private` (2026-07-21, #284) — PostproductionListView's own tile
/// grid reuses this exact same picked-video-to-temp-file step for its
/// empty-tile/"+" upload flows, no reason to duplicate it.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

private struct VideoRow: View {
    @ObservedObject private var language = AppLanguage.shared
    let video: Video
    let canEdit: Bool
    let uploading: Bool
    let onUploadTap: () -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

    private var readyVersion: VideoVersion? { video.versions.last(where: { $0.status == "ready" }) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title).font(.subheadline.weight(.semibold))
                if let readyVersion {
                    Text(language.t("videoPanelView.versionCommentsLabel")
                        .replacingOccurrences(of: "{number}", with: "\(readyVersion.versionNumber)")
                        .replacingOccurrences(of: "{count}", with: "\(readyVersion.comments.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(language.t("videoPanelView.noVideoUploaded")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uploading {
                ProgressView()
            } else {
                if readyVersion != nil {
                    Button(language.t("videoPanelView.play"), action: onPlay).buttonStyle(.bordered).controlSize(.small)
                }
                if canEdit {
                    Button(readyVersion == nil ? language.t("videoPanelView.upload") : language.t("videoPanelView.newVersion"), action: onUploadTap)
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if canEdit {
                Menu {
                    Button(language.t("videoPanelView.deleteVideo"), role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
