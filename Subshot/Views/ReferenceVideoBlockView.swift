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
/// UNVERIFIED — no compiler here, see project memory (iOS: no compiler here).
struct ReferenceVideoBlockView: View {
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject private var language = AppLanguage.shared

    @State private var showingLibrary = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var confirmingDelete = false
    @State private var player: AVPlayer?

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
            } else if hasVideo, let urlString = viewModel.referenceVideoUrl, let url = URL(string: urlString) {
                ZStack(alignment: .topTrailing) {
                    VideoPlayer(player: player)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .onAppear {
                            if player == nil { player = AVPlayer(url: url) }
                        }
                        .onChange(of: urlString) { _, newValue in
                            guard let newURL = URL(string: newValue) else { return }
                            player = AVPlayer(url: newURL)
                        }
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
    }

    private func handlePicked(_ item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: MovieFile.self) else { return }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let filename = movie.url.lastPathComponent
        let contentType = movie.url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        await viewModel.uploadReferenceVideo(fileURL: movie.url, filename: filename, contentType: contentType)
    }
}
