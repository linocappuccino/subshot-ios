import SwiftUI
import PhotosUI

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

    let existing: Scene?
    @ObservedObject var viewModel: ShotListViewModel
    /// Returns the created/renamed scene so a picked-but-not-yet-uploaded
    /// image can be attached right after — matters for brand-new scenes,
    /// which have no id (and thus nowhere to upload to) until this returns.
    var onSave: (String, String, String, String, Int?, Date?) async -> Scene?
    var onImagePicked: ((Scene, UIImage) async -> Void)?

    @State private var name: String
    @State private var color: String
    @State private var description: String
    @State private var dialogue: String
    @State private var focalLength: Int?
    @State private var hasDate: Bool
    @State private var scheduledDate: Date
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadedImage: UIImage?
    @State private var isAddingShot = false
    @State private var newShotText = ""
    @FocusState private var newShotFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        existing: Scene?,
        viewModel: ShotListViewModel,
        onSave: @escaping (String, String, String, String, Int?, Date?) async -> Scene?,
        onImagePicked: ((Scene, UIImage) async -> Void)? = nil
    ) {
        self.existing = existing
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
    }

    var body: some View {
        NavigationStack {
            Form {
                // First thing in the sheet, and available immediately even
                // while creating a brand-new scene — picking a photo just
                // stages it locally (handlePhotoPicked) and it uploads once
                // "Fertig" actually creates/saves the scene (see the toolbar
                // button below), since uploading needs a scene id a new
                // scene doesn't have yet.
                Section("Bild") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
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
                    .onChange(of: photoItem) { _, newItem in
                        Task { await handlePhotoPicked(newItem) }
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

                Section("Dialog") {
                    TextField("Gesprochener Text", text: $dialogue, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Datum & Uhrzeit") {
                    Toggle("Drehtermin festlegen", isOn: $hasDate.animation())
                    if hasDate {
                        // Default (.compact) style in a Form — tap the value to get the
                        // standard system calendar+wheel popover, same as Reminders/Calendar.
                        DatePicker("Termin", selection: $scheduledDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section("Brennweite") {
                    Picker("Brennweite", selection: $focalLength) {
                        ForEach(Self.focalLengths, id: \.self) { mm in
                            Text(mm.map { "\($0)mm" } ?? "–").tag(mm)
                        }
                    }
                    .pickerStyle(.wheel)
                }

                // Managing shots (like the cover photo below) only makes sense
                // for an existing scene — a not-yet-created one has no id to
                // attach a shot to.
                if let existing {
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
            .navigationTitle(existing == nil ? "Neue Szene" : "Szene bearbeiten")
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
                                hasDate ? scheduledDate : nil
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

    private func handlePhotoPicked(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        uploadedImage = image
    }

    private func addShot(to scene: Scene) async {
        isAddingShot = false
        await viewModel.createShot(description: newShotText, sceneId: scene.id)
        newShotText = ""
    }
}
