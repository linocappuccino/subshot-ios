import SwiftUI

/// 2026-08-05, Lino: "in den Szenen-Kacheln muss man auch einen prompt
/// eingeben können um ein AI Bild zu generieren, damit man nicht immer den
/// Beschreibungstext nehmen muss... ein Button 'AI Bild generieren' und
/// dann kommt ein Dialog wo man den Prompt eingeben kann, das Format
/// wählen kann und ob realistisch oder sketch, dann ein Button darunter
/// mit Generiere Bild.. und der Dialog schliesst sich." — reachable
/// directly from the scene tile's own .contextMenu (see ShotListView's
/// sceneTile/sceneCompactTile), a separate, faster path from the original
/// 2026-07-15 AI-image feature buried inside SceneEditSheet.swift (still
/// description-only, left as-is). Same fire-and-forget backend contract as
/// that one (202 response, ShotListView's 12s poll picks up the finished
/// image later) — this dialog dismisses itself the instant the generate
/// call is fired, it never waits for the result.
/// UNVERIFIED — no compiler here, see project memory (iOS: no compiler here).
struct SceneAIImageSheet: View {
    let scene: Scene
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss

    /// Prefilled from the scene's own description (same starting point the
    /// old description-only flow always used) but freely editable — the
    /// whole point of this dialog is letting the image prompt diverge from
    /// that text without having to overwrite the real description field.
    @State private var prompt: String
    /// 2026-07-15, Lino: "16:9 oder 9:16" — same default reasoning
    /// SceneEditSheet's own picker already uses.
    @State private var aspectRatio = "16:9"
    @State private var style = "realistic"
    @State private var isGenerating = false
    @State private var errorMessage: String?
    /// 2026-07-16 — same 402 (insufficient_credits) handling as
    /// SceneEditSheet.generateAIImage, see that function's own doc comment.
    @State private var showInsufficientCreditsAlert = false

    init(scene: Scene, viewModel: ShotListViewModel) {
        self.scene = scene
        self.viewModel = viewModel
        _prompt = State(initialValue: scene.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(language.t("sceneAIImageSheet.promptSection")) {
                    TextField(language.t("sceneAIImageSheet.promptPlaceholder"), text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                }
                Section {
                    Picker(language.t("sceneEditSheet.formatPicker"), selection: $aspectRatio) {
                        Text("16:9").tag("16:9")
                        Text("9:16").tag("9:16")
                    }
                    .pickerStyle(.segmented)
                    Picker(language.t("sceneEditSheet.stylePicker"), selection: $style) {
                        Text(language.t("sceneEditSheet.styleRealistic")).tag("realistic")
                        Text(language.t("sceneEditSheet.styleSketch")).tag("sketch")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Button {
                        Task { await generate() }
                    } label: {
                        if isGenerating {
                            HStack {
                                ProgressView()
                                Text(language.t("sceneEditSheet.generating"))
                            }
                        } else {
                            Label(language.t("sceneAIImageSheet.generateButton"), systemImage: "sparkles")
                        }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(language.t("sceneAIImageSheet.navTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("common.cancel")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert(language.t("insufficientCredits.title"), isPresented: $showInsufficientCreditsAlert) {
            Button(language.t("insufficientCredits.later"), role: .cancel) {}
            Button(language.t("insufficientCredits.buyCredits")) {
                if let url = URL(string: "https://app.subshot.ch/credits") {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text(language.t("sceneEditSheet.insufficientCreditsMessage"))
        }
    }

    private func generate() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        isGenerating = true
        do {
            _ = try await APIClient.shared.generateSceneImage(scene.id, style: style, aspectRatio: aspectRatio, prompt: trimmed)
            dismiss()
        } catch {
            if case APIError.server(402, _) = error {
                showInsufficientCreditsAlert = true
            } else {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }
}
