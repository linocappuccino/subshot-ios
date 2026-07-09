import SwiftUI

/// Same Reminders "New List" pattern as ProjectEditSheet/SceneEditSheet, for
/// folders: name, an optional single emoji (shown on the tile instead of a
/// generic folder icon), and a color from the shared palette.
struct FolderEditSheet: View {
    let existing: ProjectFolder?
    var onSave: (String, String, String?, UIImage?, Bool) async -> Void

    @State private var name: String
    @State private var emoji: String
    @State private var color: String
    @State private var uploadedImage: UIImage?
    @State private var clearBackgroundImage = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    init(existing: ProjectFolder?, onSave: @escaping (String, String, String?, UIImage?, Bool) async -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _emoji = State(initialValue: existing?.emoji ?? "")
        _color = State(initialValue: existing?.color ?? Color.subshotPalette[0])
    }

    var body: some View {
        NavigationStack {
            Form {
                // Same stage-locally-then-upload-on-save pattern as
                // SceneEditSheet's cover photo - uploading a brand-new
                // folder's image needs its id, which doesn't exist yet.
                Section("Hintergrundbild") {
                    ImageSourceButton(onImagePicked: {
                        uploadedImage = $0
                        clearBackgroundImage = false
                    }) {
                        HStack {
                            if let uploadedImage {
                                Image(uiImage: uploadedImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else if let bgUrl = existing?.backgroundImageURL, !clearBackgroundImage {
                                AsyncShotThumbnail(path: bgUrl, size: 60)
                            } else {
                                Image(systemName: "photo.fill")
                                    .frame(width: 60, height: 60)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Text((uploadedImage == nil && (existing?.backgroundImageURL == nil || clearBackgroundImage)) ? "Bild hinzufügen" : "Bild ändern")
                                .foregroundStyle(.primary)
                        }
                    }
                    if uploadedImage != nil || (existing?.backgroundImageURL != nil && !clearBackgroundImage) {
                        Button("Bild entfernen", role: .destructive) {
                            uploadedImage = nil
                            clearBackgroundImage = true
                        }
                    }
                }

                Section("Name") {
                    TextField("z.B. Kunde XY", text: $name)
                        .focused($nameFocused)
                }
                Section("Emoji") {
                    TextField("Optional, z.B. 🎬", text: $emoji)
                        // A single emoji is one (extended) grapheme cluster —
                        // trimming to the first one keeps this a one-emoji
                        // field even if someone pastes a run of them.
                        .onChange(of: emoji) { _, newValue in
                            if let first = newValue.first {
                                emoji = String(first)
                            }
                        }
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
            }
            .navigationTitle(existing == nil ? "Neuer Ordner" : "Ordner bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty else { return }
                        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await onSave(trimmedName, color, trimmedEmoji.isEmpty ? nil : trimmedEmoji, uploadedImage, clearBackgroundImage)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { nameFocused = true }
        }
        .preferredColorScheme(.dark)
    }
}
