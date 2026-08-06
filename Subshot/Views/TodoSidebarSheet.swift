import SwiftUI

/// iOS port (#412) of the Projektübersicht's right-hand web sidebar
/// (TodoSidebar.tsx, #305) — reachable via a bottom-center button on
/// ProjectListView instead of an always-visible column (no room for a
/// permanent sidebar on a phone). Same two feeds, same order
/// (Postproduction-Deadlines above Meine Todos), same urgency-color rule
/// (2026-08-05/2026-08-06, ported from TodoSidebar.tsx's dueUrgency):
/// yellow one calendar day before a deadline, red on the deadline's own
/// day AND once it's overdue.
///
/// 2026-08-06, Lino: "die todolisten müssen allgemein mehr apple like
/// dargestellt werden (wie in der apple erinnerungs app)" — insetGrouped
/// list (Reminders' own rounded-card sections), a thin ring checkbox that
/// fills with a white checkmark on a colored disc when tapped (same SF
/// Symbol two-tone technique Reminders itself uses), and plain-weight body
/// text with a small secondary subtitle line — was semibold subheadline
/// throughout. Interaction was already right (this sheet already only ever
/// shipped this way): tapping the CIRCLE completes the todo, tapping the
/// TEXT navigates to that item's project — mirrors web's completeTodo
/// (one-way, the list only ever shows open todos, so checking one off just
/// drops it from the list once the brief checked-flourish below finishes).
struct TodoSidebarSheet: View {
    @ObservedObject var viewModel: ProjectListViewModel
    var onSelectProject: (Project) -> Void
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss

    /// Same defensive lookup as NotificationsSheet.select — the todo/deadline
    /// always belongs to a project the user can see (backend already scopes
    /// the query to visible projects), but this only navigates if that
    /// project is also present in the ALREADY-LOADED root projects list
    /// (cross-project data can point at a project filed in a folder that
    /// hasn't been fetched here), same conservative behavior as the bell.
    private func selectProject(id: String) {
        if let project = viewModel.projects.first(where: { $0.id == id }) {
            dismiss()
            onSelectProject(project)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(language.t("todoSidebar.deadlinesTitle")) {
                    if let deadlines = viewModel.todoSidebarData?.postproductionDeadlines, !deadlines.isEmpty {
                        ForEach(deadlines) { deadline in
                            deadlineRow(deadline)
                        }
                    } else {
                        Text(language.t("todoSidebar.deadlinesEmpty"))
                            .foregroundStyle(.secondary)
                    }
                }
                Section(language.t("todoSidebar.myTodosTitle")) {
                    if let todos = viewModel.todoSidebarData?.todos, !todos.isEmpty {
                        ForEach(todos) { todo in
                            todoRow(todo)
                        }
                    } else {
                        Text(language.t("todoSidebar.myTodosEmpty"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Reminders' own list style — rounded-card sections rather than
            // a plain edge-to-edge list.
            .listStyle(.insetGrouped)
            .navigationTitle(language.t("todoSidebar.sheetTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("notificationsSheet.doneButton")) { dismiss() }
                }
            }
            .task { await viewModel.loadTodoSidebar() }
            .refreshable { await viewModel.loadTodoSidebar() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func deadlineRow(_ deadline: PostproductionVideoDeadline) -> some View {
        let urgency = Self.dueUrgency(deadline.postproductionDeadline)
        Button {
            selectProject(id: deadline.projectId)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(deadline.videoTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(deadline.projectName) · \(deadline.sectionName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    if let status = deadline.postproductionStatus {
                        HStack(spacing: 5) {
                            Circle().fill(status.glowColor).frame(width: 7, height: 7)
                            Text(PostproductionListView.statusLabel(status, language: language))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(Self.formatDateTime(deadline.postproductionDeadline))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(deadline.postproductionDeadline < Date() ? .red : .secondary)
                }
                .padding(.top, 1)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .listRowBackground(Self.urgencyBackground(urgency))
    }

    @ViewBuilder
    private func todoRow(_ todo: MyTodo) -> some View {
        let urgency = todo.dueAt.flatMap(Self.dueUrgency)
        HStack(alignment: .top, spacing: 12) {
            ReminderCheckbox(action: {
                await viewModel.completeTodo(todo)
            })
            .accessibilityLabel(language.t("todoSidebar.markDone"))
            .padding(.top, 1)

            Button {
                selectProject(id: todo.projectId)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(todo.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    HStack {
                        Text(todo.projectName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let dueAt = todo.dueAt {
                            Text(Self.formatDateTime(dueAt))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(dueAt < Date() ? .red : .secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .listRowBackground(Self.urgencyBackground(urgency))
    }

    // MARK: - Urgency (ported from TodoSidebar.tsx's dueUrgency/urgencyRowClass)

    private enum Urgency { case overdue, today, tomorrow }

    /// Deliberately a CALENDAR-day comparison (local device timezone), not a
    /// rolling 24h/48h window — see TodoSidebar.tsx's own doc comment.
    private static func dueUrgency(_ due: Date) -> Urgency? {
        let calendar = Calendar.current
        let dueDay = calendar.startOfDay(for: due)
        let today = calendar.startOfDay(for: Date())
        let diffDays = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
        if diffDays < 0 { return .overdue }
        if diffDays == 0 { return .today }
        if diffDays == 1 { return .tomorrow }
        return nil
    }

    private static func urgencyBackground(_ urgency: Urgency?) -> Color {
        switch urgency {
        case .today, .overdue: return Color.red.opacity(0.12)
        case .tomorrow: return Color.yellow.opacity(0.12)
        case nil: return Color.clear
        }
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_CH")
        formatter.dateFormat = "HH:mm · dd.MM"
        return formatter
    }()

    private static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }
}

/// Apple Reminders' own checkbox: a thin gray ring that, on tap, fills with
/// a colored disc + white checkmark (SF Symbol `.palette` rendering — same
/// two-layer technique Reminders itself uses, not a plain green dot) before
/// handing off to `action`. The brief local flourish runs independently of
/// the network call so the tap always feels instant; `action` is expected to
/// remove the row from its parent list shortly after (this sheet only ever
/// shows OPEN todos), which is why this never needs to reset back to unchecked.
private struct ReminderCheckbox: View {
    let action: () async -> Void
    @State private var checked = false

    var body: some View {
        Button {
            guard !checked else { return }
            withAnimation(.easeOut(duration: 0.15)) { checked = true }
            Task {
                try? await Task.sleep(nanoseconds: 220_000_000)
                await action()
            }
        } label: {
            Group {
                // `.palette` rendering only makes sense for "checkmark.circle.fill"
                // (two real layers: checkmark glyph + disc fill) — plain "circle"
                // is a single-layer outline, so applying `.palette` there would
                // just paint that ONE layer in the first color (a stark solid
                // white ring instead of a subtle gray one). Two distinct render
                // paths instead of one unified modifier chain for this reason.
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Color.secondary.opacity(0.4))
                }
            }
            .font(.system(size: 22))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
