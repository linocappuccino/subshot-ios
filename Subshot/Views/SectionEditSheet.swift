import SwiftUI

/// Minimal Reminders-"New List"-style sheet, trimmed down from SceneEditSheet
/// to just a name — sections are purely an organizational grouping, nothing
/// else to configure.
struct SectionEditSheet: View {
    let existing: SceneSection?
    var onSave: (String) async -> Void
    @ObservedObject private var language = AppLanguage.shared

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
                Section(language.t("sectionEditSheet.nameSection")) {
                    TextField(language.t("sectionEditSheet.namePlaceholder"), text: $name)
                        .focused($focused)
                }
            }
            .navigationTitle(existing == nil ? language.t("sectionEditSheet.newTitle") : language.t("sectionEditSheet.renameTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("common.done")) {
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
