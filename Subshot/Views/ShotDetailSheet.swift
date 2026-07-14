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

    // Camera settings (2026-07-13, Lino) — re-added after having been
    // deliberately dropped from this sheet earlier ("nicht so viel
    // informationen die man eingeben kann"): a later, more specific request
    // asked for every one of these fields by name, superseding that
    // simplification for camera settings specifically. Shutterangle starts
    // pre-filled with "180" for a shot that has none yet (his explicit
    // default), everything else starts empty.
    @State private var cameraAngle: String
    @State private var lens: String
    @State private var fStop: String
    @State private var frameRate: String
    @State private var shutterAngle: String
    @State private var iso: String
    @State private var codec: String
    @State private var cameraId: String
    @State private var cameraSupport: CameraSupport?

    init(shot: Shot, viewModel: ShotListViewModel) {
        _shot = State(initialValue: shot)
        self.viewModel = viewModel
        _description = State(initialValue: shot.description ?? "")
        _priority = State(initialValue: shot.priority)
        _goodTake = State(initialValue: shot.goodTakeFilename ?? "")
        _cameraAngle = State(initialValue: shot.cameraAngle ?? "")
        _lens = State(initialValue: shot.lens ?? "")
        _fStop = State(initialValue: shot.fStop ?? "")
        _frameRate = State(initialValue: shot.frameRate ?? "")
        _shutterAngle = State(initialValue: shot.shutterAngle.map { String(format: "%g", $0) } ?? "180")
        _iso = State(initialValue: shot.iso.map(String.init) ?? "")
        _codec = State(initialValue: shot.codec ?? "")
        _cameraId = State(initialValue: shot.cameraId ?? "")
        _cameraSupport = State(initialValue: shot.cameraSupport)
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

                Section("Kamera") {
                    // Autocorrect/autocapitalization off on every technical
                    // field here (2026-07-14, Lino: "die typischen apple
                    // eingabe optionen") — same reasoning as Good Take above:
                    // values like "T2.8", "ProRes422", "50mm" are codes, not
                    // sentences, and iOS's default text behavior kept
                    // capitalizing/correcting them into nonsense.
                    TextField("Kamera-ID (A, B, C…)", text: $cameraId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Winkel", text: $cameraAngle)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Objektiv", text: $lens)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("F-Stop", text: $fStop)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Framerate", text: $frameRate)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Shutterangle", text: $shutterAngle)
                        .keyboardType(.decimalPad)
                    TextField("ISO", text: $iso)
                        .keyboardType(.numberPad)
                    TextField("Codec", text: $codec)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Aufnahme-Art", selection: $cameraSupport) {
                        Text("Keine").tag(CameraSupport?.none)
                        ForEach(CameraSupport.allCases) { support in
                            Text(support.label).tag(CameraSupport?.some(support))
                        }
                    }
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
            // Passes the shot's EXISTING durationSeconds back unchanged (not
            // nil) — patchShotFull always includes every key in its JSON
            // body, and the backend treats a present-but-null field as
            // "clear it" (see app/main.py's patch_shot), so nil here would
            // silently wipe durationSeconds even though this sheet doesn't
            // offer a way to edit it.
            let updated = try await APIClient.shared.patchShotFull(
                shot.id,
                description: description,
                durationSeconds: shot.durationSeconds,
                cameraAngle: cameraAngle.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cameraAngle,
                priority: priority?.rawValue,
                goodTakeFilename: trimmedGoodTake.isEmpty ? nil : trimmedGoodTake,
                lens: lens.trimmingCharacters(in: .whitespaces).isEmpty ? nil : lens,
                fStop: fStop.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fStop,
                frameRate: frameRate.trimmingCharacters(in: .whitespaces).isEmpty ? nil : frameRate,
                shutterAngle: Double(shutterAngle),
                iso: Int(iso),
                codec: codec.trimmingCharacters(in: .whitespaces).isEmpty ? nil : codec,
                cameraId: cameraId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cameraId,
                cameraSupport: cameraSupport?.rawValue
            )
            viewModel.replace(updated)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        dismiss()
    }
}
