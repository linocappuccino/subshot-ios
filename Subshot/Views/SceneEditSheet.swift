import SwiftUI

/// Reminders' "New List" sheet, adapted for Scenes: a name field + color
/// swatch grid. Used both to create a scene (opens automatically right after
/// tapping "Szene hinzufügen" — no more silently-created "Unbenannte Szene"
/// with no way to name it) and to rename/re-color an existing one (tap a
/// scene header).
struct SceneEditSheet: View {
    let existing: Scene?
    var onSave: (String, String) async -> Void

    @State private var name: String
    @State private var color: String
    @Environment(\.dismiss) private var dismiss

    init(existing: Scene?, onSave: @escaping (String, String) async -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _color = State(initialValue: existing?.color ?? Color.subshotPalette[0])
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
                            await onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), color)
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
