import SwiftUI
import PhotosUI

/// Reminders' "New List" sheet, adapted for Scenes: a name field + color
/// swatch grid, plus a description and cover photo. Used both to create a
/// scene (opens automatically right after tapping "Szene hinzufügen" — no
/// more silently-created "Unbenannte Szene" with no way to name it) and to
/// rename/re-color/re-describe an existing one (tap a scene header).
struct SceneEditSheet: View {
    let existing: Scene?
    var onSave: (String, String, String) async -> Void
    var onImagePicked: ((UIImage) async -> Void)?

    @State private var name: String
    @State private var color: String
    @State private var description: String
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadedImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    init(
        existing: Scene?,
        onSave: @escaping (String, String, String) async -> Void,
        onImagePicked: ((UIImage) async -> Void)? = nil
    ) {
        self.existing = existing
        self.onSave = onSave
        self.onImagePicked = onImagePicked
        _name = State(initialValue: existing?.name ?? "")
        _color = State(initialValue: existing?.color ?? Color.subshotPalette[0])
        _description = State(initialValue: existing?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z.B. Küche, Aussen Tag 1", text: $name)
                }
                Section("Farbe") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(Color.subshotPalette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if hex == color {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { color = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Beschreibung") {
                    TextField("z.B. Sprechertext, Handlung, Notizen", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                // Cover photo only for an existing scene — same reasoning as
                // shots: uploading needs a scene id, which a not-yet-created
                // scene doesn't have.
                if let existing {
                    Section("Bild") {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            HStack {
                                if let uploadedImage {
                                    Image(uiImage: uploadedImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else if let imageUrl = existing.imageUrl {
                                    AsyncShotThumbnail(path: imageUrl, size: 60)
                                } else {
                                    Image(systemName: "photo.fill")
                                        .frame(width: 60, height: 60)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Text(existing.imageUrl == nil ? "Bild hinzufügen" : "Bild ändern")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .onChange(of: photoItem) { _, newItem in
                            Task { await handlePhotoPicked(newItem) }
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Neue Szene" : "Szene bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        Task {
                            await onSave(
                                name.trimmingCharacters(in: .whitespacesAndNewlines),
                                color,
                                description.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func handlePhotoPicked(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        uploadedImage = image
        await onImagePicked?(image)
    }
}
