import SwiftUI

struct ShotDetailSheet: View {
    @State var shot: Shot
    @ObservedObject var viewModel: ShotListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var description: String
    @State private var durationText: String
    @State private var cameraAngle: CameraAngle
    @State private var customAngleText: String
    @State private var priority: ShotPriority?
    @State private var goodTake: String
    @State private var uploadedImage: UIImage?
    @State private var isSaving = false

    init(shot: Shot, viewModel: ShotListViewModel) {
        _shot = State(initialValue: shot)
        self.viewModel = viewModel
        _description = State(initialValue: shot.description ?? "")
        _durationText = State(initialValue: shot.durationSeconds.map(String.init) ?? "")
        let known = CameraAngle.allCases.first { $0.rawValue == shot.cameraAngle }
        _cameraAngle = State(initialValue: known ?? (shot.cameraAngle == nil ? .wide : .other))
        _customAngleText = State(initialValue: known == nil ? (shot.cameraAngle ?? "") : "")
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

                Section("Kamerawinkel") {
                    Picker("Winkel", selection: $cameraAngle) {
                        ForEach(CameraAngle.allCases) { angle in
                            Text(angle.rawValue).tag(angle)
                        }
                    }
                    if cameraAngle == .other {
                        TextField("Eigener Winkel", text: $customAngleText)
                    }
                }

                Section("Dauer (Sekunden)") {
                    TextField("z.B. 8", text: $durationText)
                        .keyboardType(.numberPad)
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
        let angleValue: String? = cameraAngle == .other ? customAngleText : cameraAngle.rawValue
        do {
            let trimmedGoodTake = goodTake.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = try await APIClient.shared.patchShotFull(
                shot.id,
                description: description,
                durationSeconds: Int(durationText),
                cameraAngle: angleValue,
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
