import SwiftUI

/// Create/edit sheet for one Idea (2026-07-17 iOS port of the web app's
/// IdeaFloatingCard). Unlike SceneEditSheet there's no create-then-stage
/// dance: by the time this opens, the idea already exists — the caller
/// (IdeaGridView) creates it immediately via viewModel.createIdea(),
/// mirroring the web app's own IdeaGrid.createIdea() ("Neue Idee" appears
/// right away, title/text edits + image upload always have a real id to
/// target from the very first frame, no separate "Fertig"-creates-it step).
struct IdeaEditSheet: View {
    let idea: Idea
    @ObservedObject var viewModel: ShotListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var text: String
    @State private var uploading = false
    @State private var showGeneratePopup = false
    @State private var generating = false
    @State private var prompt = ""
    @State private var style = "realistic"
    /// 2026-07-17, matches the web app's IdeaFloatingCard default (a 9:16
    /// idea reference photo is the more common case there than a 16:9
    /// scene one).
    @State private var aspectRatio = "9:16"
    @State private var showInsufficientCreditsAlert = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var showFeedback = false
    @State private var approving = false
    @State private var deleting = false

    init(idea: Idea, viewModel: ShotListViewModel) {
        self.idea = idea
        self.viewModel = viewModel
        _title = State(initialValue: idea.title)
        _text = State(initialValue: idea.plainText)
    }

    /// Same "existing is a one-time snapshot, read the live copy for
    /// anything that can change while this sheet is open" fix as
    /// SceneEditSheet.liveExisting — images/status/feedbackCount all update
    /// from underneath this sheet (AI generation finishing, approval).
    private var liveIdea: Idea {
        viewModel.ideas.first(where: { $0.id == idea.id }) ?? idea
    }

    private var approved: Bool { liveIdea.status == .approved }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "de_CH")
        return f
    }()

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            await viewModel.patchIdea(idea, title: cleanTitle.isEmpty ? "Neue Idee" : cleanTitle, text: text)
        }
    }

    private func handleImagePicked(_ image: UIImage) {
        guard liveIdea.images.count < 10 else { return }
        uploading = true
        Task {
            await viewModel.uploadIdeaImage(idea, image: image)
            uploading = false
        }
    }

    /// Mirrors SceneEditSheet.generateAIImage's error handling exactly —
    /// same 402-insufficient-credits alert, same "no embedded payment flow,
    /// just an external link to the web credits page" decision (avoids the
    /// Apple IAP cut question entirely, see that sheet's own doc comment).
    private func generate() async {
        generating = true
        defer { generating = false }
        do {
            _ = try await APIClient.shared.generateIdeaImage(
                idea.id, style: style, aspectRatio: aspectRatio,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
            )
            await viewModel.refreshIdea(idea.id)
            showGeneratePopup = false
            prompt = ""
        } catch {
            if case APIError.server(402, _) = error {
                showInsufficientCreditsAlert = true
            } else {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func approve() async {
        approving = true
        defer { approving = false }
        await viewModel.approveIdea(idea)
    }

    private func performDelete() async {
        deleting = true
        await viewModel.deleteIdea(idea)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bilder (\(liveIdea.images.count)/10)") {
                    if !liveIdea.images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(liveIdea.images) { image in
                                    ideaImageThumb(image)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if !approved {
                        ImageSourceButton(onImagePicked: handleImagePicked) {
                            Label(uploading ? "Lädt hoch…" : "Bild hinzufügen", systemImage: "photo.badge.plus")
                        }
                        .disabled(uploading || liveIdea.images.count >= 10)
                        Button {
                            showGeneratePopup = true
                        } label: {
                            Label("AI Bild generieren", systemImage: "sparkles")
                        }
                        .disabled(liveIdea.images.count >= 10)
                    }
                }

                Section("Titel") {
                    TextField("Titel", text: $title)
                        .disabled(approved)
                        .onChange(of: title) { _, _ in scheduleAutosave() }
                }

                Section("Beschreibung") {
                    TextField("Beschreibung / Idee...", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .disabled(approved)
                        .onChange(of: text) { _, _ in scheduleAutosave() }
                }

                Section("Feedback") {
                    Button {
                        showFeedback = true
                    } label: {
                        HStack {
                            Text(liveIdea.feedbackCount == 0 ? "Noch kein Feedback" : "\(liveIdea.feedbackCount) Feedback")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    if approved {
                        Label("Angenommen", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        // 2026-07-17, Lino: "es braucht ein Datum und
                        // Uhrzeit WANN das Video abgenommen wurde".
                        if let approvedAt = liveIdea.approvedAt {
                            HStack {
                                Text("Angenommen am")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Self.dateFormatter.string(from: approvedAt))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        // 2026-07-18, web-parity (see
                        // [[feedback_ios_web_parity]]): "soll nicht blau
                        // sein, sondern gräulich und wird dann grün wenn man
                        // ihn klickt... animiert sich ein Hacken davor" —
                        // grey capsule at rest, green + checkmark once
                        // tapped (same optimistic-then-server-confirms
                        // pattern as the web button).
                        Button {
                            Task { await approve() }
                        } label: {
                            HStack(spacing: 6) {
                                if approving {
                                    Image(systemName: "checkmark")
                                        .transition(.scale.combined(with: .opacity))
                                }
                                Text(approving ? "Wird angenommen…" : "Abgenommen")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(approving ? Color.green.opacity(0.85) : Color(.systemGray5))
                            .foregroundStyle(approving ? .white : .primary)
                            .clipShape(Capsule())
                            .animation(.spring(response: 0.3), value: approving)
                        }
                        .buttonStyle(.plain)
                        .disabled(approving)
                    }
                }

                if !approved {
                    Section {
                        Button(role: .destructive) {
                            Task { await performDelete() }
                        } label: {
                            Label("Idee löschen", systemImage: "trash")
                        }
                        .disabled(deleting)
                    }
                }
            }
            .navigationTitle(title.isEmpty ? "Idee" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: $showFeedback) {
                IdeaFeedbackSheet(idea: liveIdea)
            }
            .sheet(isPresented: $showGeneratePopup) {
                ideaGeneratePopup
            }
        }
        .preferredColorScheme(.dark)
        .alert("Keine Credits mehr", isPresented: $showInsufficientCreditsAlert) {
            Button("Später", role: .cancel) {}
            Button("Credits kaufen") {
                if let url = URL(string: "https://app.subshot.ch/credits") {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("Du hast keine AI Credits mehr übrig, um ein Bild zu generieren. Lade Credits über die Web-Seite nach.")
        }
    }

    @ViewBuilder
    private func ideaImageThumb(_ image: IdeaImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if image.status == .generating {
                ProgressView()
                    .frame(width: 80, height: 80)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let url = image.imageUrl {
                AsyncShotThumbnail(path: url, size: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !approved && image.status != .generating {
                Button {
                    Task { await viewModel.deleteIdeaImage(idea, imageId: image.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(3)
            }
        }
    }

    @ViewBuilder
    private var ideaGeneratePopup: some View {
        NavigationStack {
            Form {
                Section("Bildprompt") {
                    TextField("Beschreibe das Bild...", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                    Text("Leer lassen, um die Beschreibung der Idee selbst zu verwenden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Format", selection: $aspectRatio) {
                        Text("16:9").tag("16:9")
                        Text("9:16").tag("9:16")
                    }
                    .pickerStyle(.segmented)
                    Picker("Stil", selection: $style) {
                        Text("Realistisch").tag("realistic")
                        Text("Sketch").tag("sketch")
                    }
                    .pickerStyle(.segmented)
                }
                Button {
                    Task { await generate() }
                } label: {
                    if generating {
                        HStack { ProgressView(); Text("Erstellt…") }
                    } else {
                        Label("Bild generieren", systemImage: "sparkles")
                    }
                }
                .disabled(generating)
            }
            .navigationTitle("AI Bild generieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { showGeneratePopup = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
