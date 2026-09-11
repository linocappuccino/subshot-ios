import SwiftUI
import AVKit
import PhotosUI

/// 2026-09-08, Lino: "in einer shotlist soll man die möglichkeit haben ganz
/// oben ein beispielvideo hochzuladen das man dann als referenz abspielen
/// lassen kann... der button soll heissen 'scribble Video hinzufügen'" —
/// web-parity counterpart to ReferenceVideoBlock.tsx, shown inside the
/// currently open shotlist in ShotListView.swift. Same presign-then-complete
/// upload flow as PostproductionListView's video uploads, driven by
/// ShotListViewModel.uploadReferenceVideo/deleteReferenceVideo.
///
/// 2026-09-10, Lino: "das scribble Video wird jetzt bei jeder shotlist
/// dargestellt im projekt.. jede shotlist hat aber ihr eigenes scribble
/// video!" — was one video for the whole project (every shotlist showed the
/// same one); now takes the specific open `section`.
///
/// 2026-09-11 (same day), Lino: "man soll mehrere scribble videos hochladen
/// können, diese werden dann nebeneinander angezeigt aber genau gleiche
/// logik wie bisher. Am besten wird das erste hochgeladene Video mit V1
/// markiert, das zweite mit V2.. wenn die zeile mit videos gefüllt ist wird
/// unter den videos ein weiteres angezeigt" — web-parity: a real list
/// (`section.referenceVideos`) rendered as a `LazyVGrid` of same-size tiles
/// (adaptive columns wrap to a new row once one fills, same idea as the
/// web's `flex-wrap`) plus a trailing "add" tile. "V1"/"V2"/... is each
/// tile's 1-based position in that array, not a stored field.
///
/// 2026-09-11 (later same day), Lino: "man muss aber die videos in der
/// reihenfolge verschieben können wenn man in der web app oder ios app
/// ist... von links nach rechts ist es aber immer V1, V2" — drag-to-reorder
/// via `.draggable`/`.dropDestination`, same pattern ShotListView already
/// uses for section/scene reordering (see its own doc comments), scoped to
/// just this grid (own drag payload prefix "referenceVideo:", never
/// confused with "section:"/"scene:" drags elsewhere on this screen).
///
/// 2026-09-08, same session, Lino: "es soll ein thumbnail dargestellt
/// werden und wenn man darauf klickt, soll sich das video in einer
/// lightbox öffnen (auch in der ios app)... das video thumbnail soll dann
/// auch immer ein zentriertes gesicht sein" — tappable AsyncShotThumbnail
/// (same face-focus-pan component ProjectFolder cover photos already use)
/// that opens ReferenceVideoLightboxView full-screen.
/// UNVERIFIED — no compiler here, see project memory (iOS: no compiler here).
struct ReferenceVideoBlockView: View {
    let section: SceneSection
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject private var language = AppLanguage.shared

    @State private var showingLibrary = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var deleteTargetId: String?
    @State private var lightboxVideo: ReferenceVideo?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(section.referenceVideos.enumerated()), id: \.element.id) { index, video in
                tile(video: video, label: "V\(index + 1)")
            }
            addTile
        }
        .photosPicker(isPresented: $showingLibrary, selection: $pickerItem, matching: .videos)
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            pickerItem = nil
            Task { await handlePicked(newItem) }
        }
        .alert(language.t("referenceVideo.deleteTitle"), isPresented: Binding(
            get: { deleteTargetId != nil },
            set: { newValue in if !newValue { deleteTargetId = nil } }
        )) {
            Button(language.t("common.cancel"), role: .cancel) {}
            Button(language.t("common.delete"), role: .destructive) {
                if let videoId = deleteTargetId {
                    Task { await viewModel.deleteReferenceVideo(sectionId: section.id, videoId: videoId) }
                }
            }
        } message: {
            Text(language.t("referenceVideo.deleteMessage"))
        }
        .fullScreenCover(item: $lightboxVideo) { video in
            if let urlString = video.url, let url = URL(string: urlString) {
                ReferenceVideoLightboxView(url: url)
            }
        }
    }

    @ViewBuilder
    private func tile(video: ReferenceVideo, label: String) -> some View {
        switch video.status ?? "" {
        case "uploading":
            statusTile(text: language.t("postproductionListView.uploading"))
        case "processing":
            // 2026-09-10, Lino: "das scribble Video braucht extrem lange
            // zu laden wenn man es abspielt! wird es komprimiert?" —
            // web-parity with ReferenceVideoBlock.tsx's own "processing"
            // branch: client's own upload already finished, the backend's
            // web-compression pass is what's running now.
            statusTile(text: language.t("referenceVideo.processing"))
        case "ready":
            if video.url != nil {
                readyTile(video: video, label: label)
            }
        default:
            EmptyView()
        }
    }

    private func statusTile(text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    @ViewBuilder
    private func readyTile(video: ReferenceVideo, label: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                lightboxVideo = video
            } label: {
                ZStack {
                    if let thumbUrl = video.thumbnailUrl {
                        AsyncShotThumbnail(
                            path: thumbUrl, size: nil, lockAspectRatio: false,
                            focusPoint: video.thumbnailFocusPoint
                        )
                    } else {
                        // Face-centered thumbnail still generating server-side
                        // (background task after complete, picks up
                        // automatically on this view model's next poll) — a
                        // plain placeholder in the meantime is enough here,
                        // no separate stall-detection needed per tile (the
                        // whole section still refreshes every ~12s regardless).
                        Image(systemName: "film")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Circle()
                        .fill(.black.opacity(0.45))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.t("referenceVideo.play"))

            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.5)))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)

            Menu {
                Button(role: .destructive) {
                    deleteTargetId = video.id
                } label: {
                    Label(language.t("common.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(8)
        }
        .draggable("referenceVideo:\(video.id)")
        .dropDestination(for: String.self) { ids, _ in
            guard let raw = ids.first, raw.hasPrefix("referenceVideo:") else { return false }
            let draggedId = String(raw.dropFirst("referenceVideo:".count))
            guard draggedId != video.id else { return false }
            var order = section.referenceVideos.map { $0.id }
            guard let fromIdx = order.firstIndex(of: draggedId) else { return false }
            order.remove(at: fromIdx)
            let insertIdx = order.firstIndex(of: video.id) ?? order.count
            order.insert(draggedId, at: insertIdx)
            Task { await viewModel.reorderReferenceVideos(sectionId: section.id, orderedVideoIds: order) }
            return true
        }
    }

    private var addTile: some View {
        Button {
            showingLibrary = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                Text(language.t("referenceVideo.upload"))
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(.tertiary)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.referenceVideoUploading)
    }

    private func handlePicked(_ item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: MovieFile.self) else { return }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let filename = movie.url.lastPathComponent
        let contentType = movie.url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        await viewModel.uploadReferenceVideo(sectionId: section.id, fileURL: movie.url, filename: filename, contentType: contentType)
    }
}
