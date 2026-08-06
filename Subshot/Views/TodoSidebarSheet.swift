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
    /// 2026-08-06, Lino: "wenn man in der todoliste was abhackt, soll es mit
    /// einer animation zuerst durchgestrichen werden und dann mit einer
    /// animation verschwinden" — todoRow (a function, not its own View
    /// struct, so it can't hold @State itself) reads this to strike through
    /// the text the moment ReminderCheckbox starts its own checked-flourish,
    /// BEFORE the row actually disappears (ReminderCheckbox's own delay,
    /// then ProjectListViewModel.completeTodo's animated removal).
    @State private var checkingTodoIds: Set<String> = []

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

    /// 2026-08-06, Lino: "zuerst kommt der eintrag... darunter kommt
    /// auftraggeber: Projekt" — clientName is optional (not every project
    /// has an Auftraggeber set), falls back to the bare project name.
    private static func clientProjectLabel(_ clientName: String?, _ projectName: String) -> String {
        guard let clientName, !clientName.isEmpty else { return projectName }
        return "\(clientName): \(projectName)"
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
                Text(Self.clientProjectLabel(deadline.projectClientName, deadline.projectName))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // 2026-08-06, Lino: "darunter links der pipeline batch und
                // rechts dann die deadline" — exact 3-line spec, replaces
                // the old project/section line + status pill (status is
                // still readable via the colored dot on the postproduction
                // grid tile itself, not re-added here since he didn't ask
                // for it back).
                HStack {
                    PipelineBadge(stage: deadline.pipelineStage)
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
        let isChecking = checkingTodoIds.contains(todo.id)
        HStack(alignment: .top, spacing: 12) {
            ReminderCheckbox(
                action: { await viewModel.completeTodo(todo) },
                onCheckingChange: { checking in
                    if checking {
                        checkingTodoIds.insert(todo.id)
                    } else {
                        checkingTodoIds.remove(todo.id)
                    }
                }
            )
            .accessibilityLabel(language.t("todoSidebar.markDone"))
            .padding(.top, 1)

            Button {
                selectProject(id: todo.projectId)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(todo.text)
                        .font(.body)
                        .strikethrough(isChecking)
                        .foregroundStyle(isChecking ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    Text(Self.clientProjectLabel(todo.projectClientName, todo.projectName))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // 2026-08-06 — same "badge left, deadline right" spec as
                    // deadlineRow above.
                    HStack {
                        PipelineBadge(stage: todo.pipelineStage)
                        Spacer()
                        if let dueAt = todo.dueAt {
                            Text(Self.formatDateTime(dueAt))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(dueAt < Date() ? .red : .secondary)
                        }
                    }
                    .padding(.top, 1)
                }
            }
            .buttonStyle(.plain)
            // Can't navigate away mid-check — the row is about to vanish,
            // and completeTodo's revert-on-failure path expects it still
            // sitting in the same spot.
            .disabled(isChecking)
        }
        .padding(.vertical, 3)
        .animation(.easeInOut(duration: 0.2), value: isChecking)
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

/// 2026-08-06, Lino: "auf der todoliste soll auch zu sehen sein, in welcher
/// pipeline die todo ist, also Idee, Script/Shotlist, Postproduction, diese
/// info über der deadline darstellen" — same label/tintColor as
/// ProjectPipelineStage already provides (shared with the project-tile
/// badge, see ProjectListView's own tile), just a small pill instead of a
/// full tile badge to fit this sheet's compact rows.
private struct PipelineBadge: View {
    let stage: ProjectPipelineStage

    var body: some View {
        Text(stage.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(stage.tintColor, in: Capsule())
    }
}

/// Apple Reminders' own checkbox — 2026-08-06 correction: the first pass
/// kept the ring in the same muted gray the old hand-drawn circle already
/// used, which (combined with insetGrouped turning out to be a no-op — see
/// below) read as "nothing changed" at a glance. Real Reminders rings are
/// COLORED (each list's own tint, visible even in cross-list smart views
/// like "Today"/"All" — the closest analogue to this cross-project sheet),
/// not gray, so this now uses the app's own accent blue for an
/// unmistakably different, unmistakably "Reminders" look: a bold colored
/// ring that fills with a colored disc + white checkmark (SF Symbol
/// `.palette` rendering — same two-layer technique Reminders itself uses)
/// on tap, before handing off to `action`. The brief local flourish runs
/// independently of the network call so the tap always feels instant;
/// `action` is expected to remove the row from its parent list shortly
/// after (this sheet only ever shows OPEN todos), which is why this never
/// needs to reset back to unchecked.
///
/// 2026-08-06, Lino: "wenn man in der todoliste was abhackt, soll es mit
/// einer animation zuerst durchgestrichen werden und dann mit einer
/// animation verschwinden" — `onCheckingChange(true)` fires the moment the
/// disc starts filling, letting the PARENT row strike through its text
/// (todoRow can't hold its own @State, it's a plain function) for the same
/// ~450ms window before `action` actually removes the row.
private struct ReminderCheckbox: View {
    let action: () async -> Void
    var onCheckingChange: (Bool) -> Void = { _ in }
    @State private var checked = false

    var body: some View {
        Button {
            guard !checked else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { checked = true }
            onCheckingChange(true)
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                await action()
                // Covers the revert-on-failure path (completeTodo re-adds
                // the todo on a failed PATCH) — without this, a reverted
                // row would be stuck struck-through/disabled forever since
                // nothing else ever clears this todo's id back out.
                onCheckingChange(false)
            }
        } label: {
            Group {
                // `.palette` rendering only makes sense for "checkmark.circle.fill"
                // (two real layers: checkmark glyph + disc fill) — plain
                // "circle" is a single-layer outline, so applying `.palette`
                // there would just paint that ONE layer in the first color.
                // Two distinct render paths instead of one unified modifier
                // chain for this reason.
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.system(size: 26, weight: .regular))
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
