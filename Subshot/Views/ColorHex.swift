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
    /// project) — used for both scene AND project color swatches, so the
    /// whole app draws from one set.
    static let subshotPalette = ["#3875bd", "#0f7e55", "#4e4295", "#d1504f", "#b9507b", "#a64c22"]

    /// Linear RGB blend toward `other`, `fraction` clamped to 0...1 — used
    /// for the scene deadline countdown color (grey→yellow→red), which fades
    /// continuously rather than snapping between three fixed colors.
    func interpolated(to other: Color, fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        #if canImport(UIKit)
        let from = UIColor(self)
        let to = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: r1 + (r2 - r1) * f,
            green: g1 + (g2 - g1) * f,
            blue: b1 + (b2 - b1) * f,
            opacity: a1 + (a2 - a1) * f
        )
        #else
        return f < 0.5 ? self : other
        #endif
    }
}
