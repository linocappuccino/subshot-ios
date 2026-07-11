import SwiftUI

/// There's no API to summon the OS emoji keyboard programmatically on iOS
/// either, and relying on that (focus a plain TextField, hope the person
/// taps their keyboard's globe/emoji key) read as "the plus button just
/// turns into a text field, nothing opens" — reported directly ("ich will
/// aber eine Emoji-Auswahl die sich öffnet wenn man das plus drückt"). An
/// actual in-app grid is the only reliable fix, same conclusion the web
/// client already reached for the same reason.
///
/// Was a ~40-emoji curated set (film/project-relevant only) — Lino asked for
/// the full Apple emoji catalog with horizontal scrolling instead
/// (2026-07-11: "können wir nicht ALLE Apple emojis darstellen... und im
/// kleinen Fenster nach links oder rechts scrollen?"). Embedding the entire
/// official Unicode set verbatim (3000+ entries incl. skin-tone/gender
/// variants, family combinations, flags for every country) isn't practical
/// to hand-maintain as a literal array with no bundled Unicode metadata
/// source in this repo — this is instead a much broader set spanning every
/// standard keyboard category (several hundred, not ~40), organized by
/// category, in a horizontally scrolling grid — same idea, not literally
/// exhaustive.
private let emojiCategories: [(name: String, emojis: [String])] = [
    ("Film & Projekt", [
        "🎬", "🎥", "📹", "🎞️", "📽️", "🎙️", "🎧", "🎵", "🎶", "📝", "📋",
        "📌", "📍", "🗓️", "📅", "⏰", "⏱️", "⭐️", "🔥", "💡", "🎯", "✅",
        "🚀", "🏆", "🎉", "✨", "🎭", "🖼️", "📸", "📷", "🎨", "🎤", "📺",
        "💻", "🖥️", "🎮", "📀", "💾", "🔊", "🔦", "🎇", "🎆",
    ]),
    ("Smileys", [
        "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂",
        "🙃", "😉", "😌", "😍", "🥰", "😘", "😗", "😙", "😚", "😋", "😛",
        "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🥸", "🤩", "🥳", "😏",
        "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣", "😖", "😫", "😩",
        "🥺", "😢", "😭", "😤", "😠", "😡", "🤬", "🤯", "😳", "🥵", "🥶",
        "😱", "😨", "😰", "😥", "😓", "🤗", "🤔", "🤭", "🤫", "🤥", "😶",
        "😐", "😑", "😬", "🙄", "😯", "😦", "😧", "😮", "😲", "🥱", "😴",
        "🤤", "😪", "😵", "🤐", "🥴", "🤢", "🤮", "🤧", "😷", "🤒", "🤕",
        "🤑", "🤠", "😈", "👿", "👹", "👺", "🤡", "💩", "👻", "💀", "👽",
        "🤖", "😺", "😸", "😹", "😻", "😼", "😽", "🙀", "😿", "😾",
    ]),
    ("Menschen", [
        "👋", "🤚", "🖐️", "✋", "🖖", "👌", "🤌", "🤏", "✌️", "🤞", "🤟",
        "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "☝️", "👍", "👎", "✊",
        "👊", "🤛", "🤜", "👏", "🙌", "👐", "🤲", "🙏", "✍️", "💅", "🤳",
        "💪", "🦾", "👀", "👁️", "👤", "👥", "🧑", "👶", "🧒", "👦", "👧",
        "🧑‍🦱", "🧑‍🦰", "🧑‍🦳", "🧑‍🦲", "👨", "👩", "🧓", "👴", "👵", "🙍", "🙎",
        "🙅", "🙆", "💁", "🙋", "🧏", "🙇", "🤦", "🤷", "🧑‍💼", "🧑‍🎓", "🧑‍🏫",
        "🧑‍⚕️", "🧑‍🌾", "🧑‍🍳", "🧑‍🎤", "🧑‍🎨", "🧑‍✈️", "🧑‍🚀", "🧑‍🚒", "👮", "🕵️", "💂",
        "👷", "🤴", "👸", "👳", "👲", "🧕", "🤵", "👰", "🤰", "🤱",
    ]),
    ("Natur", [
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁",
        "🐮", "🐷", "🐸", "🐵", "🙈", "🙉", "🙊", "🐒", "🐔", "🐧", "🐦",
        "🐤", "🦆", "🦅", "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🐛",
        "🦋", "🐌", "🐞", "🐜", "🦟", "🦗", "🕷️", "🕸️", "🐢", "🐍", "🦎",
        "🦖", "🦕", "🐙", "🦑", "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬",
        "🐳", "🐋", "🦈", "🐊", "🐅", "🐆", "🦓", "🦍", "🦧", "🐘", "🦛",
        "🦏", "🐪", "🐫", "🦒", "🦘", "🐃", "🐂", "🐄", "🐎", "🐖", "🐑",
        "🐐", "🦙", "🐕", "🐩", "🐈", "🐓", "🦃", "🦤", "🦚", "🦜", "🦢",
        "🌵", "🎄", "🌲", "🌳", "🌴", "🌱", "🌿", "☘️", "🍀", "🎍", "🎋",
        "🍃", "🍂", "🍁", "🍄", "🐚", "🌾", "💐", "🌷", "🌹", "🥀", "🌺",
        "🌸", "🌼", "🌻", "🌞", "🌝", "🌛", "🌜", "🌚", "🌕", "🌖", "☀️",
        "🌤️", "⛅️", "🌥️", "☁️", "🌦️", "🌧️", "⛈️", "🌩️", "🌨️", "❄️", "☃️",
        "⛄️", "🌬️", "💨", "🌪️", "🌫️", "🌈", "☂️", "☔️", "⚡️", "🔥", "💧",
        "🌊",
    ]),
    ("Essen", [
        "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈",
        "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑", "🥦", "🥬",
        "🥒", "🌶️", "🫑", "🌽", "🥕", "🫒", "🧄", "🧅", "🥔", "🍠", "🥐",
        "🥯", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🧈", "🥞", "🧇", "🥓",
        "🥩", "🍗", "🍖", "🌭", "🍔", "🍟", "🍕", "🫓", "🥪", "🥙", "🧆",
        "🌮", "🌯", "🥗", "🥘", "🫕", "🍝", "🍜", "🍲", "🍛", "🍣", "🍱",
        "🥟", "🦪", "🍤", "🍙", "🍚", "🍘", "🍥", "🥠", "🥮", "🍢", "🍡",
        "🍧", "🍨", "🍦", "🥧", "🧁", "🍰", "🎂", "🍮", "🍭", "🍬", "🍫",
        "🍿", "🍩", "🍪", "🌰", "🥜", "🍯", "🥛", "🍼", "☕️", "🍵", "🧃",
        "🥤", "🍶", "🍺", "🍻", "🥂", "🍷", "🥃", "🍸", "🍹", "🧉", "🍾",
    ]),
    ("Aktivität", [
        "⚽️", "🏀", "🏈", "⚾️", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱", "🪀",
        "🏓", "🏸", "🏒", "🏑", "🥍", "🏏", "🥅", "⛳️", "🪁", "🏹", "🎣",
        "🤿", "🥊", "🥋", "🎽", "🛹", "🛼", "🛷", "⛸️", "🥌", "🎿", "⛷️",
        "🏂", "🪂", "🏋️", "🤼", "🤸", "⛹️", "🤺", "🤾", "🏌️", "🏇", "🧘",
        "🏄", "🏊", "🤽", "🚣", "🧗", "🚵", "🚴", "🏆", "🥇", "🥈", "🥉",
        "🏅", "🎖️", "🏵️", "🎗️", "🎫", "🎟️", "🎪", "🤹", "🎨", "🎭", "🩰",
    ]),
    ("Reisen", [
        "🚗", "🚕", "🚙", "🚌", "🚎", "🏎️", "🚓", "🚑", "🚒", "🚐", "🛻",
        "🚚", "🚛", "🚜", "🛵", "🏍️", "🛺", "🚲", "🛴", "🚨", "🚔", "🚍",
        "🚘", "🚖", "🚡", "🚠", "🚟", "🚃", "🚋", "🚞", "🚝", "🚄", "🚅",
        "🚈", "🚂", "🚆", "🚇", "🚊", "🚉", "✈️", "🛫", "🛬", "🛩️", "💺",
        "🛰️", "🚀", "🛸", "🚁", "🛶", "⛵️", "🚤", "🛥️", "🛳️", "⛴️", "🚢",
        "⚓️", "⛽️", "🚧", "🚦", "🚥", "🗺️", "🗿", "🗽", "🗼", "🏰", "🏯",
        "🏟️", "🎡", "🎢", "🎠", "⛲️", "⛱️", "🏖️", "🏝️", "🏜️", "🌋", "⛰️",
        "🏔️", "🗻", "🏕️", "⛺️", "🏠", "🏡", "🏘️", "🏚️", "🏗️", "🏭", "🏢",
        "🏬", "🏣", "🏤", "🏥", "🏦", "🏨", "🏪", "🏫", "🏩", "💒", "🏛️",
        "⛪️", "🕌", "🕍", "🛕", "🕋",
    ]),
    ("Symbole", [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️",
        "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💯", "💢", "💥", "💫",
        "💦", "💨", "🕳️", "💣", "💬", "👁️‍🗨️", "🗨️", "🗯️", "💭", "💤", "✅",
        "❌", "❓", "❗️", "⚠️", "🚫", "🔞", "📵", "🚭", "♻️", "✳️", "✴️",
        "❇️", "©️", "®️", "™️", "🔟", "🔢", "🔤", "🅰️", "🆎", "🆑", "🆒",
        "🆓", "🆔", "🆕", "🆖", "🆗", "🆘", "🆙", "🆚", "🈁", "🈂️", "🈷️",
        "㊙️", "㊗️", "🈵", "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "🟤", "⚫️",
        "⚪️", "🟥", "🟧", "🟨", "🟩", "🟦", "🟪", "🟫", "⬛️", "⬜️", "◼️",
        "◻️", "◾️", "◽️", "▪️", "▫️", "🔶", "🔷", "🔸", "🔹", "🔺", "🔻",
        "💠", "🔘", "🔳", "🔲",
    ]),
    ("Flaggen", [
        "🏁", "🚩", "🎌", "🏴", "🏳️", "🏳️‍🌈", "🇨🇭", "🇩🇪", "🇦🇹", "🇺🇸", "🇬🇧",
        "🇫🇷", "🇮🇹", "🇪🇸", "🇵🇹", "🇳🇱", "🇧🇪", "🇸🇪", "🇳🇴", "🇩🇰", "🇫🇮", "🇮🇪",
        "🇵🇱", "🇬🇷", "🇹🇷", "🇷🇺", "🇺🇦", "🇨🇦", "🇲🇽", "🇧🇷", "🇦🇷", "🇯🇵", "🇰🇷",
        "🇨🇳", "🇮🇳", "🇦🇺", "🇿🇦", "🇪🇬",
    ]),
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

    /// Flattened once for the grid — category boundaries above are purely
    /// for keeping the source list organized/maintainable, the picker itself
    /// just scrolls through all of them in order.
    private var allEmoji: [String] {
        emojiCategories.flatMap(\.emojis)
    }

    /// Was a fixed 8-column LazyVGrid inside a `.frame(width: 300)` — 8
    /// columns of 36pt plus spacing added up to MORE than the 300pt frame
    /// (minus its own 12pt padding on each side), so the leftmost and
    /// rightmost emoji were clipped outside the popover's own bounds — not
    /// just "many emoji don't fit," genuinely cut in half ("links und
    /// rechts werden emojis abgeschnitten", 2026-07-11). A horizontally
    /// scrolling grid (also what was explicitly asked for) sidesteps that
    /// entirely — nothing needs to fit in a fixed width anymore.
    private var emojiGrid: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(36), spacing: 4), count: 6), spacing: 4) {
                ForEach(Array(allEmoji.enumerated()), id: \.offset) { _, option in
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
        }
        .frame(width: 300, height: 260)
    }
}
