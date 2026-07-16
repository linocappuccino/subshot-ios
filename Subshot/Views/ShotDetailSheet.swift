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
    /// Autosave (2026-07-16, Lino: "es muss alles was man aendert in allen
    /// Kacheln sofort gespeichert werden") — pending debounced save, see
    /// SceneEditSheet's own scheduleAutosave doc comment for the same
    /// coalescing reasoning. Photo add/remove already autosave separately
    /// (handlePhotoPicked/removePhoto above, pre-existing), this covers the
    /// rest: description, priority, good take, all camera settings.
    @State private var autosaveTask: Task<Void, Never>?

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

    // 2026-07-14, Lino: free-text Objektiv/F-Stop/ISO invited inconsistent
    // values and typos — pickers over the real-world range instead. Each
    // Binding parses/formats through the existing String @State var above
    // rather than adding parallel numeric state, so save() (which already
    // reads lens/fStop/iso as Strings) needed no changes at all.
    private var lensMMBinding: Binding<Int> {
        Binding(
            get: { Int(lens.filter(\.isNumber)) ?? 50 },
            set: { lens = "\($0)mm" }
        )
    }
    private var fStopBinding: Binding<Double> {
        Binding(
            get: { Double(fStop.replacingOccurrences(of: "f/", with: "")) ?? 2.8 },
            set: { fStop = String(format: "f/%.1f", $0) }
        )
    }
    private var isoBinding: Binding<Int> {
        Binding(
            get: { Int(iso) ?? 800 },
            set: { iso = "\($0)" }
        )
    }
    private static let lensRange = Array(0...1000)
    // Built from integer tenths (17/10.0), not stride's cumulative 1.0+0.1*n
    // additions — stride can drift by a ULP or two over 190 steps, which
    // would make the Picker's Double tag fail to exactly match the value
    // fStopBinding.get parses back out of the string, breaking selection
    // highlighting.
    private static let fStopRange = (10...200).map { Double($0) / 10.0 }
    private static let isoRange = Array(stride(from: 50, through: 50000, by: 50))
    // Standard PAL (25/50)- and NTSC (23.976/29.97/59.94)-family rates, plus
    // plain 24/30/60 — covers what a shoot actually sets a camera to, rather
    // than any arbitrary typed number.
    private static let frameRateOptions = ["23.976", "24", "25", "29.97", "30", "50", "59.94", "60"]

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
                    // 2026-07-14, Lino: photo had no remove option before,
                    // only add/replace.
                    if uploadedImage != nil || shot.imageUrl != nil {
                        Button(role: .destructive) {
                            Task { await removePhoto() }
                        } label: {
                            Label("Foto entfernen", systemImage: "trash")
                        }
                    }
                }

                Section("Beschreibung") {
                    TextField("z.B. Weitwinkel Establishing Shot", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: description) { _, _ in scheduleAutosave() }
                }

                Section("Priorität") {
                    // 2026-07-17 — same colored picker as SceneEditSheet
                    // (PrioritySegmentedControl, defined there), matching the
                    // web app's per-priority-color switch on both tiles.
                    PrioritySegmentedControl(priority: $priority)
                        .onChange(of: priority) { _, _ in scheduleAutosave() }
                }

                // For noting the keeper take's filename on set, once picture
                // has called it — a plain free-text field, not tied to any
                // file-naming convention.
                Section("Good Take:") {
                    TextField("Dateiname, z.B. A003_C012", text: $goodTake)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: goodTake) { _, _ in scheduleAutosave() }
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
                        .onChange(of: cameraId) { _, _ in scheduleAutosave() }
                    // Objektiv/F-Stop/ISO: picker over the real-world range
                    // instead of free text (2026-07-14) — Winkel removed
                    // entirely per the same request.
                    Picker("Objektiv", selection: lensMMBinding) {
                        ForEach(Self.lensRange, id: \.self) { mm in
                            Text("\(mm)mm").tag(mm)
                        }
                    }
                    .onChange(of: lens) { _, _ in scheduleAutosave() }
                    Picker("F-Stop", selection: fStopBinding) {
                        ForEach(Self.fStopRange, id: \.self) { value in
                            Text(String(format: "f/%.1f", value)).tag(value)
                        }
                    }
                    .onChange(of: fStop) { _, _ in scheduleAutosave() }
                    Picker("Framerate", selection: $frameRate) {
                        Text("Keine").tag("")
                        ForEach(Self.frameRateOptions, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    .onChange(of: frameRate) { _, _ in scheduleAutosave() }
                    TextField("Shutterangle", text: $shutterAngle)
                        .keyboardType(.decimalPad)
                        .onChange(of: shutterAngle) { _, _ in scheduleAutosave() }
                    Picker("ISO", selection: isoBinding) {
                        ForEach(Self.isoRange, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .onChange(of: iso) { _, _ in scheduleAutosave() }
                    TextField("Codec", text: $codec)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: codec) { _, _ in scheduleAutosave() }
                    Picker("Aufnahme-Art", selection: $cameraSupport) {
                        Text("Keine").tag(CameraSupport?.none)
                        ForEach(CameraSupport.allCases) { support in
                            Text(support.label).tag(CameraSupport?.some(support))
                        }
                    }
                    .onChange(of: cameraSupport) { _, _ in scheduleAutosave() }
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

    /// Acts immediately (own PATCH), same as handlePhotoPicked above, rather
    /// than waiting for "Fertig" — matches the add/change photo flow.
    private func removePhoto() async {
        do {
            let trimmedGoodTake = goodTake.trimmingCharacters(in: .whitespacesAndNewlines)
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
                cameraSupport: cameraSupport?.rawValue,
                clearImage: true
            )
            shot = updated
            uploadedImage = nil
            viewModel.replace(updated)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    /// Passes the shot's EXISTING durationSeconds back unchanged (not nil)
    /// — patchShotFull always includes every key in its JSON body, and the
    /// backend treats a present-but-null field as "clear it" (see
    /// app/main.py's patch_shot), so nil here would silently wipe
    /// durationSeconds even though this sheet doesn't offer a way to edit
    /// it. Shared by both the explicit "Fertig" save and the debounced
    /// autosave below — one save path, two triggers.
    private func persistShot() async throws {
        let trimmedGoodTake = goodTake.trimmingCharacters(in: .whitespacesAndNewlines)
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
        shot = updated
        viewModel.replace(updated)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await persistShot()
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        dismiss()
    }

    /// Debounced autosave (2026-07-16) — see SceneEditSheet's own
    /// scheduleAutosave doc comment for the coalescing reasoning; identical
    /// pattern here.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await persistShot()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}
