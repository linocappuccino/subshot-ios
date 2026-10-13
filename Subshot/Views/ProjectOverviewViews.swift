import SwiftUI

// 2026-10-13, Lino: "Folgendes umsetzen (auch in der iOS App was passt): Suche und Filter, Pipeline-
// Fortschritt auf der Kachel, nächster Termin, Kundenlogo, Archiv, Kalenderansicht, Speicher pro
// Projekt" — the app side of the web's ProjectOverviewBar / ProjectTileMeta / ProjectCalendar.
// No sorting on purpose (Lino: "sortieren soll man nicht können").

/// overview data shared by the root screen and every folder screen
@MainActor
final class ProjectOverviewStore: ObservableObject {
    static let shared = ProjectOverviewStore()

    @Published private(set) var meta: [String: ProjectMeta] = [:]
    /// every non-archived project of every folder (search / step filter)
    @Published private(set) var allProjects: [Project] = []
    @Published private(set) var archivedProjects: [Project] = []
    @Published private(set) var archiveLoaded = false

    func loadMeta() async {
        if let m = try? await APIClient.shared.overviewMeta() { meta = m }
    }

    func loadAll() async {
        if let p = try? await APIClient.shared.listAllProjects(archived: false) { allProjects = p }
    }

    func loadArchived() async {
        if let p = try? await APIClient.shared.listAllProjects(archived: true) {
            archivedProjects = p
            archiveLoaded = true
        }
    }

    /// projects per current step (non-archived), for the filter chips
    var counts: [String: Int] {
        var c: [String: Int] = ["all": 0]
        for m in meta.values where !m.archived {
            c["all", default: 0] += 1
            c[m.currentStep, default: 0] += 1
        }
        return c
    }

    func setArchived(_ project: Project, _ archived: Bool) async -> Bool {
        guard (try? await APIClient.shared.setProjectArchived(projectId: project.id, archived: archived)) != nil else { return false }
        await loadMeta()
        await loadAll()
        await loadArchived()
        return true
    }
}

// MARK: - Tile pieces

private let ringGreen = Color(red: 0x30 / 255, green: 0xd1 / 255, blue: 0x58 / 255)

private struct MiniRing: View {
    let ratio: Double
    let done: Bool
    var size: CGFloat = 13

    var body: some View {
        if done {
            Circle()
                .fill(ringGreen)
                .frame(width: size, height: size)
                .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .black)).foregroundStyle(.black))
        } else {
            ZStack {
                Circle().stroke(.white.opacity(0.28), lineWidth: 2)
                if ratio > 0 {
                    Circle().trim(from: 0, to: ratio).stroke(ringGreen, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
            }
            .frame(width: size - 2, height: size - 2)
            .frame(width: size, height: size)
        }
    }
}

/// the pipeline as a frosted capsule of mini rings + the current step's name
struct PipelineRingsBadge: View {
    let meta: ProjectMeta
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(meta.steps.enumerated()), id: \.offset) { _, s in
                MiniRing(ratio: s.ratio, done: s.done)
            }
            Text(language.t("overview.step.\(meta.currentStep)"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.leading, 2)
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// the client's logo on a small white plate
struct ClientLogoBadge: View {
    let url: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: 52, maxHeight: 18)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}

enum OverviewText {
    @MainActor
    static func nextEvent(_ e: OverviewNextEvent, _ language: AppLanguage) -> String {
        guard let date = e.date else { return "" }
        let days = OverviewDates.daysFromToday(date)
        let when: String
        if e.overdue && days < 0 {
            when = language.t("overview.when.overdue").replacingOccurrences(of: "{n}", with: "\(-days)")
        } else if days == 0 {
            when = language.t("overview.when.today")
        } else if days == 1 {
            when = language.t("overview.when.tomorrow")
        } else if days > 1 && days <= 14 {
            when = language.t("overview.when.inDays").replacingOccurrences(of: "{n}", with: "\(days)")
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: language.current == "en" ? "en_GB" : "de_CH")
            f.dateFormat = "dd.MM."
            when = language.t("overview.when.on").replacingOccurrences(of: "{date}", with: f.string(from: date))
        }
        return language.t("overview.next.\(e.kind)").replacingOccurrences(of: "{when}", with: when)
    }

    static func storage(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// "🎬 Dreh in 3 Tagen" — red when overdue, amber for today/tomorrow
struct NextEventChip: View {
    let event: OverviewNextEvent
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        let days = event.date.map(OverviewDates.daysFromToday) ?? 99
        let icon = event.kind == "shoot" ? "🎬" : event.kind == "deadline" ? "⏰" : "🔗"
        let (bg, fg): (Color, Color) = event.overdue
            ? (.red.opacity(0.2), Color(red: 1, green: 0.55, blue: 0.55))
            : days <= 1 ? (.orange.opacity(0.16), Color(red: 1, green: 0.85, blue: 0.5)) : (.white.opacity(0.07), .white.opacity(0.7))
        HStack(spacing: 3) {
            Text(icon)
            Text(OverviewText.nextEvent(event, language)).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(bg, in: Capsule())
    }
}

/// under the title: next date + storage
struct ProjectTileFooter: View {
    let meta: ProjectMeta

    var body: some View {
        let storage = OverviewText.storage(meta.storageBytes)
        if meta.nextEvent != nil || storage != nil {
            HStack(spacing: 6) {
                if let e = meta.nextEvent { NextEventChip(event: e) }
                Spacer(minLength: 0)
                if let storage {
                    Text(storage)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}

// MARK: - Filter bar

struct OverviewFilterBar: View {
    @Binding var step: String
    @Binding var archive: Bool
    let counts: [String: Int]
    @ObservedObject private var language = AppLanguage.shared

    private let steps = ["all", "ideas", "scenes", "postproduction", "deliver", "done"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { s in
                    chip(
                        title: language.t(s == "all" ? "overview.all" : "overview.step.\(s)"),
                        count: counts[s],
                        active: !archive && step == s
                    ) {
                        withAnimation(.snappy) {
                            step = s
                            archive = false
                        }
                    }
                }
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 3)
                chip(title: "🗄 " + language.t("overview.archive"), count: nil, active: archive) {
                    withAnimation(.snappy) { archive.toggle() }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: String, count: Int?, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text("\(count)").monospacedDigit().foregroundStyle(active ? .black.opacity(0.5) : .white.opacity(0.35))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? .black : .white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.07)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar

/// month view of every project's shooting days, Postproduction deadlines and Deliver link expiries
struct ProjectCalendarSheet: View {
    /// opens a project (the sheet closes first)
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared
    @State private var month: Date = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selected: String = OverviewDates.dayKey.string(from: Date())
    @State private var events: [CalendarEvent] = []
    @State private var loading = false

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: language.current == "en" ? "en_GB" : "de_CH")
        return c
    }

    /// the 6×7 grid of days (Monday first), nil = padding
    private var days: [Date?] {
        let first = month
        let weekday = cal.component(.weekday, from: first)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        var out: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<count { out.append(cal.date(byAdding: .day, value: d, to: first)) }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }

    private var byDay: [String: [CalendarEvent]] { Dictionary(grouping: events, by: \.date) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    weekdayRow
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                        ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                            if let day { dayCell(day) } else { Color.clear.frame(height: 46) }
                        }
                    }
                    legend
                    dayList
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(language.t("overview.calendar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("planning.close")) { dismiss() }
                }
            }
            .task(id: month) { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").font(.headline).frame(width: 36, height: 36) }
            Spacer()
            Text(monthTitle).font(.title3.weight(.semibold))
            if loading { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer()
            Button(language.t("overview.cal.today")) {
                month = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
                selected = OverviewDates.dayKey.string(from: Date())
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            Button { shift(1) } label: { Image(systemName: "chevron.right").font(.headline).frame(width: 36, height: 36) }
        }
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = cal.locale
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month).capitalized
    }

    private var weekdayRow: some View {
        let symbols = cal.shortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
        return HStack(spacing: 4) {
            ForEach(ordered, id: \.self) { s in
                Text(s.prefix(2)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let key = OverviewDates.dayKey.string(from: day)
        let items = byDay[key] ?? []
        let isToday = cal.isDateInToday(day)
        let isSelected = key == selected
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            selected = key
        } label: {
            VStack(spacing: 4) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 15, weight: isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? .black : (isToday ? Color.accentColor : .primary))
                    .frame(width: 30, height: 30)
                    .background(isSelected ? Color.white : .clear, in: Circle())
                HStack(spacing: 2) {
                    ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, e in
                        Circle().fill(Self.color(e.kind)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(["shoot", "deadline", "deliver_expiry"], id: \.self) { k in
                HStack(spacing: 5) {
                    Circle().fill(Self.color(k)).frame(width: 7, height: 7)
                    Text(language.t("overview.cal.\(k)")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dayList: some View {
        let items = byDay[selected] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if let d = OverviewDates.dayKey.date(from: selected) {
                Text(d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(cal.locale ?? .current)))
                    .font(.headline)
            }
            if items.isEmpty {
                Text(language.t("overview.cal.empty")).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { e in
                Button {
                    dismiss()
                    onOpen(e.projectId)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.color(e.kind)).frame(width: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.emoji.map { "\($0) " } ?? "")\(e.projectName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(detail(e)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ e: CalendarEvent) -> String {
        var parts = [language.t("overview.cal.\(e.kind)")]
        if let s = e.start, let end = e.end { parts.append("\(s)–\(end)") }
        if let n = e.scenes { parts.append(language.t("overview.cal.scenes").replacingOccurrences(of: "{n}", with: "\(n)")) }
        if let l = e.label, !l.isEmpty { parts.append(l) }
        if e.done == true { parts.append("✓ " + language.t("overview.cal.done")) }
        if let c = e.clientName, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "shoot": return Color(red: 1, green: 0.27, blue: 0.23)
        case "deadline": return .orange
        default: return Color(red: 0.04, green: 0.52, blue: 1)
        }
    }

    private func shift(_ months: Int) {
        if let m = cal.date(byAdding: .month, value: months, to: month) { month = m }
    }

    private func load() async {
        guard let last = cal.date(byAdding: DateComponents(month: 1, day: -1), to: month) else { return }
        loading = true
        defer { loading = false }
        if let e = try? await APIClient.shared.calendarEvents(from: OverviewDates.dayKey.string(from: month), to: OverviewDates.dayKey.string(from: last)) {
            events = e
        }
    }
}
