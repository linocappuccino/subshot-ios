import SwiftUI

// 2026-10-12 — web parity for "Drehreihenfolge optimieren" (no AI: same location / rig / lens
// together, morning light first, golden hour in the evening — server app/shooting_order.py).
// Shows the current order next to the suggestion with the metrics; "Übernehmen" saves it as the
// shotlist's Shot-Reihenfolge.

struct ShootingOrderSheet: View {
    @ObservedObject var viewModel: ShotListViewModel
    let sectionId: String
    /// switch the shotlist to the Shot-Reihenfolge after applying
    var onApplied: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared
    @State private var suggestion: ShootingOrderSuggestion?
    @State private var failed = false
    @State private var showCurrent = false
    @State private var busy = false

    private var section: SceneSection? { viewModel.sections.first { $0.id == sectionId } }
    private var byId: [String: Scene] { Dictionary(uniqueKeysWithValues: viewModel.scenes(in: section).map { ($0.id, $0) }) }
    private var numbers: [String: Int] { viewModel.sceneNumbers(in: section) }

    var body: some View {
        NavigationStack {
            List {
                if let s = suggestion {
                    Section { Text(language.t("optimize.intro")).font(.footnote).foregroundStyle(.secondary) }
                    Section {
                        metric(language.t("optimize.locations"), s.before.locationChanges, s.after.locationChanges)
                        metric(language.t("optimize.km"), Int(s.before.km.rounded()), Int(s.after.km.rounded()))
                        metric(language.t("optimize.rigs"), s.before.rigChanges, s.after.rigChanges)
                        metric(language.t("optimize.lenses"), s.before.lensChanges, s.after.lensChanges)
                    }
                    if !s.changed {
                        Section { Label(language.t("optimize.already"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    } else {
                        Section {
                            Picker("", selection: $showCurrent) {
                                Text(language.t("optimize.proposed")).tag(false)
                                Text(language.t("optimize.current")).tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        Section {
                            ForEach(Array((showCurrent ? s.current : s.order).enumerated()), id: \.element) { i, id in
                                row(i, id, reasons: showCurrent ? [] : (s.reasons[id] ?? []))
                            }
                        }
                    }
                } else if failed {
                    Section { Text(language.t("planning.failed")).foregroundStyle(.secondary) }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.t("optimize.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.t("planning.close")) { dismiss() } }
                if let s = suggestion, s.changed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(language.t("optimize.apply")) {
                            busy = true
                            Task {
                                await viewModel.applyShootingOrder(s.order, in: sectionId)
                                busy = false
                                onApplied()
                                dismiss()
                            }
                        }
                        .disabled(busy)
                    }
                }
            }
            .task {
                do {
                    suggestion = try await APIClient.shared.suggestShootingOrder(sectionId: sectionId)
                } catch {
                    failed = true
                }
            }
        }
    }

    private func metric(_ name: String, _ a: Int, _ b: Int) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("\(a)").foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text("\(b)").fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(b < a ? Color.green : b > a ? Color.orange : Color.primary)
        }
    }

    private func row(_ i: Int, _ id: String, reasons: [String]) -> some View {
        let scene = byId[id]
        let info = suggestion?.scenes[id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(i + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                Text("\(scene?.isIntermediateStep == false ? (numbers[id].map { "\($0) · " } ?? "") : "")\(scene?.name ?? "–")")
                    .foregroundStyle(scene?.isIntermediateStep == true ? .secondary : .primary)
                Spacer()
                if let info {
                    Text([info.place == "ext" ? "EXT" : info.place == "int" ? "INT" : "",
                          ["morning": "🌅", "evening": "🌇", "night": "🌙"][info.light] ?? "",
                          info.rig].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let loc = info?.location ?? scene?.locationAddress {
                Text("📍 " + loc).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 32)
            }
            if !reasons.isEmpty {
                HStack(spacing: 4) {
                    ForEach(reasons, id: \.self) { r in
                        Text(language.t("optimize.r.\(r)"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                .padding(.leading, 32)
            }
        }
    }
}
