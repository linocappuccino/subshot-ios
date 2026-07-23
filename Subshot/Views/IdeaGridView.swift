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
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(entry.ideas) { idea in
                                IdeaTileView(idea: idea)
                                    .onTapGesture { editingIdea = idea }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editingIdea) { idea in
            IdeaEditSheet(idea: idea, viewModel: viewModel)
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
                            .aspectRatio(16.0 / 9.0, contentMode: .fill)
                            .clipped()
                    } else {
                        AsyncShotThumbnail(path: url, size: nil, lockAspectRatio: false)
                            .aspectRatio(16.0 / 9.0, contentMode: .fill)
                            .clipped()
                    }
                } else {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(idea.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
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
            .padding(.top, 6)
        }
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
