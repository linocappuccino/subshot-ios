import SwiftUI

/// Same Reminders "Edit List" pattern as SceneEditSheet, for projects: rename
/// + recolor an existing project. Reached via swipe/context menu on
/// ProjectListView rows.
struct ProjectEditSheet: View {
    let project: Project
    var onSave: (String, String, String?) async -> Void

    @State private var name: String
    @State private var color: String
    @State private var emoji: String
    @Environment(\.dismiss) private var dismiss

    init(project: Project, onSave: @escaping (String, String, String?) async -> Void) {
        self.project = project
        self.onSave = onSave
        _name = State(initialValue: project.name)
        _color = State(initialValue: project.color)
        _emoji = State(initialValue: project.emoji ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Projektname", text: $name)
                }
                Section("Emoji") {
                    TextField("Optional, z.B. 🎬", text: $emoji)
                        // A single emoji is one (extended) grapheme cluster —
                        // trimming to the first one keeps this a one-emoji
                        // field even if someone pastes a run of them.
                        .onChange(of: emoji) { _, newValue in
                            if let first = newValue.first {
                                emoji = String(first)
                            }
                        }
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
            .navigationTitle("Projekt bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await onSave(trimmed.isEmpty ? project.name : trimmed, color, trimmedEmoji.isEmpty ? nil : trimmedEmoji)
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
