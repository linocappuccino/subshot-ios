import SwiftUI

/// #11 Schritt 6 (Postproduction-Tracking) — eigener Bereich pro Projekt
/// (2026-07-17, Lino: eigener Tab statt Einbau in die bestehende
/// Szenenübersicht). Listet jede Section, die per "Ab in die
/// Postproduction"-Aktion (ShotListView's Section-Kontextmenü) explizit
/// dorthin geschickt wurde. Status von jeder Rolle änderbar, Deadline nur
/// ab "projektleiter" (2026-07-19, Lino's finale Rollen-Spezifikation) —
/// serverseitig durchgesetzt, hier nur gespiegelt, damit ein Editor gar
/// nicht erst ein Deadline-Feld sieht, das der Server ohnehin ablehnen
/// würde.
struct PostproductionListView: View {
    @ObservedObject var viewModel: ShotListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var myRole: String?
    /// #122 — Video-Feedback-Link teilen (kind="video"), gleicher
    /// Share-Sheet-Mechanismus wie ShotListView's eigener Teilen-Button.
    @State private var showingShareLinkSheet = false
    @State private var shareLinkURL: URL?
    @State private var isPresentingShareSheet = false

    private var sections: [SceneSection] {
        viewModel.sections.filter(\.inPostproduction)
    }
    private var canEditStatus: Bool { myRole == "editor" || myRole == "projektleiter" || myRole == "owner" }
    private var canEditDeadline: Bool { myRole == "projektleiter" || myRole == "owner" }

    var body: some View {
        NavigationStack {
            Group {
                if sections.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Abschnitte",
                        systemImage: "checklist",
                        description: Text("Auf der Szenenübersicht: Abschnitt gedrückt halten → „Ab in die Postproduction“, sobald alle Szenen im Kasten sind.")
                    )
                } else {
                    List(sections) { section in
                        PostproductionRow(
                            section: section,
                            canEditStatus: canEditStatus,
                            canEditDeadline: canEditDeadline,
                            onStatusChange: { status in
                                Task { await viewModel.patchSectionPostproduction(section, status: status) }
                            },
                            onDeadlineChange: { date in
                                if let date {
                                    Task { await viewModel.patchSectionPostproduction(section, deadline: date) }
                                } else {
                                    Task { await viewModel.patchSectionPostproduction(section, clearDeadline: true) }
                                }
                            }
                        )
                    }
                }
            }
            .navigationTitle("Postproduction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                if canEditStatus {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            showingShareLinkSheet = true
                        } label: {
                            Image(systemName: "link")
                        }
                    }
                }
            }
        }
        .task {
            if let me = try? await APIClient.shared.me() {
                myRole = viewModel.members.first(where: { $0.userId == me.id })?.role
            }
        }
        .sheet(isPresented: $showingShareLinkSheet) {
            ShareLinkSheet(projectId: viewModel.projectId, kind: "video") { url in
                shareLinkURL = url
                isPresentingShareSheet = true
            }
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            if let shareLinkURL {
                ActivityView(activityItems: [shareLinkURL])
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PostproductionRow: View {
    let section: SceneSection
    let canEditStatus: Bool
    let canEditDeadline: Bool
    let onStatusChange: (PostproductionStatus) -> Void
    let onDeadlineChange: (Date?) -> Void

    @State private var deadline: Date
    /// #11 Schritt 7 (Video-Feedback-Tool) — Videos einer Section lazily
    /// geladen, nur wenn wirklich aufgeklappt (gleiche Begruendung wie
    /// web's expandedVideos: nicht jedes <video>/AVPlayer sofort fuer
    /// jede Zeile vorbereiten).
    @State private var showingVideos = false

    init(
        section: SceneSection, canEditStatus: Bool, canEditDeadline: Bool,
        onStatusChange: @escaping (PostproductionStatus) -> Void, onDeadlineChange: @escaping (Date?) -> Void
    ) {
        self.section = section
        self.canEditStatus = canEditStatus
        self.canEditDeadline = canEditDeadline
        self.onStatusChange = onStatusChange
        self.onDeadlineChange = onDeadlineChange
        _deadline = State(initialValue: section.postproductionDeadline ?? .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showingVideos.toggle() }
            } label: {
                HStack {
                    Text(section.name).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showingVideos ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            if canEditStatus {
                Picker("Status", selection: Binding(
                    get: { section.postproductionStatus ?? .wartend },
                    set: { onStatusChange($0) }
                )) {
                    ForEach(PostproductionStatus.allCases, id: \.self) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Text((section.postproductionStatus ?? .wartend).label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if canEditDeadline {
                Toggle("Deadline", isOn: Binding(
                    get: { section.postproductionDeadline != nil },
                    set: { onDeadlineChange($0 ? deadline : nil) }
                ))
                if section.postproductionDeadline != nil {
                    DatePicker("Datum", selection: Binding(
                        get: { deadline },
                        set: { deadline = $0; onDeadlineChange($0) }
                    ), displayedComponents: .date)
                    .labelsHidden()
                }
            } else if let deadline = section.postproductionDeadline {
                Text("Deadline: \(deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showingVideos {
                VideoPanelView(sectionId: section.id, canEdit: canEditStatus)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}
