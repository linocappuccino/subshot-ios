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
    var onSave: (String, String, String?, Bool, Bool, Bool) async -> Void
    @ObservedObject private var language = AppLanguage.shared

    @State private var name: String
    @State private var color: String
    @State private var emoji: String
    @State private var moduleConcept: Bool
    @State private var moduleScripting: Bool
    @State private var modulePostproduction: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        project: Project?, defaultColor: String = Color.subshotPalette[0],
        onSave: @escaping (String, String, String?, Bool, Bool, Bool) async -> Void
    ) {
        self.project = project
        self.onSave = onSave
        _name = State(initialValue: project?.name ?? "")
        _color = State(initialValue: project?.color ?? defaultColor)
        _emoji = State(initialValue: project?.emoji ?? "")
        _moduleConcept = State(initialValue: project?.moduleConcept ?? true)
        _moduleScripting = State(initialValue: project?.moduleScripting ?? true)
        _modulePostproduction = State(initialValue: project?.modulePostproduction ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(language.t("projectEditSheet.nameSection")) {
                    TextField(language.t("projectEditSheet.namePlaceholder"), text: $name)
                }
                Section(language.t("projectEditSheet.emojiSection")) {
                    EmojiPickerField(emoji: $emoji)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                }
                Section(language.t("projectEditSheet.colorSection")) {
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
                // 2026-07-17, Lino, #96 (erster Baustein der grossen
                // Pipeline-Vision: Idee -> Scripting -> Postproduction ->
                // Video-Feedback): "Beim Projekt erstellen sollen
                // Checkboxen kommen... einzeln markierbar, welche
                // Pipelines fuer das Projekt genutzt werden." Rein
                // informativ fuer jetzt, kein Freischalt-Gate. 2026-07-19:
                // "Video Feedback" Toggle entfernt, mit Postproduction
                // Tracking zusammengefuehrt (Lino: "sind das gleiche").
                Section(language.t("projectEditSheet.pipelineModulesSection")) {
                    Toggle(language.t("projectEditSheet.moduleConcept"), isOn: $moduleConcept)
                    Toggle(language.t("projectEditSheet.moduleScripting"), isOn: $moduleScripting)
                    Toggle(language.t("projectEditSheet.modulePostproduction"), isOn: $modulePostproduction)
                }
            }
            .navigationTitle(project == nil ? language.t("projectEditSheet.newTitle") : language.t("projectEditSheet.editTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("common.done")) {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                        // A brand-new project needs a real name (there's no
                        // existing one to fall back to like the edit case
                        // below does) - empty just does nothing, same guard
                        // the old bare name-only creation sheet had.
                        guard project != nil || !trimmed.isEmpty else { return }
                        Task {
                            await onSave(
                                trimmed.isEmpty ? (project?.name ?? "") : trimmed, color, trimmedEmoji.isEmpty ? nil : trimmedEmoji,
                                moduleConcept, moduleScripting, modulePostproduction
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
