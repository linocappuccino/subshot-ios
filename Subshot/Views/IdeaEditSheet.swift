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
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    /// 2026-07-21, #277 — owns the description text AND the whole
    /// slash-command state machine (see IdeaSlashTextEditor.swift); text
    /// itself lives at `slashController.text` now, not a plain @State.
    @StateObject private var slashController: IdeaSlashEditorController
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
    /// 2026-07-21, #278 — tap an idea image to view it fullscreen, tap
    /// again to dismiss back to this card. Independent of the delete "x"
    /// button (that stays its own small tap target inside the same tile,
    /// see ideaImageThumb).
    @State private var enlargedImage: IdeaImage?

    init(idea: Idea, viewModel: ShotListViewModel) {
        self.idea = idea
        self.viewModel = viewModel
        _title = State(initialValue: idea.title)
        _slashController = StateObject(wrappedValue: IdeaSlashEditorController(initialText: idea.plainText))
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
            await viewModel.patchIdea(idea, title: cleanTitle.isEmpty ? language.t("ideaGrid.newIdeaTitle") : cleanTitle, text: slashController.text)
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

    /// 2026-07-22, web parity (#297) — video counterpart to
    /// handleImagePicked above, wired to IdeaMediaSourceButton's
    /// onVideoPicked below.
    private func handleVideoPicked(_ fileURL: URL, _ contentType: String) {
        guard liveIdea.images.count < 10 else { return }
        uploading = true
        Task {
            await viewModel.uploadIdeaVideo(idea, fileURL: fileURL, filename: fileURL.lastPathComponent, contentType: contentType)
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
                Section(language.t("ideaEditSheet.imagesSectionTitle").replacingOccurrences(of: "{count}", with: "\(liveIdea.images.count)")) {
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
                        IdeaMediaSourceButton(onImagePicked: handleImagePicked, onVideoPicked: handleVideoPicked) {
                            Label(uploading ? language.t("ideaEditSheet.uploadingImage") : language.t("ideaEditSheet.addImageButton"), systemImage: "photo.badge.plus")
                        }
                        .disabled(uploading || liveIdea.images.count >= 10)
                        Button {
                            showGeneratePopup = true
                        } label: {
                            Label(language.t("ideaEditSheet.generatePopupTitle"), systemImage: "sparkles")
                        }
                        .disabled(liveIdea.images.count >= 10)
                    }
                }

                Section(language.t("ideaEditSheet.titleSectionLabel")) {
                    TextField(language.t("ideaEditSheet.titleSectionLabel"), text: $title)
                        .disabled(approved)
                        .onChange(of: title) { _, _ in scheduleAutosave() }
                }

                Section(language.t("ideaEditSheet.descriptionSectionLabel")) {
                    // 2026-07-21, #277 — was a plain multi-line TextField;
                    // now a custom UITextView wrapper with the same
                    // slash-command state machine as web's RichTextEditor
                    // (see IdeaSlashTextEditor.swift). scheduleAutosave is
                    // wired via slashController.onTextChanged below.
                    IdeaSlashTextEditor(controller: slashController, isEditable: !approved)
                        .frame(minHeight: 180, maxHeight: 320)
                    Text(language.t("ideaEditSheet.slashHint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(language.t("ideaEditSheet.feedbackSectionLabel")) {
                    Button {
                        showFeedback = true
                    } label: {
                        HStack {
                            Text(liveIdea.feedbackCount == 0
                                ? language.t("ideaEditSheet.noFeedbackYet")
                                : language.t("ideaEditSheet.feedbackCountLabel")
                                    .replacingOccurrences(of: "{count}", with: "\(liveIdea.feedbackCount)")
                                    .replacingOccurrences(of: "{suffix}", with: liveIdea.feedbackCount == 1 ? "" : "s"))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    if approved {
                        Label(language.t("ideaEditSheet.approvedBadge"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        // 2026-07-17, Lino: "es braucht ein Datum und
                        // Uhrzeit WANN das Video abgenommen wurde".
                        if let approvedAt = liveIdea.approvedAt {
                            HStack {
                                Text(language.t("ideaEditSheet.approvedOnLabel"))
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
                                Text(approving ? language.t("ideaEditSheet.approving") : language.t("ideaEditSheet.approveButton"))
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
                            Label(language.t("ideaEditSheet.deleteIdeaButton"), systemImage: "trash")
                        }
                        .disabled(deleting)
                    }
                }
            }
            .navigationTitle(title.isEmpty ? language.t("ideaEditSheet.navTitleFallback") : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("ideaEditSheet.doneButton")) { dismiss() }
                }
            }
            .sheet(isPresented: $showFeedback) {
                IdeaFeedbackSheet(idea: liveIdea)
            }
            .sheet(isPresented: $showGeneratePopup) {
                ideaGeneratePopup
            }
            // 2026-07-21, #277 — the slash-menu itself: a plain
            // .confirmationDialog rather than a floating popup positioned
            // at the caret (see IdeaSlashTextEditor's own top-of-file doc
            // comment for why). Dismissing without picking an option
            // (swipe-down/tap-outside) also routes through
            // slashController.cancelSlash() via the isPresented setter,
            // same as tapping "Abbrechen" — matches web's Escape behavior
            // of just closing the menu, the already-typed "/" stays put.
            // 2026-07-22 — option.label/option.icon are the marker text
            // itself (IdeaSlashOption.markerLine embeds them verbatim, must
            // match the backend's regex constants exactly, see
            // IdeaSlashTextEditor.swift's top-of-file doc comment) —
            // deliberately left untranslated, same reasoning as web's
            // RichTextEditor slash-menu marker labels.
            .confirmationDialog(
                language.t("ideaEditSheet.insertDialogTitle"),
                isPresented: Binding(
                    get: { slashController.pendingSlashOptions != nil },
                    set: { if !$0 { slashController.cancelSlash() } }
                ),
                titleVisibility: .visible
            ) {
                ForEach(slashController.pendingSlashOptions ?? []) { option in
                    Button("\(option.icon) \(option.label)") {
                        slashController.confirm(option)
                    }
                }
                Button(language.t("ideaEditSheet.cancelButton"), role: .cancel) { slashController.cancelSlash() }
            }
        }
        .fullScreenCover(item: $enlargedImage) { image in
            IdeaImageFullscreenView(image: image)
        }
        .onAppear {
            slashController.onTextChanged = { scheduleAutosave() }
        }
        .preferredColorScheme(.dark)
        .alert(language.t("ideaEditSheet.noCreditsTitle"), isPresented: $showInsufficientCreditsAlert) {
            Button(language.t("ideaEditSheet.later"), role: .cancel) {}
            Button(language.t("ideaEditSheet.buyCredits")) {
                if let url = URL(string: "https://app.subshot.ch/credits") {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text(language.t("ideaEditSheet.noCreditsMessage"))
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
                // 2026-07-22, web parity (#297) — video/GIF branch mirrors
                // IdeaImageReorderGrid.tsx's ReorderTile (this horizontal
                // strip is iOS's closest equivalent render site: there's no
                // separate drag-to-reorder grid ported yet, see this
                // sheet's own top-of-file doc comment).
                if isVideoUrl(url) {
                    AsyncIdeaVideoThumbnail(path: url)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { enlargedImage = image }
                } else {
                    AsyncShotThumbnail(path: url, size: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        // 2026-07-21, #278 — tap to enlarge; the delete "x"
                        // button below sits in its own small corner Button, so
                        // it keeps intercepting taps in ITS bounds first, this
                        // gesture only ever fires for taps on the photo itself.
                        .onTapGesture { enlargedImage = image }
                }
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
                Section(language.t("ideaEditSheet.imagePromptSectionLabel")) {
                    TextField(language.t("ideaEditSheet.imagePromptPlaceholder"), text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                    Text(language.t("ideaEditSheet.imagePromptHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker(language.t("ideaEditSheet.formatLabel"), selection: $aspectRatio) {
                        Text("16:9").tag("16:9")
                        Text("9:16").tag("9:16")
                    }
                    .pickerStyle(.segmented)
                    Picker(language.t("ideaEditSheet.styleLabel"), selection: $style) {
                        Text(language.t("ideaEditSheet.styleRealistic")).tag("realistic")
                        Text(language.t("ideaEditSheet.styleSketch")).tag("sketch")
                    }
                    .pickerStyle(.segmented)
                }
                Button {
                    Task { await generate() }
                } label: {
                    if generating {
                        HStack { ProgressView(); Text(language.t("ideaEditSheet.generatingLabel")) }
                    } else {
                        Label(language.t("ideaEditSheet.generateImageButton"), systemImage: "sparkles")
                    }
                }
                .disabled(generating)
            }
            .navigationTitle(language.t("ideaEditSheet.generatePopupTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("ideaEditSheet.cancelButton")) { showGeneratePopup = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// 2026-07-21, #278 — fullscreen viewer for one idea image, opened by
/// tapping its thumbnail in ideaImageThumb above. Tapping anywhere on the
/// image (or its black backdrop) dismisses back to the card, matching
/// "tap again to close".
private struct IdeaImageFullscreenView: View {
    let image: IdeaImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = image.imageUrl {
                // 2026-07-22, web parity (#297) — video/GIF branch mirrors
                // IdeaFloatingCard.tsx's main image-area isVideoUrl check
                // (this fullscreen viewer is iOS's closest equivalent render
                // site: there's no inline big-slideshow card ported, this
                // sheet only ever shows one image large at a time, on tap).
                if isVideoUrl(url) {
                    AsyncIdeaVideoThumbnail(path: url)
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    AsyncShotThumbnail(path: url, size: nil)
                        .aspectRatio(contentMode: .fit)
                        .padding()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .preferredColorScheme(.dark)
    }
}
