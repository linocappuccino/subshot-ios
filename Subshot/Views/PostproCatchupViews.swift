import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import PhotosUI

// 2026-11-17 (b113) — Post-production pieces ported from the web (PostproLanguages.tsx and the
// selection bar of postproduction/page.tsx). Counters always come from PostproFilter.facetCounts.

/// one capsule chip (web: pill) — white when active, greyed and not tappable with 0
struct PPChip<Label: View>: View {
    let active: Bool
    var zero: Bool = false
    var compact: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.medium))
                .padding(.horizontal, compact ? 11 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .foregroundStyle(active ? Color.black : (zero ? Color.white.opacity(0.25) : Color.white.opacity(0.8)))
                .background(Capsule().fill(active ? Color.white : Color.white.opacity(zero ? 0.03 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(zero)
    }
}

struct PPCount: View {
    let n: Int
    let active: Bool
    var body: some View {
        Text("\(n)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(active ? Color.black.opacity(0.1) : Color.white.opacity(0.1)))
            .foregroundStyle(active ? Color.black.opacity(0.7) : Color.white.opacity(0.6))
    }
}

/// «Alle» / one tab per project language (flag + name + count) / «Nicht zugeordnet» / «+ Sprache».
/// Editors can long-press a language tab to change or delete it.
struct LanguageTabsRow: View {
    @ObservedObject private var language = AppLanguage.shared
    let overview: PostproLanguagesOverview
    let counts: [String: Int]
    @Binding var tab: String
    let editable: Bool
    let onCreate: (String, String) -> Void
    let onRename: (String, String, String) -> Void
    let onDelete: (PostproLanguagesOverview.Language) -> Void

    private var addable: [PostproLanguageCatalog.Entry] {
        PostproLanguageCatalog.list.filter { c in !overview.languages.contains(where: { $0.name == c.name }) }
    }

    var body: some View {
        if editable || !overview.languages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PPChip(active: tab == "all", action: { tab = "all" }) {
                        Text(language.t("pp.all"))
                        PPCount(n: counts["all"] ?? 0, active: tab == "all")
                    }
                    .accessibilityIdentifier("pp.langTab.all")
                    ForEach(overview.languages) { l in
                        PPChip(active: tab == l.id, action: { tab = l.id }) {
                            Text(l.flag)
                            Text(l.name)
                            PPCount(n: counts[l.id] ?? 0, active: tab == l.id)
                        }
                        .accessibilityIdentifier("pp.langTab.\(l.name)")
                        .contextMenu {
                            if editable {
                                Menu(language.t("pp.changeLanguageTo")) {
                                    ForEach(addable, id: \.code) { c in
                                        Button("\(c.flag) \(c.name)") { onRename(l.id, c.name, c.flag) }
                                    }
                                }
                                Button(role: .destructive) { onDelete(l) } label: {
                                    Label(language.t("pp.deleteLanguage"), systemImage: "trash")
                                }
                            }
                        }
                    }
                    if !overview.languages.isEmpty {
                        PPChip(active: tab == "none", action: { tab = "none" }) {
                            Text(language.t("pp.unassigned"))
                            PPCount(n: counts["none"] ?? 0, active: tab == "none")
                        }
                        .accessibilityIdentifier("pp.langTab.none")
                    }
                    if editable {
                        Menu {
                            ForEach(addable, id: \.code) { c in
                                Button("\(c.flag) \(c.name)") { onCreate(c.name, c.flag) }
                            }
                        } label: {
                            Text(language.t("pp.addLanguage"))
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.white.opacity(0.25)))
                        }
                        .accessibilityIdentifier("pp.addLanguage")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// second / third filter row (format, platform) — every key of the project stays visible,
/// greyed with 0 when the other filters exclude it (web: FormatTabs / PlatformTabs)
struct FacetChipsRow: View {
    @ObservedObject private var language = AppLanguage.shared
    let title: String
    let present: [String]
    let counts: [String: Int]
    @Binding var tab: String
    let idPrefix: String
    let label: (String) -> AnyView

    private var keys: [String] { present.contains(tab) || tab == "all" ? present : present + [tab] }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.4)).padding(.trailing, 2)
                PPChip(active: tab == "all", compact: true, action: { tab = "all" }) {
                    Text(language.t("pp.all"))
                    Text("\(counts["all"] ?? 0)").monospacedDigit().opacity(0.5)
                }
                .accessibilityIdentifier("\(idPrefix).all")
                ForEach(keys, id: \.self) { k in
                    let zero = (counts[k] ?? 0) == 0 && tab != k
                    PPChip(active: tab == k, zero: zero, compact: true, action: { tab = k }) {
                        label(k)
                        Text("\(counts[k] ?? 0)").monospacedDigit().opacity(0.5)
                    }
                    .accessibilityIdentifier("\(idPrefix).\(k)")
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// a tiny frame in the format's shape (web: FormatIcon)
struct FormatShapeIcon: View {
    let format: String
    private var size: CGSize {
        switch format {
        case "9:16": return CGSize(width: 7, height: 12)
        case "16:9": return CGSize(width: 13, height: 7.5)
        case "1:1": return CGSize(width: 10, height: 10)
        case "4:5": return CGSize(width: 8.5, height: 10.5)
        case "5:4": return CGSize(width: 10.5, height: 8.5)
        default: return CGSize(width: 12, height: 6)
        }
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(lineWidth: 1.5)
            .frame(width: size.width, height: size.height)
            .opacity(0.7)
    }
}

/// «🇩🇪 DE» on the thumbnail; editors get a menu (✓ current, «Keine Sprache», «Neue Sprache»)
struct LanguageBadgeView: View {
    @ObservedObject private var language = AppLanguage.shared
    let current: PostproLanguagesOverview.Language?
    let languages: [PostproLanguagesOverview.Language]
    let onChange: ((String?) -> Void)?
    let onNew: (() -> Void)?

    private var badge: some View {
        Group {
            if let current {
                HStack(spacing: 3) {
                    Text(current.flag).font(.system(size: 12))
                    Text(PostproLanguageCatalog.code(current.name))
                }
            } else {
                Text(language.t("pp.languageBadgeAdd"))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(current == nil ? 0.8 : 1))
        .frame(height: 20)
        .padding(.horizontal, 8)
        .background(Capsule().fill(.black.opacity(current == nil ? 0.5 : 0.6)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }

    var body: some View {
        if let onChange {
            Menu {
                ForEach(languages) { l in
                    Button { onChange(l.id) } label: {
                        if current?.id == l.id { Label("\(l.flag) \(l.name)", systemImage: "checkmark") } else { Text("\(l.flag) \(l.name)") }
                    }
                }
                Button { onChange(nil) } label: {
                    if current == nil { Label(language.t("pp.noLanguage"), systemImage: "checkmark") } else { Text(language.t("pp.noLanguage")) }
                }
                if let onNew {
                    Divider()
                    Button { onNew() } label: { Label(language.t("pp.newLanguage"), systemImage: "plus") }
                }
            } label: {
                badge.frame(minHeight: 32).contentShape(Rectangle())
            }
            .accessibilityIdentifier("pp.languageBadge")
        } else if current != nil {
            badge
        }
    }
}

/// format («9:16») or resolution («1080 × 1920») badge, same height as the language badge
struct SmallInfoBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.9))
            .frame(height: 20)
            .padding(.horizontal, 8)
            .background(Capsule().fill(.black.opacity(0.6)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }
}

/// «Plattform ▾» of the selection bar: Hinzufügen / Ersetzen, the four icons, «Kein Icon», «Übernehmen»
struct BulkPlatformSheet: View {
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    let onApply: ([String], String) -> Void
    @State private var selected: [String] = []
    @State private var mode = "add"

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $mode) {
                    Text(language.t("pp.platformAdd")).tag("add")
                    Text(language.t("pp.platformReplace")).tag("replace")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                Section {
                    ForEach(VideoPlatform.allCases) { p in
                        Button {
                            if let i = selected.firstIndex(of: p.rawValue) { selected.remove(at: i) } else { selected.append(p.rawValue) }
                        } label: {
                            HStack {
                                Image(p.imageName).resizable().scaledToFit().frame(width: 22, height: 22)
                                Text(p.name).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(p.rawValue) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }
                Section {
                    Button(language.t("pp.platformNoIcon"), role: .destructive) {
                        onApply([], "replace")
                        dismiss()
                    }
                }
            }
            .navigationTitle(language.t("pp.platform"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.t("pp.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("pp.apply")) {
                        onApply(PostproFilter.platformKeys.filter { selected.contains($0) }, mode)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// one line of the multi-upload list (web: data-upload-item)
struct PPUploadItem: Identifiable, Equatable {
    enum Phase: Equatable { case wait, up, done, error(String) }
    let id: String
    var name: String
    var progress: Double = 0
    var state: Phase = .wait
}

struct UploadQueueView: View {
    @ObservedObject private var language = AppLanguage.shared
    let items: [PPUploadItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { u in
                HStack(spacing: 10) {
                    Text(u.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                    switch u.state {
                    case .error(let msg):
                        Text("✕ \(msg)").font(.caption).foregroundStyle(.red.opacity(0.85)).lineLimit(2)
                        Spacer(minLength: 0)
                    default:
                        ProgressView(value: u.progress)
                            .tint(u.state == .done ? .green : .blue)
                            .frame(maxWidth: 220)
                        Text(u.state == .done ? language.t("pp.uploadDone") : u.state == .wait ? language.t("pp.uploadWait") : "\(Int((u.progress * 100).rounded())) %")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityIdentifier("pp.uploadItem")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.white.opacity(0.15)))
        .padding(.horizontal, 16)
    }
}

/// A picked movie that keeps its original file name (title of the new video), copied into its own
/// temp folder so equal names never collide.
struct NamedMovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try NamedMovieFile(copying: received.file)
        }
    }

    nonisolated init(url: URL) { self.url = url }

    /// copy into a fresh temp folder (also used for Files-app URLs, which are security scoped)
    nonisolated init(copying source: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pp-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: dest)
        url = dest
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    var title: String {
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? url.lastPathComponent : base
    }

    var isVideo: Bool {
        ["mp4", "m4v", "mov", "webm"].contains(url.pathExtension.lowercased())
            || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false)
    }

    var contentType: String {
        switch url.pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        default: return "video/mp4"
        }
    }
}

/// «Neue Sprache» (from a tile's badge or the selection bar): pick from the list, the flag comes with it
struct LanguageCatalogSheet: View {
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    let existing: [String]
    let onPick: (String, String) -> Void

    var body: some View {
        NavigationStack {
            List(PostproLanguageCatalog.list.filter { !existing.contains($0.name) }, id: \.code) { c in
                Button {
                    onPick(c.name, c.flag)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text(c.flag)
                        Text(c.name).foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(language.t("pp.chooseLanguage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.t("pp.cancel")) { dismiss() } }
            }
        }
    }
}

/// shared reference for the 3 upload workers (all on the main actor)
final class PPUploadQueue {
    private var items: [(id: String, source: PPUploadSource)]
    private var index = 0
    init(_ items: [(id: String, source: PPUploadSource)]) { self.items = items }
    func next() -> (id: String, source: PPUploadSource)? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

enum PPUploadSource {
    case photo(PhotosPickerItem)
    case file(URL)
}
