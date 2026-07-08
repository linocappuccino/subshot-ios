import SwiftUI
import MapKit

/// Reminders' "New List" sheet, adapted for Scenes: a name field + color
/// swatch grid, plus a description and cover photo. Used both to create a
/// scene (opens automatically right after tapping "Szene hinzufügen" — no
/// more silently-created "Unbenannte Szene" with no way to name it) and to
/// rename/re-color/re-describe an existing one (tap a scene header).
struct SceneEditSheet: View {
    /// Common cinema/photo lens reference stops — a wheel with every integer
    /// from 10-400 would be 391 entries to scroll through for no real benefit,
    /// nobody dials in "247mm". `nil` (front of the list) means "not set".
    static let focalLengths: [Int?] = [nil, 10, 12, 14, 16, 18, 20, 24, 28, 35, 40, 50, 65, 85, 100, 135, 150, 200, 300, 400]
    /// Estimated scene length, offered in 5-minute steps — matches how a
    /// shooting schedule is actually blocked out, no one dials in "37 Min.".
    static let durations: [Int?] = [nil] + stride(from: 5, through: 240, by: 5).map { $0 }

    let existing: Scene?
    /// "Zwischenschritt" — a lighter-weight scene variant for connective
    /// beats that don't need the full treatment: same core fields (name,
    /// color, description, date/duration, location) but no cover image,
    /// dialogue, focal length, or shot list. Not a separate backend concept,
    /// purely which Form sections this sheet shows.
    let isIntermediateStep: Bool
    @ObservedObject var viewModel: ShotListViewModel
    /// Returns the created/renamed scene so a picked-but-not-yet-uploaded
    /// image can be attached right after — matters for brand-new scenes,
    /// which have no id (and thus nowhere to upload to) until this returns.
    var onSave: (String, String, String, String, Int?, Date?, Int?) async -> Scene?
    var onImagePicked: ((Scene, UIImage) async -> Void)?

    @State private var name: String
    @State private var color: String
    @State private var description: String
    @State private var dialogue: String
    @State private var focalLength: Int?
    @State private var hasDate: Bool
    @State private var scheduledDate: Date
    @State private var durationMinutes: Int?
    @State private var uploadedImage: UIImage?
    @State private var isAddingShot = false
    @State private var newShotText = ""
    @FocusState private var newShotFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        existing: Scene?,
        isIntermediateStep: Bool = false,
        viewModel: ShotListViewModel,
        onSave: @escaping (String, String, String, String, Int?, Date?, Int?) async -> Scene?,
        onImagePicked: ((Scene, UIImage) async -> Void)? = nil
    ) {
        self.existing = existing
        self.isIntermediateStep = isIntermediateStep
        self.viewModel = viewModel
        self.onSave = onSave
        self.onImagePicked = onImagePicked
        _name = State(initialValue: existing?.name ?? "")
        _color = State(initialValue: existing?.color ?? Color.subshotPalette[0])
        _description = State(initialValue: existing?.description ?? "")
        _dialogue = State(initialValue: existing?.dialogue ?? "")
        _focalLength = State(initialValue: existing?.focalLengthMm)
        _hasDate = State(initialValue: existing?.scheduledAt != nil)
        _scheduledDate = State(initialValue: existing?.scheduledAt ?? Date())
        _durationMinutes = State(initialValue: existing?.durationMinutes)
    }

    var body: some View {
        NavigationStack {
            Form {
                // First thing in the sheet, and available immediately even
                // while creating a brand-new scene — picking a photo just
                // stages it locally (ImageSourceButton's onImagePicked) and
                // it uploads once "Fertig" actually creates/saves the scene
                // (see the toolbar button below), since uploading needs a
                // scene id a new scene doesn't have yet.
                if !isIntermediateStep {
                    Section("Bild") {
                        ImageSourceButton(onImagePicked: { uploadedImage = $0 }) {
                            HStack {
                                if let uploadedImage {
                                    Image(uiImage: uploadedImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else if let imageUrl = existing?.imageUrl {
                                    AsyncShotThumbnail(path: imageUrl, size: 60)
                                } else {
                                    Image(systemName: "photo.fill")
                                        .frame(width: 60, height: 60)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Text((uploadedImage == nil && existing?.imageUrl == nil) ? "Bild hinzufügen" : "Bild ändern")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }

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
                    TextField("z.B. Handlung, Notizen", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                if !isIntermediateStep {
                    Section("Dialog") {
                        TextField("Gesprochener Text", text: $dialogue, axis: .vertical)
                            .lineLimit(3...6)
                    }
                }

                Section("Datum & Uhrzeit") {
                    Toggle("Drehtermin festlegen", isOn: $hasDate.animation(.spring(response: 0.35, dampingFraction: 0.86)))
                    if hasDate {
                        // Default (.compact) style in a Form — tap the value to get the
                        // standard system calendar+wheel popover, same as Reminders/Calendar.
                        DatePicker("Termin", selection: $scheduledDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                if hasDate {
                    // Only meaningful once a start time exists — the live/countdown
                    // badge on the scene card is scheduledAt + durationMinutes.
                    Section("Geschätzte Länge") {
                        Picker("Länge", selection: $durationMinutes) {
                            ForEach(Self.durations, id: \.self) { mins in
                                Text(mins.map { "\($0) Min." } ?? "–").tag(mins)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                }

                if !isIntermediateStep {
                    Section("Brennweite") {
                        Picker("Brennweite", selection: $focalLength) {
                            ForEach(Self.focalLengths, id: \.self) { mm in
                                Text(mm.map { "\($0)mm" } ?? "–").tag(mm)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                }

                // Same reasoning as "Einstellungen" below: location is patched
                // straight onto the scene via its own dedicated endpoint call,
                // which needs an id a not-yet-created scene doesn't have.
                if let existing {
                    Section("Location") {
                        SceneLocationSection(scene: existing, viewModel: viewModel)
                    }
                }

                if let existing {
                    Section("Priorität") {
                        ScenePrioritySection(scene: existing, viewModel: viewModel)
                    }
                }

                // Managing shots (like the cover photo below) only makes sense
                // for an existing scene — a not-yet-created one has no id to
                // attach a shot to. Not offered for Zwischenschritt scenes at
                // all (they're connective beats, not shot lists).
                if let existing, !isIntermediateStep {
                    Section("Einstellungen") {
                        ForEach(viewModel.shots(in: existing)) { shot in
                            Text(shot.description?.isEmpty == false ? shot.description! : "Ohne Beschreibung")
                                .strikethrough(shot.status == .done)
                                .foregroundStyle(shot.status == .done ? .secondary : .primary)
                        }
                        if isAddingShot {
                            TextField("Neue Einstellung", text: $newShotText)
                                .focused($newShotFocused)
                                .submitLabel(.done)
                                .onSubmit { Task { await addShot(to: existing) } }
                        } else {
                            Button {
                                isAddingShot = true
                                newShotText = ""
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    newShotFocused = true
                                }
                            } label: {
                                Label("Einstellung hinzufügen", systemImage: "plus")
                            }
                        }
                    }
                }

            }
            .navigationTitle(existing != nil ? "Szene bearbeiten" : (isIntermediateStep ? "Neuer Zwischenschritt" : "Neue Szene"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        Task {
                            let saved = await onSave(
                                name.trimmingCharacters(in: .whitespacesAndNewlines),
                                color,
                                description.trimmingCharacters(in: .whitespacesAndNewlines),
                                dialogue.trimmingCharacters(in: .whitespacesAndNewlines),
                                focalLength,
                                hasDate ? scheduledDate : nil,
                                hasDate ? durationMinutes : nil
                            )
                            // existing's id never changes on rename, so prefer it when
                            // present; `saved` only matters for a brand-new scene, which
                            // has no id until onSave's createScene call returns one.
                            if let uploadedImage, let target = existing ?? saved {
                                await onImagePicked?(target, uploadedImage)
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func addShot(to scene: Scene) async {
        isAddingShot = false
        await viewModel.createShot(description: newShotText, sceneId: scene.id)
        newShotText = ""
    }
}

/// Per-scene address field, same MKLocalSearchCompleter autocomplete as the
/// project-level LocationSection in ProjectInfoBox — but with its own
/// completer instance rather than reusing `viewModel.locationCompleter`
/// (that one's scoped to the project box; a scene sheet is a modal with its
/// own short lifetime, no scroll-churn risk to guard against here).
private struct SceneLocationSection: View {
    let scene: Scene
    @ObservedObject var viewModel: ShotListViewModel
    @StateObject private var completer = LocationSearchCompleter()
    @State private var query = ""
    @State private var isEditing = false

    var body: some View {
        if let address = scene.locationAddress, !isEditing {
            VStack(alignment: .leading, spacing: 8) {
                if let lat = scene.locationLat, let lng = scene.locationLng {
                    SceneMapThumbnail(lat: lat, lng: lng, size: 200)
                        .frame(maxWidth: .infinity)
                }
                Text(address).font(.subheadline)
                HStack {
                    Button("Ändern") {
                        query = address
                        isEditing = true
                    }
                    .font(.caption)
                    Spacer()
                    Button("Entfernen", role: .destructive) {
                        Task { await viewModel.clearSceneLocation(scene) }
                    }
                    .font(.caption)
                }
            }
        } else {
            TextField("Adresse eingeben", text: $query)
                .onChange(of: query) { _, newValue in
                    completer.update(query: newValue)
                }
            if !completer.results.isEmpty {
                ForEach(completer.results.prefix(5), id: \.self) { result in
                    Button {
                        Task { await select(result) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).font(.footnote).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) async {
        guard let resolved = try? await LocationSearch.resolve(completion) else { return }
        await viewModel.updateSceneLocation(scene, address: resolved.address, lat: resolved.lat, lng: resolved.lng)
        isEditing = false
        completer.clear()
        query = ""
    }
}

/// Same segmented-picker pattern as ShotDetailSheet's priority field, colored
/// per option (must=red, should=orange, optional=gray — matches ShotCard's
/// priorityColor) so the picker itself previews what the scene tile's badge
/// will look like.
private struct ScenePrioritySection: View {
    let scene: Scene
    @ObservedObject var viewModel: ShotListViewModel

    var body: some View {
        Picker("Priorität", selection: Binding(
            get: { scene.priority },
            set: { newValue in Task { await viewModel.updateScenePriority(scene, priority: newValue) } }
        )) {
            Text("Keine").tag(ShotPriority?.none)
            ForEach(ShotPriority.allCases) { p in
                Text(p.label).tag(ShotPriority?.some(p))
            }
        }
        .pickerStyle(.segmented)
    }
}
