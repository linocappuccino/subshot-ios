import SwiftUI

// 2026-10-12 — web parity for "Callsheet / Dispo automatisch" (Lino: "ein Link bzw. PDF pro Drehtag
// für die Crew: Location und Karte, Zuständige und Zeiten, plus Wetter und Sonnenstand (Golden Hour,
// Sonnenuntergang) für jede Location"). Shooting days come from the scenes' start times; the server
// builds the day (weather: Open-Meteo up to 16 days ahead, sun: computed) and the PDF.

struct CallsheetSheet: View {
    let projectId: String
    let projectName: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared
    @State private var days: [CallsheetDay]?
    @State private var day: String?
    @State private var sheet: Callsheet?
    @State private var pdfURL: URL?
    @State private var pdfBusy = false

    var body: some View {
        NavigationStack {
            List {
                if let days {
                    if days.isEmpty {
                        Section { Text(language.t("callsheet.noDays")).foregroundStyle(.secondary) }
                    } else {
                        Section {
                            Picker(language.t("schedule.autoDate"), selection: Binding(get: { day ?? days[0].date }, set: { day = $0; pdfURL = nil; Task { await loadDay() } })) {
                                ForEach(days) { d in
                                    Text("\(LiveScheduleSheet.dayLabel(d.date)) · \(d.start ?? "")–\(d.end ?? "")").tag(d.date)
                                }
                            }
                        }
                        if let s = sheet, s.date == day {
                            content(s)
                        } else {
                            Section { ProgressView().frame(maxWidth: .infinity) }
                        }
                    }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.t("callsheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.t("places.done")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label(language.t("callsheet.pdf"), systemImage: "square.and.arrow.up") }
                    } else if day != nil {
                        Button {
                            Task { await makePDF() }
                        } label: {
                            if pdfBusy { ProgressView() } else { Label(language.t("callsheet.pdf"), systemImage: "doc.richtext") }
                        }
                        .disabled(pdfBusy)
                    }
                }
            }
            .task { await loadDays() }
        }
    }

    @ViewBuilder
    private func content(_ s: Callsheet) -> some View {
        ForEach(s.locations) { l in
            Section {
                if let w = l.weather {
                    Text("\(w.symbol) \(w.text) · \(Int((w.tMin ?? 0).rounded()))–\(Int((w.tMax ?? 0).rounded())) °C · \(language.t("callsheet.rain")) \(w.rainProb ?? 0) % · \(language.t("callsheet.wind")) \(Int((w.wind ?? 0).rounded())) km/h")
                        .font(.subheadline)
                } else if l.lat != nil {
                    Text(s.forecastFrom.map { language.t("callsheet.forecastFrom").replacingOccurrences(of: "{date}", with: LiveScheduleSheet.dayLabel($0)) } ?? language.t("callsheet.noForecast"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let sun = l.sun, let rise = sun.sunrise {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("☀ \(language.t("callsheet.sunrise")) \(rise) · \(language.t("callsheet.sunset")) \(sun.sunset ?? "–")")
                        Text("\(language.t("callsheet.golden")) \(sun.goldenMorning ?? "–") / \(sun.goldenEvening ?? "–")").foregroundStyle(.orange)
                        Text("\(language.t("callsheet.blue")) \(sun.blueMorning ?? "–") / \(sun.blueEvening ?? "–")").foregroundStyle(.cyan)
                    }
                    .font(.footnote)
                }
            } header: {
                HStack {
                    Text("L\(l.no) · \(l.address ?? "–")").textCase(nil)
                    Spacer()
                    if let m = l.maps, let url = URL(string: m) {
                        Link(language.t("callsheet.map"), destination: url).font(.caption).textCase(nil)
                    }
                }
            }
        }
        Section {
            ForEach(Array(s.rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(r.start ?? "")\(r.end.map { $0.isEmpty ? "" : "–\($0)" } ?? "")")
                        .font(.caption.monospacedDigit())
                        .frame(width: 78, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(!r.intermediate ? (r.number.map { "\($0)\(r.letter ?? "") · " } ?? "") : "")\(r.title.isEmpty ? "–" : r.title)")
                            .foregroundStyle(r.intermediate ? .secondary : .primary)
                        if !r.assignees.isEmpty { Text(r.assignees.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let w = r.weather { Text("\(w.symbol) \(Int(w.temp.rounded()))°").font(.caption.monospacedDigit()) }
                        if let loc = r.location { Text("L\(loc)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        if !s.crew.isEmpty {
            Section(language.t("callsheet.crew")) {
                ForEach(Array(s.crew.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading) {
                        Text(p.name ?? p.email ?? "–")
                        if let e = p.email, p.name != nil { Text(e).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func loadDays() async {
        guard let d = try? await APIClient.shared.callsheetDays(projectId: projectId) else { days = []; return }
        days = d
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(identifier: "Europe/Zurich")!, formatOptions: [.withFullDate])
        day = (d.first { $0.date >= today } ?? d.last)?.date
        await loadDay()
    }

    private func loadDay() async {
        guard let day else { return }
        sheet = try? await APIClient.shared.callsheet(projectId: projectId, date: day)
    }

    private func makePDF() async {
        guard let day else { return }
        pdfBusy = true
        defer { pdfBusy = false }
        pdfURL = try? await APIClient.shared.callsheetPDF(projectId: projectId, date: day, filename: "Callsheet \(projectName) \(day).pdf")
    }
}
