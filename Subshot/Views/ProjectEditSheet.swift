import SwiftUI

/// Same Reminders "Edit List" pattern as SceneEditSheet, for projects: rename
/// + recolor an existing project (reached via swipe/context menu on
/// ProjectListView rows) — AND, since 2026-07-13 (Lino: "wenn man ein
/// Projekt anlegt... soll auch direkt die Option kommen mit dem Emoji und
/// der Farbe, nicht erst beim Bearbeiten"), also used for brand-new
/// projects with `project: nil`, so Emoji/Farbe are choosable at creation
/// time instead of only afterward via a separate edit step.
struct ProjectEditSheet: View {
    let project: Project?
    var onSave: (String, String, String?) async -> Void

    @State private var name: String
    @State private var color: String
    @State private var emoji: String
    @Environment(\.dismiss) private var dismiss

    init(project: Project?, defaultColor: String = Color.subshotPalette[0], onSave: @escaping (String, String, String?) async -> Void) {
        self.project = project
        self.onSave = onSave
        _name = State(initialValue: project?.name ?? "")
        _color = State(initialValue: project?.color ?? defaultColor)
        _emoji = State(initialValue: project?.emoji ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Projektname", text: $name)
                }
                Section("Emoji") {
                    EmojiPickerField(emoji: $emoji)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
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
            .navigationTitle(project == nil ? "Neues Projekt" : "Projekt bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                        // A brand-new project needs a real name (there's no
                        // existing one to fall back to like the edit case
                        // below does) - empty just does nothing, same guard
                        // the old bare name-only creation sheet had.
                        guard project != nil || !trimmed.isEmpty else { return }
                        Task {
                            await onSave(trimmed.isEmpty ? (project?.name ?? "") : trimmed, color, trimmedEmoji.isEmpty ? nil : trimmedEmoji)
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
