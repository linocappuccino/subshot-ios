import SwiftUI
import PhotosUI

/// Apple-standard "Foto aufnehmen" / "Aus Mediathek wählen" action sheet in
/// one button — PhotosPicker alone has no camera option, so this also wraps
/// UIImagePickerController for the camera case. Used by both SceneEditSheet
/// and ShotDetailSheet's image row.
struct ImageSourceButton<Label: View>: View {
    var onImagePicked: (UIImage) -> Void
    @ViewBuilder var label: () -> Label

    @ObservedObject private var language = AppLanguage.shared
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
        .confirmationDialog(language.t("imageSourceButton.title"), isPresented: $showingDialog, titleVisibility: .hidden) {
            // The half-second delay isn't decorative — setting showingLibrary/
            // showingCamera in the same runloop tick as the confirmationDialog
            // dismissing itself is a known SwiftUI race (the new presentation
            // request gets silently dropped while the dialog is still
            // mid-dismissal). This was "Bild hinzufügen tut nichts" in practice.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(language.t("imageSourceButton.takePhoto")) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingCamera = true }
                }
            }
            Button(language.t("imageSourceButton.chooseFromLibrary")) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingLibrary = true }
            }
            Button(language.t("imageSourceButton.cancel"), role: .cancel) {}
        }
        // .photosPicker(isPresented:) is the programmatic-trigger form —
        // PhotosPicker itself only works as a self-presenting control, which
        // doesn't fit "one of two options in a dialog I already built".
        .photosPicker(isPresented: $showingLibrary, selection: $photosPickerItem, matching: .images)
        .onChange(of: photosPickerItem) { _, newItem in
            Task {
                guard let newItem, let data = try? await newItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                onImagePicked(image)
                photosPickerItem = nil
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

/// Thin UIImagePickerController wrapper — SwiftUI has no native camera-capture
/// view; this is still Apple's own recommended way to get one.
/// Not `private` (2026-07-22, #297) — IdeaMediaSourceButton (idea images/
/// videos) reuses this exact same photo-capture step for its own "Foto
/// aufnehmen" option, same reasoning as MovieFile in VideoPanelView.swift
/// being made internal for reuse rather than duplicated.
struct CameraCapture: UIViewControllerRepresentable {
    var onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
