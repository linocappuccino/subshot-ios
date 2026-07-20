import SwiftUI

/// Feedback list for one idea (2026-07-17 iOS port of the web app's
/// IdeaFeedbackPanel; 2026-07-18 web-parity update — round grouping +
/// resolved toggle, see [[feedback_ios_web_parity]]). Feedback itself is
/// only ever WRITTEN on the public web share page (no login there), this
/// app displays what clients already left AND lets the PL check entries off
/// as processed (same idea as web's checkbox — see APIClient
/// .setIdeaFeedbackResolved). Grouped into numbered rounds ("01 Feedback",
/// "02 Feedback", ...) matching the round the backend already assigned
/// (Idea.feedback_round in app/main.py) — a new round starts once the idea's
/// text/images change after an earlier round was already sent. Colored per
/// author (Color.stableColor(for:), same helper already used for
/// assignee/todo avatars elsewhere in this app).
struct IdeaFeedbackSheet: View {
    let idea: Idea
    @Environment(\.dismiss) private var dismiss

    @State private var feedback: [IdeaFeedback] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Collapsed rounds (by round number) — all rounds start expanded, same
    /// default as the web app's FeedbackRound.
    @State private var collapsedRounds: Set<Int> = []

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "de_CH")
        return f
    }()

    private var rounds: [(round: Int, entries: [IdeaFeedback])] {
        Dictionary(grouping: feedback, by: \.round)
            .sorted { $0.key < $1.key }
            .map { (round: $0.key, entries: $0.value) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                } else if feedback.isEmpty {
                    ContentUnavailableView("Noch kein Feedback", systemImage: "bubble.left")
                } else {
                    List {
                        ForEach(rounds, id: \.round) { group in
                            let earliest = group.entries.map(\.createdAt).min() ?? Date()
                            let openCount = group.entries.filter { !$0.resolved }.count
                            Section {
                                if !collapsedRounds.contains(group.round) {
                                    ForEach(group.entries) { entry in
                                        feedbackRow(entry)
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
                                    HStack {
                                        Text(String(format: "%02d", group.round) + " Feedback — " + Self.dateFormatter.string(from: earliest))
                                        if openCount > 0 {
                                            Text("(\(openCount) offen)")
                                        }
                                        Spacer()
                                        Image(systemName: collapsedRounds.contains(group.round) ? "chevron.right" : "chevron.down")
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Feedback zu „\(idea.title)“")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            do {
                feedback = try await APIClient.shared.ideaFeedback(idea.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private func feedbackRow(_ entry: IdeaFeedback) -> some View {
        let color = Color.stableColor(for: entry.authorName)
        HStack(alignment: .top, spacing: 8) {
            Button {
                Task { await toggleResolved(entry) }
            } label: {
                Image(systemName: entry.resolved ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(entry.resolved ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.authorName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                }
                Text(entry.comment)
                    .font(.subheadline)
                    .strikethrough(entry.resolved)
                    .foregroundStyle(entry.resolved ? .secondary : .primary)
            }
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3)
        }
    }

    private func toggleResolved(_ entry: IdeaFeedback) async {
        guard let index = feedback.firstIndex(where: { $0.id == entry.id }) else { return }
        do {
            let updated = try await APIClient.shared.setIdeaFeedbackResolved(
                ideaId: idea.id, feedbackId: entry.id, resolved: !entry.resolved
            )
            feedback[index] = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
