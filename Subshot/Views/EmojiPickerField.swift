import SwiftUI

/// Round "+" tile that becomes the emoji itself once one's set, with a small
/// "x" badge to clear it again — mirrors the web app's EmojiField.tsx for
/// cross-client consistency (see project memory on client parity). The
/// actual input surface underneath is still a plain TextField (invisible
/// border, just the emoji rendered large) since there's no API to summon the
/// OS emoji keyboard programmatically — tapping the tile focuses it, which
/// brings up the keyboard, and the emoji key/globe key on it works as usual.
struct EmojiPickerField: View {
    @Binding var emoji: String
    @FocusState private var isFocused: Bool
    private let size: CGFloat = 48

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TextField("", text: $emoji)
                .focused($isFocused)
                .multilineTextAlignment(.center)
                .font(.system(size: 24))
                .frame(width: size, height: size)
                .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
                .overlay {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: emoji.isEmpty ? [4, 3] : []))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
                .overlay {
                    if emoji.isEmpty {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                // A single emoji is one (extended) grapheme cluster —
                // trimming to the first one keeps this a one-emoji field
                // even if someone pastes a run of them.
                .onChange(of: emoji) { _, newValue in
                    if let first = newValue.first {
                        emoji = String(first)
                    }
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
}
