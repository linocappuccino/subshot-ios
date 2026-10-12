import SwiftUI

// 2026-10-12 — web parity for "Zeitplan mit Live-Verzug" (Lino: "Aus Dauer und Drehreihenfolge
// entsteht ein Tagesplan mit Uhrzeiten. Während des Drehs siehst du «X Min. hinter/vor Plan» und
// Vorschläge, was man kürzen oder streichen könnte."). The server does the arithmetic
// (app/live_schedule.py); this shows it and can create the day plan from the open shotlist.

struct LiveScheduleSheet: View {
    let projectId: String
    /// the open shotlist in shooting order (for "Tagesplan erstellen")
    let planScenes: [Scene]
    /// after times were set (reload the scenes)
    var onPlanned: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared
    @State private var schedule: LiveSchedule?
    @State private var failed = false
    @State private var day: String?
    @State private var autoDate = Date()
    @State private var autoStart = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var autoBusy = false
    @State private var autoResult: String?

    var body: some View {
        NavigationStack {
            List {
                if let s = schedule {
                    if let days = s.days, days.count > 1 {
                        Section {
                            Picker(language.t("schedule.autoDate"), selection: Binding(get: { s.date }, set: { day = $0; Task { await load() } })) {
                                ForEach(days, id: \.self) { d in Text(Self.dayLabel(d)).tag(d) }
                            }
                        }
                    }
                    if s.rows.isEmpty {
                        Section { Text(language.t("schedule.empty")).foregroundStyle(.secondary) }
                    } else {
                        Section { statusCard(s) }
                        Section {
                            ForEach(s.rows) { row($0) }
                        }
                        if let sug = s.suggestions, !sug.isEmpty || s.shorten != nil {
                            Section(language.t("schedule.suggestTitle")) {
                                ForEach(sug) { x in
                                    HStack {
                                        Text("\(x.number.map { "\($0) · " } ?? "")\(x.title)")
                                        Spacer()
                                        Text("−\(x.minutes ?? 0) Min. · \(language.t("schedule.cut"))").foregroundStyle(.secondary).font(.footnote)
                                    }
                                }
                                if let sh = s.shorten {
                                    Text(language.t("schedule.shorten").replacingOccurrences(of: "{scenes}", with: "\(sh.scenes)").replacingOccurrences(of: "{n}", with: "\(sh.minutesEach)"))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if failed {
                    Section { Text(language.t("planning.failed")).foregroundStyle(.secondary) }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }

                if !planScenes.isEmpty {
                    Section {
                        DatePicker(language.t("schedule.autoDate"), selection: $autoDate, displayedComponents: .date)
                        DatePicker(language.t("schedule.autoStart"), selection: $autoStart, displayedComponents: .hourAndMinute)
                        Button {
                            Task { await autoPlan() }
                        } label: {
                            HStack {
                                Text(language.t("schedule.autoApply"))
                                if autoBusy { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(autoBusy)
                        if let autoResult { Text(autoResult).font(.footnote).foregroundStyle(.secondary) }
                    } header: {
                        Text(language.t("schedule.autoTitle"))
                    } footer: {
                        Text(language.t("schedule.autoHint"))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.t("schedule.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(language.t("places.done")) { dismiss() } }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func statusCard(_ s: LiveSchedule) -> some View {
        let (text, color): (String, Color) = {
            switch s.state {
            case "not_started": return (language.t("schedule.notStarted"), .secondary)
            case "wrapped" where s.delayMin == 0: return (language.t("schedule.wrapped"), .green)
            default:
                if s.delayMin >= 1 { return (language.t("schedule.behind").replacingOccurrences(of: "{n}", with: "\(s.delayMin)"), .red) }
                if s.delayMin <= -1 { return (language.t("schedule.ahead").replacingOccurrences(of: "{n}", with: "\(-s.delayMin)"), .green) }
                return (language.t("schedule.onPlan"), .green)
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.title2.weight(.semibold)).foregroundStyle(color)
            if let p = s.plannedEnd, let pr = s.projectedEnd {
                Text(language.t("schedule.wrap").replacingOccurrences(of: "{planned}", with: p).replacingOccurrences(of: "{projected}", with: pr))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let d = s.done, let t = s.total {
                HStack(spacing: 6) {
                    ProgressRingView(ratio: t > 0 ? Double(d) / Double(t) : 0, done: t > 0 && d == t, size: 15)
                    Text("\(d)/\(t) " + language.t("shotlistProgress.shot")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ r: LiveSchedule.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.newStart ?? r.plannedStart)
                    .font(.subheadline.monospacedDigit().weight(r.newStart != nil ? .semibold : .regular))
                    .foregroundStyle(r.newStart != nil ? Color.orange : Color.primary)
                if r.newStart != nil {
                    Text(r.plannedStart).font(.caption2.monospacedDigit()).strikethrough().foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(!r.intermediate ? (r.number.map { "\($0)\(r.letter ?? "") · " } ?? "") : "")\(r.title.isEmpty ? "–" : r.title)")
                    .foregroundStyle(r.intermediate ? .secondary : .primary)
                if let m = r.minutes { Text("\(m) Min.").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            statusBadge(r)
        }
        .listRowBackground(r.status == "current" ? Color.accentColor.opacity(0.12) : nil)
    }

    @ViewBuilder
    private func statusBadge(_ r: LiveSchedule.Row) -> some View {
        switch r.status {
        case "done":
            Label(r.doneAt ?? language.t("schedule.statusDone"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case "not_shot":
            Text(language.t("schedule.statusNotShot")).font(.caption).foregroundStyle(.red)
        case "current":
            Text(language.t("schedule.statusCurrent")).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
        default:
            EmptyView()
        }
    }

    private func load() async {
        do {
            schedule = try await APIClient.shared.liveSchedule(projectId: projectId, date: day)
            failed = false
        } catch {
            if !APIError.isCancellation(error) { failed = true }
        }
    }

    private func autoPlan() async {
        autoBusy = true
        defer { autoBusy = false }
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Europe/Zurich")
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.timeZone = TimeZone(identifier: "Europe/Zurich")
        tf.dateFormat = "HH:mm"
        let date = df.string(from: autoDate)
        do {
            let r = try await APIClient.shared.autoSchedule(projectId: projectId, date: date, start: tf.string(from: autoStart),
                                                            sceneIds: planScenes.filter { !$0.isProjectInfo }.map(\.id))
            autoResult = language.t("schedule.autoDone").replacingOccurrences(of: "{n}", with: "\(r.updated)").replacingOccurrences(of: "{end}", with: r.end ?? "–")
            day = date
            await onPlanned()
            await load()
        } catch {
            autoResult = error.localizedDescription
        }
    }

    static func dayLabel(_ iso: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: AppLanguage.shared.current == "en" ? "en_GB" : "de_CH")
        out.dateFormat = "EEE dd.MM.yyyy"
        return out.string(from: d)
    }
}
