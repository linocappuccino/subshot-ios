import SwiftUI

extension Color {
    /// Parses "#RRGGBB" or "RRGGBB" hex strings (the format scenes store their
    /// color as, per the backend schema). Falls back to gray on malformed input
    /// rather than crashing — a scene with a bad color shouldn't take the
    /// whole list down.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { $0 == "#" }
        guard s.count == 6, let value = UInt64(s, radix: 16) else {
            self = .gray
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Palette check-validated pastel set (see dataviz skill notes on this
    /// project) — used for both scene color swatches and the deterministic
    /// per-project circle color below, so the whole app draws from one set.
    static let subshotPalette = ["#3875bd", "#0f7e55", "#4e4295", "#d1504f", "#b9507b", "#a64c22"]

    /// Projects have no color field on the backend (no schema migration for
    /// that yet) — deriving a stable color from the id hash gives every
    /// project a consistent, distinct-ish circle color across app launches
    /// without needing new backend state.
    static func stable(for id: String) -> Color {
        let hash = id.unicodeScalars.reduce(into: 0) { $0 = $0 &* 31 &+ Int($1.value) }
        let hex = subshotPalette[abs(hash) % subshotPalette.count]
        return Color(hex: hex)
    }
}
