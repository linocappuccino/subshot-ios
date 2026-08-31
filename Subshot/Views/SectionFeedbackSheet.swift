import SwiftUI
import Combine

/// Comments left on the public no-login storyboard preview for one
/// Section/Skript ("Shotlist") — 2026-08-31, Todoist #96, iOS counterpart of
/// the web app's AnnotationsPanel, scoped to a single section instead of the
/// whole project. Read-only creation-wise (a public visitor writes these on
/// the preview page, this app only displays + lets the PL triage them),
/// grouped into numbered rounds same shape as IdeaFeedbackSheet. Reuses
/// ShotListViewModel.annotations (already fetched project-wide in load())
/// instead of its own network round trip.
struct SectionFeedbackSheet: View {
    let section: SceneSection
    @ObservedObject var viewModel: ShotListViewModel
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss

    @State private var collapsedRounds: Set<Int> = []

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "de_CH")
        return f
    }()

    private var comments: [Annotation] {
        viewModel.annotations.filter { $0.sectionId == section.id }
    }

    private var rounds: [(round: Int, entries: [Annotation])] {
        Dictionary(grouping: comments, by: { $0.round ?? 0 })
            .sorted { $0.key < $1.key }
            .map { (round: $0.key, entries: $0.value.sorted { $0.createdAt < $1.createdAt }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if comments.isEmpty {
                    ContentUnavailableView(language.t("sectionFeedbackSheet.emptyState"), systemImage: "bubble.left")
                } else {
                    List {
                        ForEach(rounds, id: \.round) { group in
                            let earliest = group.entries.map(\.createdAt).min() ?? Date()
                            let openCount = group.entries.filter { $0.status == "open" }.count
                            Section {
                                if !collapsedRounds.contains(group.round) {
                                    ForEach(group.entries) { entry in
                                        commentRow(entry)
                                    }
                                }
                            } header: {
                                Button {
                                    if collapsedRounds.contains(group.round) {
                                        collapsedRounds.remove(group.round)
                                    } else {
                                        collapsedRounds.insert(group.round)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(String(format: "%02d ", group.round) + language.t("sectionFeedbackSheet.roundWord"))
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: collapsedRounds.contains(group.round) ? "chevron.right" : "chevron.down")
                                                .foregroundStyle(.secondary)
                                        }
                                        HStack(spacing: 10) {
                                            Text(Self.dateFormatter.string(from: earliest))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if openCount > 0 {
                                                Text(language.t("sectionFeedbackSheet.openCount").replacingOccurrences(of: "{count}", with: "\(openCount)"))
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle(language.t("sectionFeedbackSheet.navTitle").replacingOccurrences(of: "{name}", with: section.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("sectionFeedbackSheet.doneButton")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func commentRow(_ entry: Annotation) -> some View {
        let color = Color.stableColor(for: entry.authorName)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.authorName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Spacer()
                if entry.status != "open", let resolvedByName = entry.resolvedByName {
                    Text("\(entry.status == "rejected" ? "✗" : "✓") \(resolvedByName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(entry.comment ?? "")
                .font(.subheadline)
                .strikethrough(entry.status != "open")
                .foregroundStyle(entry.status == "resolved" ? .secondary : .primary)
            HStack(spacing: 14) {
                if entry.status != "resolved" {
                    Button(language.t("sectionFeedbackSheet.resolve")) {
                        Task { await viewModel.setAnnotationStatus(entry, status: "resolved") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                }
                if entry.status != "rejected" {
                    Button(language.t("sectionFeedbackSheet.reject")) {
                        Task { await viewModel.setAnnotationStatus(entry, status: "rejected") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                }
                if entry.status != "open" {
                    Button(language.t("sectionFeedbackSheet.reopen")) {
                        Task { await viewModel.setAnnotationStatus(entry, status: "open") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3)
        }
    }
}
