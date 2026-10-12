import SwiftUI

// 2026-10-12 — small shared pieces for the shot-list "am Set" features (web parity):
// PlacePill (📍 place in its own colour, full address → Google Maps, separate chevron to change),
// ProgressRingView (Apple-Activity-style ring), ShotlistProgressView (ring + "7/12 im Kasten" + bar).

/// 📍 + the place, tinted in the place's colour. Tapping the address opens Google Maps; the
/// optional `menu` is a separate chevron at the end (pick another place).
struct PlacePill<MenuContent: View>: View {
    let address: String?
    let color: Color?
    var emptyLabel: String = ""
    /// the scene follows the shotlist's default place (no own place)
    var muted: Bool = false
    var full: Bool = true
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        let tint = (address != nil ? color : nil) ?? Color.secondary
        HStack(spacing: 6) {
            if let address, let url = ShotlistPlace.mapsURL(address) {
                Link(destination: url) { label(address, tint: tint) }
                    .buttonStyle(.plain)
            } else {
                label(nil, tint: tint)
            }
            if MenuContent.self != EmptyView.self {
                Divider().frame(height: 14)
                Menu { menu() } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, MenuContent.self != EmptyView.self ? 5 : 10)
        .padding(.vertical, 4)
        .background(tint.opacity(address != nil ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(address != nil ? 0.35 : 0.0), lineWidth: 1))
    }

    private func label(_ address: String?, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "mappin.circle.fill")
                .font(.caption)
                .foregroundStyle(tint)
            Text(address.map { full ? $0 : ShotlistPlace.short($0) } ?? emptyLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(address != nil ? Color.primary : Color.secondary)
                .opacity(muted ? 0.75 : 1)
                .multilineTextAlignment(.leading)
                .lineLimit(full ? 3 : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension PlacePill where MenuContent == EmptyView {
    init(address: String?, color: Color?, emptyLabel: String = "", muted: Bool = false, full: Bool = true) {
        self.init(address: address, color: color, emptyLabel: emptyLabel, muted: muted, full: full, menu: { EmptyView() })
    }
}

/// Apple-Activity-style ring: grey track + green arc for the done share, a green disc with a tick
/// once everything is done.
struct ProgressRingView: View {
    let ratio: Double
    let done: Bool
    var size: CGFloat = 18

    static let green = Color(hex: "#30d158")

    var body: some View {
        ZStack {
            if done {
                Circle().fill(Self.green)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.black)
            } else {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: size * 0.125)
                Circle()
                    .trim(from: 0, to: max(0, min(1, ratio)))
                    .stroke(Self.green, style: StrokeStyle(lineWidth: size * 0.125, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: ratio)
            }
        }
        .frame(width: size, height: size)
    }
}

/// per shotlist on the overview cards: ring + "7/12 Szenen im Kasten" + a thin bar
struct ShotlistProgressView: View {
    let done: Int
    let total: Int
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        if total == 0 {
            Text(language.t("shotlistProgress.empty"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let ratio = Double(done) / Double(total)
            let complete = done == total
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressRingView(ratio: ratio, done: complete, size: 15)
                    Text("\(done)/\(total) " + language.t("shotlistProgress.shot"))
                        .font(.caption.weight(complete ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(complete ? ProgressRingView.green : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(ProgressRingView.green).frame(width: geo.size.width * ratio)
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

/// "🌤 14° · 10 %" — weather at the scene's start time and place
struct WeatherPill: View {
    let weather: SceneWeather

    var body: some View {
        Text(weather.label)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(weather.text)
    }
}
