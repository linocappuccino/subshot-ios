import SwiftUI

/// Curated set, film/project-relevant first — same list as the web client's
/// EmojiField.tsx (client parity). There's no API to summon the OS emoji
/// keyboard programmatically on iOS either, and relying on that (focus a
/// plain TextField, hope the person taps their keyboard's globe/emoji key)
/// read as "the plus button just turns into a text field, nothing opens" —
/// reported directly ("ich will aber eine Emoji-Auswahl die sich öffnet
/// wenn man das plus drückt"). An actual in-app grid is the only reliable
/// fix, same conclusion the web client already reached for the same reason.
private let emojiOptions = [
    "🎬", "🎥", "📹", "🎞️", "📽️", "🎙️", "🎧", "🎵",
    "📝", "📋", "📌", "📍", "🗓️", "⏰", "⭐️", "🔥",
    "💡", "🎯", "✅", "🚀", "🏆", "🎉", "✨", "🎭",
    "🖼️", "📸", "🌆", "🏙️", "🚗", "✈️", "🏠", "🏢",
    "🌲", "🌊", "☀️", "🌙", "❤️", "😀", "😎", "🔥",
]

/// Round "+" tile that becomes the emoji itself once one's set, with a small
/// "x" badge to clear it again — mirrors the web app's EmojiField.tsx.
struct EmojiPickerField: View {
    @Binding var emoji: String
    @State private var showingPicker = false
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
                emojiGrid
                    .presentationCompactAdaptation(.popover)
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

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 8), spacing: 2) {
            ForEach(Array(emojiOptions.enumerated()), id: \.offset) { _, option in
                Button {
                    emoji = option
                    showingPicker = false
                } label: {
                    Text(option)
                        .font(.system(size: 20))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
