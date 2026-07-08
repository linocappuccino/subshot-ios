import SwiftUI

/// Minimal Reminders-"New List"-style sheet, trimmed down from SceneEditSheet
/// to just a name — sections are purely an organizational grouping, nothing
/// else to configure.
struct SectionEditSheet: View {
    let existing: SceneSection?
    var onSave: (String) async -> Void

    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(existing: SceneSection?, onSave: @escaping (String) async -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z.B. Tag 1, Interieur, Nachtdreh", text: $name)
                        .focused($focused)
                }
            }
            .navigationTitle(existing == nil ? "Neuer Abschnitt" : "Abschnitt umbenennen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            await onSave(trimmed)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { focused = true }
        }
        .preferredColorScheme(.dark)
    }
}
