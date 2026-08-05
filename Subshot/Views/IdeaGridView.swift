import SwiftUI

/// Planungssektor tile grid (2026-07-17 iOS port of the web app's
/// IdeaGrid.tsx) — small reorderable-in-spirit grid (drag-to-reorder isn't
/// ported yet, tap-to-open is), grouped into the same four status sections
/// the web app uses (see IdeaStatusGroup.of). Self-contained: owns its own
/// "which idea is the edit sheet showing" state, reads/writes through the
/// shared ShotListViewModel like every other piece of this screen.
struct IdeaGridView: View {
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject private var language = AppLanguage.shared
    @State private var editingIdea: Idea?
    /// 2026-07-23 (#324) — set only when this view was reached via a
    /// notification's deep link (see ShotListView's pendingDeepLinkKind);
    /// consumed exactly once by .task below, mirrors web's autoOpenIdeaId
    /// in projects/[id]/page.tsx.
    var initialSelectedIdeaId: String? = nil

    /// 2026-07-21, #280 (Lino: "ganz falsch!") — this view is now the
    /// Ideas page's ENTIRE content, no Scene/Section content sits below it
    /// anymore (see ShotListView.body's `switch activeWorkflowSection`); an
    /// approved idea's real Scene still lives exclusively on the Scripting
    /// panel, in its own Section, same as the web app's separate Ideas/
    /// Scenes routes. That's a completely separate concern from THIS list,
    /// though: filtering to `.open` here also hid the approved idea's own
    /// card, even though IdeaStatusGroup was already fully built for a 4th
    /// "Abgenommen" group (groupLabel below has had an .approved case,
    /// wired to a real translation key, since #280 — it was simply
    /// unreachable dead code with every idea pre-filtered to .open).
    /// 2026-07-23 (#326, Lino: "hier sieht man die abgenommenen Projekte
    /// nicht?!") — show every idea regardless of status; IdeaStatus only
    /// ever has .open/.approved (no soft-delete state), so this is simply
    /// viewModel.ideas now.
    private var visibleIdeas: [Idea] {
        viewModel.ideas
    }

    private var groupedIdeas: [(group: IdeaStatusGroup, ideas: [Idea])] {
        let grouped = Dictionary(grouping: visibleIdeas, by: IdeaStatusGroup.of)
        return IdeaStatusGroup.allCases.compactMap { group in
            guard let ideas = grouped[group], !ideas.isEmpty else { return nil }
            return (group, ideas.sorted { $0.sortOrder < $1.sortOrder })
        }
    }

    /// Local translation of IdeaStatusGroup.label — deliberately NOT
    /// changing Models.swift's own `.label` computed property (shared with
    /// other, un-migrated call sites like ShotListView's own status text;
    /// see AppLanguageStrings+Ideas.swift's top-of-file doc comment).
    private func groupLabel(_ group: IdeaStatusGroup) -> String {
        switch group {
        case .idea: return language.t("ideaGrid.groupIdea")
        case .firstFeedback: return language.t("ideaGrid.groupFeedback1")
        case .secondFeedback: return language.t("ideaGrid.groupFeedback2")
        case .approved: return language.t("ideaGrid.groupApproved")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 2026-07-21, #276 — the top-right "+ Idee" button that used to
            // sit here is gone; creating a new idea now only happens via
            // the dedicated bottom-right FAB on the Ideas page (see
            // ShotListView's addIdeaButton), which also skips the
            // create-then-open round trip this button used to do (same
            // direct-create-and-open behavior, just triggered from a
            // single button instead of two).
            Text(language.t("ideaGrid.heading") + (visibleIdeas.isEmpty ? "" : " (\(visibleIdeas.count))"))
                .font(.headline)

            if visibleIdeas.isEmpty {
                Text(language.t("ideaGrid.emptyState"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupedIdeas, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(groupLabel(entry.group).uppercased() + " (\(entry.ideas.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        // 2026-08-05, Lino: "hier müssen die ideen auch in
                        // einzelne kacheln lass ein wenig platz zwischen
                        // den kacheln" — 10pt read as tiles touching almost
                        // edge-to-edge; bumped to 16pt, same 2-column-grid
                        // spacing convention ProjectListView already uses.
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(entry.ideas) { idea in
                                IdeaTileView(idea: idea)
                                    .onTapGesture { editingIdea = idea }
                                    .contextMenu {
                                        Button {
                                            Task { await viewModel.duplicateIdea(idea) }
                                        } label: {
                                            Label(language.t("ideaGrid.duplicateIdea"), systemImage: "plus.square.on.square")
                                        }
                                        Button(role: .destructive) {
                                            Task { await viewModel.deleteIdea(idea) }
                                        } label: {
                                            Label(language.t("ideaGrid.deleteIdea"), systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editingIdea) { idea in
            IdeaEditSheet(idea: idea, viewModel: viewModel)
        }
        .task {
            if let initialSelectedIdeaId, let idea = viewModel.ideas.first(where: { $0.id == initialSelectedIdeaId }) {
                editingIdea = idea
            }
        }
    }
}

/// One small tile — cover photo (first ready image, plain center-crop, no
/// face-focus point server-side for idea images, see AsyncShotThumbnail's
/// own doc comment) + title + plain-text preview, mirrors the web app's
/// IdeaTile.tsx.
private struct IdeaTileView: View {
    let idea: Idea
    @ObservedObject private var language = AppLanguage.shared

    private var cover: IdeaImage? {
        idea.readyImages.first
    }

    private var approved: Bool { idea.status == .approved }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(.systemGray6)
                if let cover, let url = cover.imageUrl {
                    // 2026-07-22, web parity (#297) — video/GIF branch
                    // mirrors IdeaTile.tsx's cover-thumbnail isVideoUrl
                    // check (the overview-grid tile, third of the three
                    // render sites this feature needed on web).
                    if isVideoUrl(url) {
                        AsyncIdeaVideoThumbnail(path: url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        // 2026-07-26 (#336, Lino: "Thumbnails eingezoomt") — was
                        // `.aspectRatio(16/9, contentMode: .fill).clipped()`
                        // applied directly to AsyncShotThumbnail with no
                        // definite frame to fill against, which left the fill
                        // computation to negotiate against AsyncShotThumbnail's
                        // own unconstrained/intrinsic (image-pixel-size-driven)
                        // ideal size rather than the tile's actual visible box —
                        // over-cropping the photo. Every other working cover-
                        // photo call site in the app (ShotListView's sceneTile/
                        // ShotCard) instead gives AsyncShotThumbnail an explicit
                        // greedy `.frame(...)` and lets ITS OWN internal
                        // `.aspectRatio(contentMode: .fill)` do the (single) fill
                        // computation against that definite frame — mirrored here.
                        AsyncShotThumbnail(path: url, size: nil, lockAspectRatio: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                } else {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(idea.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    // 2026-07-27, Todoist #356 — same amber "intern noch
                    // nicht abgenommen" indicator as web's IdeaTile.tsx.
                    if idea.status == .open && idea.internalStatus == nil {
                        Circle()
                            .fill(Color.orange.opacity(0.8))
                            .frame(width: 6, height: 6)
                    }
                    if approved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                // 2026-07-17, Lino: "es braucht ein Datum und Uhrzeit WANN
                // das Video abgenommen wurde" — auf der kleinen Kachel
                // statt der Text-Vorschau, sobald angenommen.
                if approved, let approvedAt = idea.approvedAt {
                    Text(language.t("ideaTile.approvedOn").replacingOccurrences(of: "{date}", with: Self.dateFormatter.string(from: approvedAt)))
                        .font(.caption)
                        .foregroundStyle(.green.opacity(0.8))
                } else if !idea.plainText.isEmpty {
                    Text(idea.plainText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
        }
        // 2026-08-05, Lino: "hier müssen die einzelnen ideen jeweils in
        // einer kachel sein" — only the cover-photo area above had a
        // background/rounded corners of its own (see the ZStack's
        // .clipShape, now removed from there); the title/text area below
        // it sat directly on the grid's plain background with no card
        // container at all, so adjacent tiles' text visually ran together
        // with nothing marking where one idea ends and the next begins.
        // Moved the background+corner-radius to the WHOLE tile (image +
        // text together) instead, same "one bordered card per tile"
        // pattern PostproductionVideoTile already uses.
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(approved ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "de_CH")
        return f
    }()
}
