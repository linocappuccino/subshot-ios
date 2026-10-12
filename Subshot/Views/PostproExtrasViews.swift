import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// 2026-10-12 — web parity for the Postproduction additions:
// - FassungenChipsRow (Lino: "das mit den versch. fassungen ist so viel zu kompliziert und versteckt!
//   das muss viel einfacher sein!"): the Fassungen right on the tile — ✓ uploaded (menu: download /
//   replace / remove), dashed ⬆ missing (tap → from Photos or Files), "+ Fassung" presets.
// - QCBadge + QCSheet: the technical check of the newest version (internal only).
// - RoundsBadge: feedback rounds "Runde 2/3" with the agreed limit per video (internal only).

private let fassungPresets = ["16:9", "9:16", "1:1", "4:5", "Cutdown 30s", "Cutdown 15s", "Cutdown 6s", "Ohne Untertitel", "Mit Untertitel"]

struct FassungenChipsRow: View {
    let videoId: String
    let extras: VideoExtras
    let canEdit: Bool
    let onChange: (VideoExtras) -> Void
    let onError: (String) -> Void

    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.openURL) private var openURL
    @State private var uploading: Set<String> = []
    @State private var target: String?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        if canEdit || !extras.deliverables.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(extras.deliverables) { d in chip(d) }
                    if canEdit {
                        Menu {
                            ForEach(fassungPresets.filter { p in !extras.deliverables.contains { $0.label.lowercased() == p.lowercased() } }, id: \.self) { p in
                                Button(p) { Task { await add(p) } }
                            }
                        } label: {
                            Text("+ " + language.t("fassungen.add"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                        }
                    }
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .videos)
            .onChange(of: photoItem) { _, item in
                guard let item, let id = target else { return }
                photoItem = nil
                Task { await uploadFromPhotos(item, id: id) }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
                guard let id = target, case .success(let url) = result else { return }
                Task { await uploadFromFiles(url, id: id) }
            }
        }
    }

    @ViewBuilder
    private func chip(_ d: VideoDeliverable) -> some View {
        if uploading.contains(d.id) || d.status == "uploading" {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(d.label)
            }
            .modifier(ChipStyle(fill: Color.primary.opacity(0.08), stroke: nil, fg: .secondary))
        } else if d.status != "ready" {
            Menu {
                uploadButtons(d.id)
            } label: {
                Text("⬆ " + d.label).modifier(ChipStyle(fill: .clear, stroke: Color.secondary.opacity(0.6), fg: .primary, dashed: true))
            }
            .disabled(!canEdit)
        } else {
            Menu {
                Button {
                    Task {
                        do { openURL(try await APIClient.shared.deliverableDownloadURL(d.id)) } catch { onError(error.localizedDescription) }
                    }
                } label: { Label(language.t("fassungen.download"), systemImage: "arrow.down.circle") }
                if canEdit {
                    Section(language.t("fassungen.replace")) { uploadButtons(d.id) }
                    Button(role: .destructive) {
                        Task { await remove(d) }
                    } label: { Label(language.t("fassungen.remove"), systemImage: "trash") }
                }
            } label: {
                Text("✓ " + d.label).modifier(ChipStyle(fill: Color.green.opacity(0.16), stroke: nil, fg: .green))
            }
        }
    }

    @ViewBuilder
    private func uploadButtons(_ id: String) -> some View {
        Button {
            target = id
            showPhotos = true
        } label: { Label(language.t("fassungen.fromPhotos"), systemImage: "photo.on.rectangle") }
        Button {
            target = id
            showFiles = true
        } label: { Label(language.t("fassungen.fromFiles"), systemImage: "folder") }
    }

    // MARK: actions

    private func add(_ label: String) async {
        do {
            let d = try await APIClient.shared.createDeliverable(videoId: videoId, label: label)
            var x = extras
            x.deliverables.append(d)
            onChange(x)
        } catch { onError(error.localizedDescription) }
    }

    private func remove(_ d: VideoDeliverable) async {
        var x = extras
        x.deliverables.removeAll { $0.id == d.id }
        onChange(x)
        do { try await APIClient.shared.deleteDeliverable(d.id) } catch {
            onChange(extras)
            onError(error.localizedDescription)
        }
    }

    private func uploadFromPhotos(_ item: PhotosPickerItem, id: String) async {
        uploading.insert(id)
        defer { uploading.remove(id) }
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else { return }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            try await upload(movie.url, id: id)
        } catch { onError(error.localizedDescription) }
    }

    private func uploadFromFiles(_ url: URL, id: String) async {
        uploading.insert(id)
        defer { uploading.remove(id) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // copy out of the security scope first (the upload runs on a background session)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await upload(tmp, id: id)
        } catch { onError(error.localizedDescription) }
    }

    private func upload(_ fileURL: URL, id: String) async throws {
        let d = try await APIClient.shared.uploadDeliverable(id, fileURL: fileURL)
        var x = extras
        if let i = x.deliverables.firstIndex(where: { $0.id == d.id }) { x.deliverables[i] = d }
        onChange(x)
    }
}

private struct ChipStyle: ViewModifier {
    let fill: Color
    let stroke: Color?
    let fg: Color
    var dashed = false

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(fill, in: Capsule())
            .overlay {
                if let stroke {
                    Capsule().strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
                }
            }
    }
}

// MARK: - Technischer Check

struct QCBadge: View {
    let qc: VideoQC
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        let (text, bg): (String, Color) = {
            switch qc.status {
            case "done":
                return qc.failed == 0 ? ("✓ " + language.t("qc.badgeOk"), .green.opacity(0.85)) : ("⚠ " + language.t("qc.badgeFail").replacingOccurrences(of: "{n}", with: "\(qc.failed)"), .orange.opacity(0.9))
            case "error":
                return ("⚠ " + language.t("qc.badgeFail").replacingOccurrences(of: "{n}", with: "!"), .orange.opacity(0.9))
            default:
                return (language.t("qc.badgePending"), .black.opacity(0.5))
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
    }
}

struct QCSheet: View {
    let title: String
    let qc: VideoQC?
    let versionId: String?
    var onRerun: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguage.shared
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                if let qc, qc.status == "done" {
                    Section {
                        ForEach(qc.checks) { c in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(c.ok ? Color.green : Color.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.label).font(.subheadline.weight(.medium))
                                    Text(c.value).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } footer: {
                        Text(language.t("qc.internalHint"))
                    }
                } else if let qc, qc.status == "error" {
                    Section { Text(qc.error ?? language.t("planning.failed")).foregroundStyle(.secondary) }
                } else {
                    Section { Label(language.t("qc.pending"), systemImage: "hourglass").foregroundStyle(.secondary) }
                }
                if versionId != nil {
                    Section {
                        Button {
                            busy = true
                            Task { await onRerun(); busy = false }
                        } label: {
                            HStack { Text(language.t("qc.rerun")); if busy { Spacer(); ProgressView() } }
                        }
                        .disabled(busy)
                    }
                }
            }
            .navigationTitle(language.t("qc.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.t("places.done")) { dismiss() } } }
        }
    }
}

// MARK: - Feedback-Runden

struct RoundsBadge: View {
    let rounds: FeedbackRounds.VideoRounds
    let canEdit: Bool
    let onSetLimit: (Int?) -> Void
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        let over = rounds.limit.map { rounds.used > $0 } ?? false
        let atLimit = rounds.limit.map { rounds.used == $0 } ?? false
        let text = language.t("rounds.badge").replacingOccurrences(of: "{used}", with: "\(rounds.used)") + (rounds.limit.map { "/\($0)" } ?? "")
        let label = Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(over ? Color.red.opacity(0.9) : atLimit ? Color.orange.opacity(0.9) : Color.black.opacity(0.5), in: Capsule())
        if canEdit {
            Menu {
                Section(language.t("rounds.limitTitle")) {
                    ForEach(1...6, id: \.self) { n in
                        Button {
                            onSetLimit(n)
                        } label: {
                            if rounds.ownLimit == n { Label("\(n)", systemImage: "checkmark") } else { Text("\(n)") }
                        }
                    }
                    Button(language.t("rounds.projectDefault")) { onSetLimit(nil) }
                }
            } label: { label }
        } else {
            label
        }
    }
}
