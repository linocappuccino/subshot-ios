import SwiftUI

/// There's no API to summon the OS emoji keyboard programmatically on iOS
/// either, and relying on that (focus a plain TextField, hope the person
/// taps their keyboard's globe/emoji key) read as "the plus button just
/// turns into a text field, nothing opens" — reported directly ("ich will
/// aber eine Emoji-Auswahl die sich öffnet wenn man das plus drückt"). An
/// actual in-app grid is the only reliable fix, same conclusion the web
/// client already reached for the same reason.
///
/// 2026-07-21 (#275): rebuilt to load the same `emojibase-data` German
/// dataset the web app's EmojiField.tsx uses (see its own doc comment for
/// the "Zahn"/🦷 story — English-only names silently failed real searches),
/// generated once by the web repo's `scripts/generate-emoji-data.mjs` and
/// copied here as `Resources/emojiData.json` (1914 entries, real German
/// names + keyword tags, same exclusions: no component/skin-tone swatches,
/// no bare regional-indicator letters). Regenerate by re-running that script
/// and copying the output over whenever the emoji set should refresh — no
/// separate iOS generator, single source of truth.
///
/// IMPORTANT for whoever opens this in Xcode next: `Resources/emojiData.json`
/// is a new file (git status shows it untracked) and was never added to a
/// build target from this machine (no compiler here, no .xcodeproj in this
/// repo either) — make sure it's included in the app target's "Copy Bundle
/// Resources" build phase, or `Bundle.main.url(forResource:withExtension:)`
/// below returns nil and the picker silently shows zero emoji.
private struct EmojiEntry: Identifiable {
    let emoji: String
    let name: String
    let tags: [String]
    var id: String { emoji }
}

private struct RawEmojiEntry: Decodable {
    let emoji: String
    let name: String
    let tags: [String]
    let group: Int
}

private let groupLabels: [Int: String] = [
    0: "Smileys & Emotionen", 1: "Menschen", 3: "Natur", 4: "Essen & Trinken",
    5: "Reisen", 6: "Aktivität", 7: "Objekte", 8: "Symbole", 9: "Flaggen",
]
private let groupOrder = [0, 1, 3, 4, 5, 6, 7, 8, 9]

/// Lino's actual most-used picks for this app — kept pinned as its own
/// first category, same as before and same as the web app's redesign.
private let filmProjektEmojis = [
    "🎬", "🎥", "📹", "🎞️", "📽️", "🎙️", "🎧", "🎵", "🎶", "📝", "📋",
    "📌", "📍", "🗓️", "📅", "⏰", "⏱️", "⭐️", "🔥", "💡", "🎯", "✅",
    "🚀", "🏆", "🎉", "✨", "🎭", "🖼️", "📸", "📷", "🎨", "🎤", "📺",
    "💻", "🖥️", "🎮", "📀", "💾", "🔊", "🔦", "🎇", "🎆",
]

private let rawEmoji: [RawEmojiEntry] = {
    guard let url = Bundle.main.url(forResource: "emojiData", withExtension: "json"),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode([RawEmojiEntry].self, from: data)
    else { return [] }
    return decoded
}()

private let allEmoji: [EmojiEntry] = rawEmoji.map { EmojiEntry(emoji: $0.emoji, name: $0.name, tags: $0.tags) }
private let byChar: [String: EmojiEntry] = Dictionary(uniqueKeysWithValues: allEmoji.map { ($0.emoji, $0) })

private let emojiCategories: [(name: String, emojis: [EmojiEntry])] = {
    var categories: [(name: String, emojis: [EmojiEntry])] = [
        ("Film & Projekt", filmProjektEmojis.map { byChar[$0] ?? EmojiEntry(emoji: $0, name: $0, tags: []) }),
    ]
    for group in groupOrder {
        let emojis = rawEmoji.filter { $0.group == group }.map { EmojiEntry(emoji: $0.emoji, name: $0.name, tags: $0.tags) }
        categories.append((groupLabels[group] ?? "", emojis))
    }
    return categories
}()

/// Round "+" tile that becomes the emoji itself once one's set, with a small
/// "x" badge to clear it again — mirrors the web app's EmojiField.tsx.
struct EmojiPickerField: View {
    @Binding var emoji: String
    @State private var showingPicker = false
    @State private var query = ""
    private let size: CGFloat = 48

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                showingPicker = true
            } label: {
                Group {
                    if emoji.isEmpty {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(emoji)
                            .font(.system(size: 24))
                    }
                }
                .frame(width: size, height: size)
                .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
                .overlay {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: emoji.isEmpty ? [4, 3] : []))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPicker) {
                emojiPopover
                    .presentationCompactAdaptation(.popover)
                    .onDisappear { query = "" }
            }

            if !emoji.isEmpty {
                Button {
                    emoji = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(.systemGray2))
                }
                .offset(x: 6, y: -6)
            }
        }
        .frame(width: size + 6, height: size + 6, alignment: .topTrailing)
    }

    private var searchResults: [EmojiEntry]? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return allEmoji.filter { $0.name.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) } }
    }

    /// 2026-07-21 (#275), rebuilt from a horizontally scrolling flat strip
    /// to a vertically scrolling grid grouped by category, with a search
    /// field on top — same shape as the web app's EmojiField.tsx redesign
    /// (#250/#252). The old strip was also the actual "oben/unten zu wenig
    /// Platz" complaint: a fixed 260pt-tall `.frame` around 6 fixed 36pt
    /// rows left almost no breathing room top/bottom; this layout isn't
    /// height-starved the same way since it scrolls vertically instead.
    private var emojiPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Suchen…", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            ScrollView(.vertical, showsIndicators: true) {
                if let results = searchResults {
                    if results.isEmpty {
                        Text("Keine Treffer")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        emojiGrid(results)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(emojiCategories, id: \.name) { category in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.name.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                emojiGrid(category.emojis)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300, height: 340)
    }

    private func emojiGrid(_ entries: [EmojiEntry]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 2), count: 8), spacing: 2) {
            ForEach(entries) { entry in
                Button {
                    emoji = entry.emoji
                    showingPicker = false
                } label: {
                    Text(entry.emoji)
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
