import SwiftUI

struct ShotDetailSheet: View {
    @State var shot: Shot
    @ObservedObject var viewModel: ShotListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var description: String
    @State private var priority: ShotPriority?
    @State private var goodTake: String
    @State private var uploadedImage: UIImage?
    @State private var isSaving = false

    // camera_angle/duration_seconds are still on the model/API (existing
    // values are preserved — patchShotFull below simply stops sending
    // these two fields) but no longer editable here (Lino: "nicht so viel
    // informationen die man eingeben kann. Es reicht wenn man ein Bild und
    // eine Beschreibung, Prio und einen Good Take eingeben kann"), mirrors
    // the web app's ShotEditModal.tsx simplification.
    init(shot: Shot, viewModel: ShotListViewModel) {
        _shot = State(initialValue: shot)
        self.viewModel = viewModel
        _description = State(initialValue: shot.description ?? "")
        _priority = State(initialValue: shot.priority)
        _goodTake = State(initialValue: shot.goodTakeFilename ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bild") {
                    ImageSourceButton(onImagePicked: { image in
                        Task { await handlePhotoPicked(image) }
                    }) {
                        HStack {
                            if let uploadedImage {
                                Image(uiImage: uploadedImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else if let imageUrl = shot.imageUrl {
                                AsyncShotThumbnail(path: imageUrl, size: 60)
                            } else {
                                Image(systemName: "camera.fill")
                                    .frame(width: 60, height: 60)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Text(shot.imageUrl == nil ? "Foto hinzufügen" : "Foto ändern")
                                .foregroundStyle(.primary)
                        }
                    }
                }

                Section("Beschreibung") {
                    TextField("z.B. Weitwinkel Establishing Shot", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Priorität") {
                    Picker("Priorität", selection: $priority) {
                        Text("Keine").tag(ShotPriority?.none)
                        ForEach(ShotPriority.allCases) { p in
                            Text(p.label).tag(ShotPriority?.some(p))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // For noting the keeper take's filename on set, once picture
                // has called it — a plain free-text field, not tied to any
                // file-naming convention.
                Section("Good Take:") {
                    TextField("Dateiname, z.B. A003_C012", text: $goodTake)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Einstellung bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func handlePhotoPicked(_ image: UIImage) async {
        uploadedImage = image
        do {
            let updated = try await APIClient.shared.uploadShotImage(shotId: shot.id, image: image)
            shot = updated
            viewModel.replace(updated)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmedGoodTake = goodTake.trimmingCharacters(in: .whitespacesAndNewlines)
            // Passes the shot's EXISTING durationSeconds/cameraAngle back
            // unchanged (not nil) — patchShotFull always includes both keys
            // in its JSON body, and the backend treats a present-but-null
            // field as "clear it" (see app/main.py's patch_shot), so nil
            // here would silently wipe any value a shot already had even
            // though this sheet no longer offers a way to edit them.
            let updated = try await APIClient.shared.patchShotFull(
                shot.id,
                description: description,
                durationSeconds: shot.durationSeconds,
                cameraAngle: shot.cameraAngle,
                priority: priority?.rawValue,
                goodTakeFilename: trimmedGoodTake.isEmpty ? nil : trimmedGoodTake
            )
            viewModel.replace(updated)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        dismiss()
    }
}
