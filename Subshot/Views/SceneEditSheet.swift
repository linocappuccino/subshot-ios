import SwiftUI

/// Reminders' "New List" sheet, adapted for Scenes: a name field, description
/// and cover photo. Used both to create a scene (opens automatically right
/// after tapping "Szene hinzufügen" — no more silently-created "Unbenannte
/// Szene" with no way to name it) and to rename/re-describe an existing one
/// (tap a scene header). No manual color picker anymore — the scene's
/// accent color now comes from its priority (see ScenePrioritySection
/// below); `color` is still sent to the backend (required field) but fixed,
/// never user-edited.
struct SceneEditSheet: View {
    /// Minutes offered in 5-minute steps within an hour — matches how a
    /// shooting schedule is actually blocked out, no one dials in "37 Min.".
    static let minuteSteps = Array(stride(from: 0, through: 55, by: 5))
    /// 2026-07-13, Lino: "der Timer... bitte mit Stunden/Minuten ergänzen
    /// (nicht nur Minuten)" — was a single wheel of "5 Min." … "240 Min.",
    /// hard to dial in anything over an hour. Two wheels (Stunden/Minuten)
    /// still resolve to the same total-minutes `durationMinutes` the backend
    /// expects, just via `durationHours`/`durationMins` kept in sync with it.
    static let hourSteps = Array(0...8)

    let existing: Scene?
    /// "Zwischenschritt" — a lighter-weight scene variant for connective
    /// beats that don't need the full treatment: same core fields (name,
    /// color, description, date/duration, location) but no cover image,
    /// dialogue, or shot list. Not a separate backend concept, purely which
    /// Form sections this sheet shows.
    let isIntermediateStep: Bool
    @ObservedObject var viewModel: ShotListViewModel
    /// Returns the created/renamed scene so a picked-but-not-yet-uploaded
    /// image can be attached right after — matters for brand-new scenes,
    /// which have no id (and thus nowhere to upload to) until this returns.
    var onSave: (String, String, String, String, Date?, Int?, ShotPriority?) async -> Scene?
    var onImagePicked: ((Scene, UIImage) async -> Void)?

    @State private var name: String
    @State private var color: String
    @State private var description: String
    @State private var hasDate: Bool
    @State private var scheduledDate: Date
    @State private var durationMinutes: Int?
    @State private var durationHours = 0
    @State private var durationMins = 0
    @State private var priority: ShotPriority?
    @State private var uploadedImage: UIImage?
    /// 2026-07-15, Lino: no way to remove a scene's cover photo, only
    /// replace it — mirrors ShotDetailSheet's own removePhoto (shots
    /// already got this 2026-07-14).
    @State private var removingImage = false
    @State private var isAddingShot = false
    @State private var newShotText = ""
    @FocusState private var newShotFocused: Bool
    /// Dialogue lines for a scene that doesn't exist yet — there's no scene
    /// id to attach a SceneDialogue to until "Fertig" actually creates it
    /// (same staging idea as `uploadedImage` above), so these are flushed to
    /// the backend one by one right after `onSave` returns.
    @State private var draftDialogues: [String] = []
    @State private var isAddingDialogue = false
    @State private var newDialogueText = ""
    @FocusState private var newDialogueFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        existing: Scene?,
        isIntermediateStep: Bool = false,
        viewModel: ShotListViewModel,
        onSave: @escaping (String, String, String, String, Date?, Int?, ShotPriority?) async -> Scene?,
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
        _hasDate = State(initialValue: existing?.scheduledAt != nil)
        // A brand-new scene defaults its start time to right when the
        // previous one (by sort_order — the last scene currently in the
        // list) wraps, i.e. its scheduled_at + duration_minutes — not to
        // "now". Only reaches one scene back, not the whole chain: if that
        // previous scene has no date/duration set, this falls through to
        // `Date()` same as before, it does NOT walk further back to find an
        // earlier one that does.
        let suggestedDate: Date? = {
            guard existing == nil else { return nil }
            guard let previous = viewModel.scenes.max(by: { $0.sortOrder < $1.sortOrder }),
                  let previousStart = previous.scheduledAt,
                  let previousDuration = previous.durationMinutes else { return nil }
            return previousStart.addingTimeInterval(TimeInterval(previousDuration * 60))
        }()
        _scheduledDate = State(initialValue: existing?.scheduledAt ?? suggestedDate ?? Date())
        _durationMinutes = State(initialValue: existing?.durationMinutes)
        let totalMinutes = existing?.durationMinutes ?? 0
        _durationHours = State(initialValue: totalMinutes / 60)
        _durationMins = State(initialValue: (totalMinutes % 60) / 5 * 5)
        _priority = State(initialValue: existing?.priority)
    }

    /// Same fix as SceneLocationSection's own `liveScene` below — `existing`
    /// is a one-time snapshot from when the sheet opened, so reading
    /// assigneeId straight off it would show a stale value right after
    /// picking a new assignee until the sheet is reopened.
    private func liveExisting(_ scene: Scene) -> Scene {
        viewModel.scenes.first(where: { $0.id == scene.id }) ?? scene
    }

    /// Keeps `durationMinutes` (what actually gets sent to the backend, see
    /// `onSave` below) in sync with the two Stunden/Minuten wheels above —
    /// 0h/0min collapses to nil, same "not set" meaning the old single-wheel
    /// "–" option had.
    private func syncDurationMinutes() {
        let total = durationHours * 60 + durationMins
        durationMinutes = total == 0 ? nil : total
    }

    /// Mirrors ShotDetailSheet's removePhoto. A locally staged (not yet
    /// uploaded) photo just clears locally — nothing to tell the server
    /// about yet. An already-saved image needs its own immediate PATCH,
    /// same as removePhoto acts immediately rather than waiting for
    /// "Fertig" (this sheet's own "Fertig" only ever ADDS an image via
    /// onImagePicked, it never sends clear_image, so removal has to be a
    /// separate direct call here).
    private func removeImage() async {
        uploadedImage = nil
        guard let existing, existing.imageUrl != nil else { return }
        removingImage = true
        defer { removingImage = false }
        do {
            let updated = try await APIClient.shared.patchScene(existing.id, clearImage: true)
            if let index = viewModel.scenes.firstIndex(where: { $0.id == updated.id }) {
                viewModel.scenes[index] = updated
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
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
                        if uploadedImage != nil || existing?.imageUrl != nil {
                            Button(role: .destructive) {
                                Task { await removeImage() }
                            } label: {
                                Label("Bild entfernen", systemImage: "trash")
                            }
                        }
                    }
                }

                Section("Name") {
                    TextField("z.B. Küche, Aussen Tag 1", text: $name)
                }
                if !isIntermediateStep {
                    Section("Priorität") {
                        Picker("Priorität", selection: $priority) {
                            Text("Keine").tag(ShotPriority?.none)
                            ForEach(ShotPriority.allCases) { p in
                                Text(p.label).tag(ShotPriority?.some(p))
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Beschreibung") {
                    TextField("z.B. Handlung, Notizen", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                if !isIntermediateStep {
                    Section {
                        ForEach(liveDialogues) { line in
                            existingDialogueRow(line)
                        }
                        ForEach(Array(draftDialogues.enumerated()), id: \.offset) { index, text in
                            draftDialogueRow(text, at: index)
                        }
                        if isAddingDialogue {
                            // 2026-07-15, Lino: dialogue text needs to keep
                            // real line breaks exactly as typed — a plain
                            // single-line TextField (the old version here)
                            // can't hold a newline AT ALL, Return always
                            // submitted the whole line immediately. axis:
                            // .vertical (same technique "Beschreibung"
                            // above already uses) lets Return insert an
                            // actual newline and grows the field instead.
                            // That means Return no longer submits, so this
                            // needs its own explicit commit button — a
                            // multi-line field's onSubmit doesn't reliably
                            // fire on Return the way a single-line field's did.
                            HStack(alignment: .bottom, spacing: 8) {
                                TextField("Neuer Dialog", text: $newDialogueText, axis: .vertical)
                                    .focused($newDialogueFocused)
                                    .lineLimit(1...6)
                                Button {
                                    commitNewDialogue()
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                .disabled(newDialogueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        } else {
                            Button {
                                newDialogueText = ""
                                isAddingDialogue = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    newDialogueFocused = true
                                }
                            } label: {
                                // Just "Dialog", not "+ Dialog" - the SF
                                // Symbol plus icon already is the "+", a
                                // literal "+" in the text too doubled it up.
                                Label("Dialog", systemImage: "plus")
                            }
                        }
                    } header: {
                        Label("Dialog", systemImage: "quote.bubble")
                    }
                }

                Section("Datum & Uhrzeit") {
                    Toggle("Drehtermin festlegen", isOn: $hasDate.animation(.spring(response: 0.35, dampingFraction: 0.86)))
                    if hasDate {
                        // Default (.compact) style in a Form — tap the value to get the
                        // standard system calendar+wheel popover, same as Reminders/Calendar.
                        DatePicker("Start", selection: $scheduledDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                if hasDate {
                    // Only meaningful once a start time exists — the live/countdown
                    // badge on the scene card is scheduledAt + durationMinutes.
                    Section("Geschätzte Länge") {
                        HStack {
                            Picker("Stunden", selection: $durationHours) {
                                ForEach(Self.hourSteps, id: \.self) { h in
                                    Text("\(h) Std.").tag(h)
                                }
                            }
                            .pickerStyle(.wheel)
                            Picker("Minuten", selection: $durationMins) {
                                ForEach(Self.minuteSteps, id: \.self) { m in
                                    Text("\(m) Min.").tag(m)
                                }
                            }
                            .pickerStyle(.wheel)
                        }
                        .onChange(of: durationHours) { _, _ in syncDurationMinutes() }
                        .onChange(of: durationMins) { _, _ in syncDurationMinutes() }
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

                // Zuständig (2026-07-13, Lino) — was only reachable from the
                // full single-column sceneTile's own inline assignee menu;
                // the 2-column compact tile deliberately leaves that off the
                // tile itself (see sceneCompactTile's doc comment) and this
                // sheet had no equivalent, so a scene opened from the
                // 2-column grid had no way at all to assign a user. Same
                // "needs a real id" reasoning as Location/Einstellungen above,
                // and offered for Zwischenschritt scenes too, unlike those.
                // Reads/writes through `liveExisting`, not `existing` directly
                // — same stale-snapshot fix as SceneLocationSection's
                // `liveScene` below, or the picker would silently snap back
                // to the pre-selection value until the sheet is reopened.
                if let existing {
                    Section("Zuständig") {
                        Picker("Zuständig", selection: Binding(
                            get: { liveExisting(existing).assigneeId },
                            set: { newValue in Task { await viewModel.assignScene(existing, to: newValue) } }
                        )) {
                            Text("Niemand").tag(String?.none)
                            ForEach(viewModel.members) { member in
                                Text(member.name ?? member.email).tag(String?.some(member.userId))
                            }
                        }
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
                            // No more free-text "Dialog" field in this sheet
                            // (see the Dialog section below - only the
                            // checkable multi-line list + "+ Dialog" now) -
                            // this passes the existing value straight
                            // through unchanged rather than ever clearing it.
                            let saved = await onSave(
                                name.trimmingCharacters(in: .whitespacesAndNewlines),
                                color,
                                description.trimmingCharacters(in: .whitespacesAndNewlines),
                                existing?.dialogue ?? "",
                                hasDate ? scheduledDate : nil,
                                hasDate ? durationMinutes : nil,
                                priority
                            )
                            // existing's id never changes on rename, so prefer it when
                            // present; `saved` only matters for a brand-new scene, which
                            // has no id until onSave's createScene call returns one.
                            if let uploadedImage, let target = existing ?? saved {
                                await onImagePicked?(target, uploadedImage)
                            }
                            if let target = existing ?? saved {
                                for text in draftDialogues {
                                    await viewModel.addDialogue(to: target, text: text)
                                }
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

    /// Reads through the shared viewModel rather than `existing.dialogues`
    /// directly, so a line added/checked off here shows up immediately —
    /// same reasoning as the "Einstellungen" section above using
    /// `viewModel.shots(in:)` instead of a fixed snapshot.
    private var liveDialogues: [SceneDialogue] {
        guard let existing else { return [] }
        return viewModel.scenes.first(where: { $0.id == existing.id })?.dialogues ?? []
    }

    private func commitNewDialogue() {
        let trimmed = newDialogueText.trimmingCharacters(in: .whitespacesAndNewlines)
        isAddingDialogue = false
        guard !trimmed.isEmpty else { return }
        if let existing {
            Task { await viewModel.addDialogue(to: existing, text: trimmed) }
        } else {
            draftDialogues.append(trimmed)
        }
        newDialogueText = ""
    }

    @ViewBuilder
    private func existingDialogueRow(_ line: SceneDialogue) -> some View {
        HStack(spacing: 8) {
            Button {
                guard let existing else { return }
                Task { await viewModel.toggleDialogue(line, in: existing) }
            } label: {
                Image(systemName: line.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(line.done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            Text(line.text)
                .font(.subheadline)
                .strikethrough(line.done)
        }
        .swipeActions {
            Button(role: .destructive) {
                guard let existing else { return }
                Task { await viewModel.deleteDialogue(line, in: existing) }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    /// Not yet checkable — a draft line has no SceneDialogue id until the
    /// scene itself is created and this gets flushed via addDialogue above.
    @ViewBuilder
    private func draftDialogueRow(_ text: String, at index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle").foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
        .swipeActions {
            Button(role: .destructive) {
                draftDialogues.remove(at: index)
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }
}

/// Per-scene address field, same backend-search autocomplete as the
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

    /// `scene` is a snapshot captured once when the sheet opened (SceneEditSheet's
    /// `existing` never re-reads from the view model) — selecting an address updates
    /// the backend immediately (see `select` below), but without this, the sheet kept
    /// showing the stale pre-selection state (empty search field again) until it was
    /// dismissed and reopened, which read as "address isn't applied until Fertig".
    /// Same fix already applied to dialogues via `liveDialogues` in the parent sheet.
    private var liveScene: Scene {
        viewModel.scenes.first(where: { $0.id == scene.id }) ?? scene
    }

    var body: some View {
        if let address = liveScene.locationAddress, !isEditing {
            VStack(alignment: .leading, spacing: 8) {
                if let lat = liveScene.locationLat, let lng = liveScene.locationLng {
                    SceneMapThumbnail(lat: lat, lng: lng, size: 200)
                        .frame(maxWidth: .infinity)
                }
                // Same explicit leading-alignment fix as ShotListView's
                // scene-card address and ProjectInfoBox's (2026-07-15) —
                // without it Text sizes to its own intrinsic width instead
                // of the row's actual available width.
                Text(address)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private func select(_ suggestion: LocationSuggestion) async {
        guard let resolved = try? await LocationSearch.resolve(suggestion, sessionToken: completer.sessionToken) else { return }
        await viewModel.updateSceneLocation(scene, address: resolved.address, lat: resolved.lat, lng: resolved.lng)
        isEditing = false
        completer.clear()
        query = ""
    }
}
