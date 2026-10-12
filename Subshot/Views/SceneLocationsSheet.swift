import SwiftUI

// 2026-10-12 — web parity for "📍 Drehorte" (Lino: "wie kann man zb. szene 1-10 einer location
// zuweisen und dann szene 11-15 einer anderen", "man soll immer den ort direkt ausgeschrieben
// anwählen können ... die versch. orte können eine unterschiedliche farbe haben"):
// - Orte: the shotlist's places (pin in its colour, name + full address, scene count), one is the
//   default (Section.location) every scene without its own place follows; "+ Ort hinzufügen".
// - Szenen: one row per scene with its place as a coloured pill — tap it to pick another place by
//   name; tick several rows (long-press = "Bis hier auswählen") and tap a place in the bottom bar.

struct SceneLocationsSheet: View {
    @ObservedObject var viewModel: ShotListViewModel
    let sectionId: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared

    @State private var selected: Set<String> = []
    @State private var anchor: String?
    @State private var extra: [(String, Double?, Double?)] = []
    @State private var adding = false

    private var section: SceneSection? { viewModel.sections.first { $0.id == sectionId } }
    private var rows: [Scene] { viewModel.scenes(in: section).filter { !$0.isProjectInfo && !$0.isIntermediateStep } }
    private var places: [ShotlistPlace] { ShotlistPlace.build(section: section, scenes: viewModel.scenes(in: section), extra: extra) }
    private var numbers: [String: Int] { viewModel.sceneNumbers(in: section) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(places) { p in placeRow(p) }
                    if adding {
                        PlaceSearchField { address, lat, lng in
                            if let section, section.locationAddress == nil {
                                Task { await viewModel.updateSectionLocation(section, address: address, lat: lat, lng: lng) }
                            } else {
                                extra.append((address, lat, lng))
                            }
                            adding = false
                        }
                    } else {
                        Button {
                            adding = true
                        } label: {
                            Label(language.t("places.add"), systemImage: "plus")
                        }
                    }
                } header: {
                    Text(language.t("places.placesHeader"))
                } footer: {
                    Text(language.t("places.hint"))
                }

                if !rows.isEmpty && !places.isEmpty {
                    Section {
                        ForEach(rows) { scene in sceneRow(scene) }
                    } header: {
                        HStack {
                            Text(language.t("places.scenesHeader"))
                            Spacer()
                            Button(selected.count == rows.count ? language.t("places.clearSelection") : language.t("places.selectAll")) {
                                selected = selected.count == rows.count ? [] : Set(rows.map(\.id))
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    } footer: {
                        Text(language.t("places.assignHint"))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.t("places.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("places.done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty, let section {
                    moveBar(section)
                }
            }
        }
    }

    // MARK: rows

    private func placeRow(_ p: ShotlistPlace) -> some View {
        let count = rows.filter { viewModel.placeAddress(of: $0, in: section) == p.address }.count
        return HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(p.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.short).font(.body)
                Text(p.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(language.t("places.sceneCount").replacingOccurrences(of: "{n}", with: "\(count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if p.isDefault {
                    Text(language.t("places.default"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                } else if let section, p.lat != nil {
                    Button(language.t("places.makeDefault")) {
                        Task { await viewModel.setDefaultPlace(p, in: section) }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func sceneRow(_ scene: Scene) -> some View {
        let on = selected.contains(scene.id)
        let address = viewModel.placeAddress(of: scene, in: section)
        let color = places.first { $0.address == address }?.color
        return HStack(spacing: 10) {
            Button {
                toggle(scene.id)
            } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            Text(numbers[scene.id].map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Text(scene.name?.isEmpty == false ? scene.name! : "–")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { toggle(scene.id) }
            Menu {
                placeMenu(for: [scene.id])
            } label: {
                PlacePill(address: address, color: color, emptyLabel: language.t("places.noPlace"), muted: scene.locationAddress == nil, full: false)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(on ? Color.accentColor.opacity(0.12) : nil)
        .contextMenu {
            Button {
                selectRange(to: scene.id)
            } label: {
                Label(language.t("places.selectRange"), systemImage: "arrow.up.and.down.text.horizontal")
            }
        }
    }

    @ViewBuilder
    private func placeMenu(for ids: [String]) -> some View {
        if let section {
            ForEach(places) { p in
                Button {
                    Task { await viewModel.assignPlace(p, to: ids, in: section) }
                } label: {
                    Label(p.short + (p.isDefault ? " · " + language.t("places.default") : ""), systemImage: "mappin.circle.fill")
                }
            }
        }
    }

    private func moveBar(_ section: SceneSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.t("places.moveTo").replacingOccurrences(of: "{n}", with: "\(selected.count)"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(places) { p in
                        Button {
                            let ids = rows.map(\.id).filter { selected.contains($0) }
                            Task { await viewModel.assignPlace(p, to: ids, in: section) }
                            selected = []
                            anchor = nil
                        } label: {
                            PlacePill(address: p.address, color: p.color, full: false)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(true)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: selection

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        anchor = id
    }

    private func selectRange(to id: String) {
        guard let a = anchor, let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == id }) else {
            toggle(id)
            return
        }
        for k in min(i, j)...max(i, j) { selected.insert(rows[k].id) }
        anchor = id
    }
}

/// address search (Google Places via the backend) — calls back with a picked place
struct PlaceSearchField: View {
    let onPick: (String, Double, Double) -> Void
    @StateObject private var completer = LocationSearchCompleter()
    @State private var query = ""
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(language.t("common.addressPlaceholder"), text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, v in completer.update(query: v) }
            ForEach(completer.results.prefix(5), id: \.self) { r in
                Button {
                    Task {
                        guard let resolved = try? await LocationSearch.resolve(r, sessionToken: completer.sessionToken) else { return }
                        onPick(resolved.address, resolved.lat, resolved.lng)
                        completer.clear()
                        query = ""
                    }
                } label: {
                    Text(r.title).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
    }
}
