import SwiftUI
import AVKit
import PhotosUI

/// 2026-09-08, Lino: "in einer shotlist soll man die möglichkeit haben ganz
/// oben ein beispielvideo hochzuladen das man dann als referenz abspielen
/// lassen kann... der button soll heissen 'scribble Video hinzufügen'" —
/// web-parity counterpart to ReferenceVideoBlock.tsx, shown above
/// scriptOverviewGrid() in ShotListView.swift (only on the Skript-
/// Auswahlübersicht, not inside an opened shotlist — this is one video for
/// the whole project, not per Abschnitt). Same presign-then-complete upload
/// flow as PostproductionListView's video uploads, driven by
/// ShotListViewModel.uploadReferenceVideo/deleteReferenceVideo.
///
/// 2026-09-08, same session, Lino: "es soll ein thumbnail dargestellt
/// werden und wenn man darauf klickt, soll sich das video in einer
/// lightbox öffnen (auch in der ios app)... das video thumbnail soll dann
/// auch immer ein zentriertes gesicht sein" — was an always-live inline
/// VideoPlayer; now a tappable AsyncShotThumbnail (same face-focus-pan
/// component ProjectFolder cover photos already use, see its own doc
/// comment) that opens ReferenceVideoLightboxView (new file) full-screen.
/// UNVERIFIED — no compiler here, see project memory (iOS: no compiler here).
struct ReferenceVideoBlockView: View {
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject private var language = AppLanguage.shared

    @State private var showingLibrary = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var confirmingDelete = false
    @State private var showingLightbox = false
    /// 2026-09-08, Lino: "in der ios app wird kein thumbnail vom video
    /// angezeigt" — root cause was a reference video uploaded BEFORE this
    /// thumbnail feature shipped (the backend background task only fires
    /// from complete_reference_video, never retroactively), backfilled once
    /// server-side. This flag is the belt-and-suspenders fix for the same
    /// class of gap happening again (a background job that fails silently,
    /// or just never runs for some other reason): the plain `ProgressView`
    /// fallback below used to spin forever with zero visual feedback if
    /// `referenceVideoThumbnailUrl` never arrives.
    /// 2026-09-08, same day, Lino (live report): "das thumbnail wird
    /// erstellt... aber geht extrem lange" — the backend generation itself
    /// was genuinely slow (~60-90s, see video_processing.
    /// pick_face_thumbnail's own doc comment for the real fix, since
    /// verified live at ~15s), not silently broken. 30s (with a comfortable
    /// margin over that measured time, and >2x this view's own 12s poll
    /// interval so a normal-length video gets at least two chances to pick
    /// the result up) is generous enough that reaching this timeout now
    /// really does mean "not coming", not "still processing".
    @State private var thumbnailTimedOut = false

    private var hasVideo: Bool {
        viewModel.referenceVideoStatus == "ready" && viewModel.referenceVideoUrl != nil
    }

    var body: some View {
        Group {
            if viewModel.referenceVideoUploading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(language.t("postproductionListView.uploading"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
            } else if hasVideo, viewModel.referenceVideoUrl != nil {
                ZStack(alignment: .topTrailing) {
                    Button {
                        showingLightbox = true
                    } label: {
                        ZStack {
                            if let thumbUrl = viewModel.referenceVideoThumbnailUrl {
                                AsyncShotThumbnail(
                                    path: thumbUrl, size: nil, lockAspectRatio: false,
                                    focusPoint: viewModel.referenceVideoThumbnailFocusPoint
                                )
                            } else if thumbnailTimedOut {
                                Image(systemName: "film")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.5))
                            } else {
                                // Face-centered thumbnail is still being generated
                                // server-side (background task after complete —
                                // picks up automatically on the next poll, see
                                // ShotListViewModel.uploadReferenceVideo's doc
                                // comment) — plain placeholder in the meantime,
                                // no live player needed just to show something.
                                ProgressView()
                                    .task {
                                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                                        if viewModel.referenceVideoThumbnailUrl == nil { thumbnailTimedOut = true }
                                    }
                            }
                            Circle()
                                .fill(.black.opacity(0.45))
                                .frame(width: 52, height: 52)
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .offset(x: 2)
                                }
                        }
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.t("referenceVideo.play"))
                    Menu {
                        Button {
                            showingLibrary = true
                        } label: {
                            Label(language.t("referenceVideo.replace"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label(language.t("referenceVideo.delete"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .padding(10)
                }
            } else {
                Button {
                    showingLibrary = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text(language.t("referenceVideo.upload"))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                            .foregroundStyle(.tertiary)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .photosPicker(isPresented: $showingLibrary, selection: $pickerItem, matching: .videos)
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            pickerItem = nil
            Task { await handlePicked(newItem) }
        }
        .alert(language.t("referenceVideo.deleteTitle"), isPresented: $confirmingDelete) {
            Button(language.t("common.cancel"), role: .cancel) {}
            Button(language.t("common.delete"), role: .destructive) {
                Task { await viewModel.deleteReferenceVideo() }
            }
        } message: {
            Text(language.t("referenceVideo.deleteMessage"))
        }
        .onChange(of: viewModel.referenceVideoUploading) { _, uploading in
            if uploading { thumbnailTimedOut = false }
        }
        .fullScreenCover(isPresented: $showingLightbox) {
            if let urlString = viewModel.referenceVideoUrl, let url = URL(string: urlString) {
                ReferenceVideoLightboxView(url: url)
            }
        }
    }

    private func handlePicked(_ item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: MovieFile.self) else { return }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let filename = movie.url.lastPathComponent
        let contentType = movie.url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        await viewModel.uploadReferenceVideo(fileURL: movie.url, filename: filename, contentType: contentType)
    }
}
