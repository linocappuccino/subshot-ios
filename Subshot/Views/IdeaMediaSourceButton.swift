import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Idea-specific counterpart to ImageSourceButton (2026-07-22, web parity
/// #297 — idea images can now also be real video files or GIFs, mirrors the
/// web app's file input `accept="image/...,video/mp4,video/quicktime,
/// video/webm"`, see lib/media.ts + AuthVideo.tsx). Scene/Shot cover photos
/// stay photo-only on purpose (see the backend's `_ALLOWED_IDEA_MEDIA_TYPES`
/// doc comment in app/main.py — this is an idea-only capability), so this is
/// a SEPARATE component rather than widening ImageSourceButton's shared
/// `.photosPicker(matching: .images)` filter for every one of its callers.
///
/// Camera capture stays photo-only, same as ImageSourceButton — Lino never
/// asked for in-app video *recording*, only picking existing library
/// videos/GIFs (the web app's own plain `<input type="file">` has no camera
/// step at all either, this only widens what the LIBRARY picker accepts).
struct IdeaMediaSourceButton<Label: View>: View {
    @ObservedObject private var language = AppLanguage.shared
    var onImagePicked: (UIImage) -> Void
    /// `fileURL` is a local temp copy (see MovieFile in VideoPanelView.swift)
    /// — the caller uploads it and is responsible for deleting it afterward
    /// (see ShotListViewModel.uploadIdeaVideo's own `defer` cleanup).
    var onVideoPicked: (_ fileURL: URL, _ contentType: String) -> Void
    @ViewBuilder var label: () -> Label

    @State private var showingDialog = false
    @State private var showingLibrary = false
    @State private var showingCamera = false
    @State private var photosPickerItem: PhotosPickerItem?

    var body: some View {
        Button {
            showingDialog = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        // Same 0.4s post-dismissal delay as ImageSourceButton — setting
        // showingLibrary/showingCamera in the same runloop tick as the
        // confirmationDialog dismissing itself is a known SwiftUI race (the
        // new presentation request gets silently dropped mid-dismissal).
        .confirmationDialog(language.t("ideaMediaSourceButton.dialogTitle"), isPresented: $showingDialog, titleVisibility: .hidden) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(language.t("ideaMediaSourceButton.takePhoto")) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingCamera = true }
                }
            }
            Button(language.t("ideaMediaSourceButton.chooseFromLibrary")) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingLibrary = true }
            }
            Button(language.t("ideaMediaSourceButton.cancel"), role: .cancel) {}
        }
        // .any(of: [.images, .videos]) — the one real difference from
        // ImageSourceButton's `.images`-only filter. `.images` already
        // includes animated GIFs (PHPickerFilter's own definition), so no
        // separate GIF case is needed here; onChange below just checks
        // whether the picked item's UTType conforms to `.movie` to decide
        // which branch to take.
        .photosPicker(isPresented: $showingLibrary, selection: $photosPickerItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photosPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                defer { photosPickerItem = nil }
                let isVideo = newItem.supportedContentTypes.contains { $0.conforms(to: .movie) }
                if isVideo {
                    guard let movie = try? await newItem.loadTransferable(type: MovieFile.self) else { return }
                    let ext = movie.url.pathExtension.lowercased()
                    let contentType: String
                    switch ext {
                    case "mov": contentType = "video/quicktime"
                    case "webm": contentType = "video/webm"
                    default: contentType = "video/mp4"
                    }
                    onVideoPicked(movie.url, contentType)
                } else {
                    // Covers both plain images and GIFs — UIImage(data:)
                    // decodes a GIF fine, just as its static first frame
                    // (see MediaKind.swift's isGifUrl doc comment for why
                    // that's a known, flagged gap rather than a bug).
                    guard let data = try? await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    onImagePicked(image)
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in
                showingCamera = false
                if let image { onImagePicked(image) }
            }
            .ignoresSafeArea()
        }
    }
}
