import SwiftUI
import Combine
import ClerkKit
import ClerkKitUI

/// Login screen. Clerk's own AuthView (sheet) still handles the actual sign-in/sign-up form,
/// Google, etc. — this screen is the branded entry point in front of it.
///
/// 2026-10-13, Lino: "anmelde screen schöner und interaktiver, das falsche app icon ist noch drin,
/// das app icon soll dynamisch und smooth rein animiert werden und der hintergrund soll mehr
/// cinematisch sein" —
/// - AppIconDisplay is now the new clapperboard icon (same file as AppIcon.appiconset).
/// - Background: a projector beam from above, an anamorphic flare behind the icon, film grain +
///   drifting dust at 24 fps, vignette, and letterbox bars that open at launch like a film starting.
/// - Icon: flies in from depth (blur → sharp, 3D tilt, spring), then a light sweep; it tilts with
///   the finger and bounces (+ haptic) on tap. A red LED timecode runs under the tagline (matches
///   the icon's displays).
struct LoginView: View {
    @ObservedObject private var language = AppLanguage.shared
    @State private var authIsPresented = false
    @State private var appeared = false
    /// letterbox bars open shortly after launch
    @State private var barsOpen = false
    @State private var shine = false
    @State private var idlePulse = false
    @State private var drag: CGSize = .zero
    @State private var tapBounce = false
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CinematicBackground(appeared: appeared, flareY: geo.size.height * 0.36)

                VStack(spacing: 0) {
                    Spacer()
                    icon
                        .padding(.bottom, 26)
                    Text("Subshot")
                        .font(.custom("Anton-Regular", size: 48))
                        .textCase(.uppercase)
                        .tracking(appeared ? 1.5 : 14)
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.18), radius: 14)
                        .opacity(appeared ? 1 : 0)
                        .blur(radius: appeared ? 0 : 8)
                        .animation(.easeOut(duration: 1.1).delay(0.45), value: appeared)
                    Text(language.t("loginView.tagline"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 6)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(.easeOut(duration: 0.8).delay(0.75), value: appeared)
                    timecode
                        .padding(.top, 18)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.8).delay(1.0), value: appeared)
                    Spacer()
                    signInButton
                        .padding(.horizontal, 36)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 20) + 36)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 30)
                        .animation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.9), value: appeared)
                }
                .frame(maxWidth: .infinity)

                letterbox(height: geo.size.height)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            start = Date()
            withAnimation(.spring(response: 1.1, dampingFraction: 0.7).delay(0.15)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.4).delay(0.1)) { barsOpen = true }
            withAnimation(.easeInOut(duration: 1.1).delay(1.15)) { shine = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { idlePulse = true }
            }
        }
        .sheet(isPresented: $authIsPresented) {
            AuthView()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Icon

    private var icon: some View {
        let size: CGFloat = 132
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        return Image("AppIconDisplay")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            // light sweep across the glass once it has landed
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .rotationEffect(.degrees(20))
                        .offset(x: shine ? g.size.width * 1.4 : -g.size.width * 0.9)
                        .blendMode(.plusLighter)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.8))
            // the icon's red LED glow, breathing
            .shadow(color: Color(red: 1, green: 0.23, blue: 0.19).opacity(idlePulse ? 0.38 : 0.16), radius: idlePulse ? 34 : 20)
            .shadow(color: .black.opacity(0.6), radius: 24, y: 16)
            // interactive: follows the finger, bounces on tap
            .rotation3DEffect(.degrees(Double(drag.width) / 6), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(Double(-drag.height) / 6), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .scaleEffect(tapBounce ? 0.9 : 1)
            .offset(y: idlePulse ? -4 : 2)
            // entrance: from depth, blurred and tilted → sharp
            .scaleEffect(appeared ? 1 : 0.35)
            .rotation3DEffect(.degrees(appeared ? 0 : 55), axis: (x: 1, y: -0.4, z: 0), perspective: 0.5)
            .blur(radius: appeared ? 0 : 18)
            .opacity(appeared ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.7)) {
                            drag = CGSize(width: max(-90, min(90, v.translation.width)), height: max(-90, min(90, v.translation.height)))
                        }
                    }
                    .onEnded { v in
                        let tapped = abs(v.translation.width) < 6 && abs(v.translation.height) < 6
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.45)) { drag = .zero }
                        if tapped { bounce() }
                    }
            )
    }

    private func bounce() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { tapBounce = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.4)) { tapBounce = false }
        }
        shine = false
        withAnimation(.easeInOut(duration: 0.8)) { shine = true }
    }

    // MARK: Timecode

    /// a running 25 fps timecode in the icon's red LED style
    private var timecode: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 25)) { ctx in
            let t = max(0, ctx.date.timeIntervalSince(start))
            let frames = Int(t * 25)
            let text = String(format: "%02d:%02d:%02d:%02d", (frames / 90_000) % 24, (frames / 1500) % 60, (frames / 25) % 60, frames % 25)
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(red: 1, green: 0.23, blue: 0.19))
                    .frame(width: 7, height: 7)
                    .opacity(frames % 25 < 13 ? 1 : 0.25)
                Text(text)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.22))
                    .shadow(color: Color(red: 1, green: 0.2, blue: 0.15).opacity(0.8), radius: 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        }
    }

    // MARK: Button

    private var signInButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            authIsPresented = true
        } label: {
            HStack(spacing: 8) {
                Text(language.t("loginView.signInButton"))
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .offset(x: idlePulse ? 3 : 0)
            }
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(.white, in: Capsule())
            .shadow(color: .white.opacity(idlePulse ? 0.22 : 0.08), radius: idlePulse ? 22 : 12)
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: Letterbox

    /// black cinema bars that slide away at launch (2.39:1 → full frame)
    private func letterbox(height: CGFloat) -> some View {
        let bar = height * 0.22
        return VStack {
            Color.black.frame(height: bar).offset(y: barsOpen ? -bar : 0)
            Spacer()
            Color.black.frame(height: bar).offset(y: barsOpen ? bar : 0)
        }
        .allowsHitTesting(false)
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// projector beam, anamorphic flare, film grain + dust, vignette
private struct CinematicBackground: View {
    let appeared: Bool
    let flareY: CGFloat

    /// fixed dust particles (position 0…1, speed, size)
    private static let dust: [(x: Double, y: Double, speed: Double, size: Double, phase: Double)] = {
        var g = SystemRandomNumberGenerator()
        return (0..<46).map { _ in
            (Double.random(in: 0...1, using: &g), Double.random(in: 0...1, using: &g),
             Double.random(in: 0.006...0.025, using: &g), Double.random(in: 0.8...2.4, using: &g),
             Double.random(in: 0...(2 * .pi), using: &g))
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let w = size.width, h = size.height
                // base: deep warm-black gradient
                gc.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.07, green: 0.06, blue: 0.06), Color(red: 0.02, green: 0.02, blue: 0.025), .black]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

                // projector beam from the top, slowly swaying
                let sway = sin(t * 0.25) * w * 0.06
                var beam = Path()
                beam.move(to: CGPoint(x: w * 0.5 + sway * 0.3 - 18, y: -10))
                beam.addLine(to: CGPoint(x: w * 0.5 + sway * 0.3 + 18, y: -10))
                beam.addLine(to: CGPoint(x: w * 1.05 + sway, y: h * 0.82))
                beam.addLine(to: CGPoint(x: -w * 0.05 + sway, y: h * 0.82))
                beam.closeSubpath()
                let flicker = 0.9 + 0.1 * sin(t * 13) * sin(t * 7.3)
                gc.drawLayer { l in
                    l.addFilter(.blur(radius: 30))
                    l.fill(beam, with: .linearGradient(
                        Gradient(colors: [Color(red: 1, green: 0.93, blue: 0.82).opacity(0.17 * flicker), .clear]),
                        startPoint: CGPoint(x: w / 2, y: 0), endPoint: CGPoint(x: w / 2, y: h * 0.8)))
                }

                // anamorphic flare behind the icon (warm core, long thin streak)
                let pulse = 0.85 + 0.15 * sin(t * 0.9)
                gc.drawLayer { l in
                    l.addFilter(.blur(radius: 46))
                    l.fill(Path(ellipseIn: CGRect(x: w / 2 - 120, y: flareY - 110, width: 240, height: 220)),
                           with: .color(Color(red: 1, green: 0.25, blue: 0.18).opacity(0.22 * pulse)))
                }
                gc.drawLayer { l in
                    l.addFilter(.blur(radius: 5))
                    l.fill(Path(ellipseIn: CGRect(x: -w * 0.1, y: flareY - 2.5, width: w * 1.2, height: 5)),
                           with: .linearGradient(Gradient(colors: [.clear, Color(red: 0.55, green: 0.75, blue: 1).opacity(0.5 * pulse), .clear]),
                                                 startPoint: CGPoint(x: 0, y: flareY), endPoint: CGPoint(x: w, y: flareY)))
                }

                // dust floating in the beam
                for d in Self.dust {
                    let y = (d.y - t * d.speed).truncatingRemainder(dividingBy: 1)
                    let py = (y < 0 ? y + 1 : y) * h
                    let px = d.x * w + sin(t * 0.4 + d.phase) * 14
                    let inBeam = max(0, 1 - abs(px - w / 2 - sway * 0.6) / (w * 0.55)) * (1 - py / h)
                    let a = (0.12 + 0.5 * inBeam) * (0.6 + 0.4 * sin(t * 1.3 + d.phase))
                    gc.fill(Path(ellipseIn: CGRect(x: px, y: py, width: d.size, height: d.size)), with: .color(.white.opacity(a)))
                }

                // film grain: new random specks every frame
                var rng = SeededRandom(seed: UInt64(t * 24))
                for _ in 0..<520 {
                    let x = rng.next() * w, y = rng.next() * h
                    let s = 0.6 + rng.next() * 1.1
                    gc.fill(Path(CGRect(x: x, y: y, width: s, height: s)),
                            with: .color((rng.next() < 0.5 ? Color.white : Color.black).opacity(0.05 + rng.next() * 0.07)))
                }

                // vignette
                gc.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.85)]),
                    center: CGPoint(x: w / 2, y: h * 0.42), startRadius: min(w, h) * 0.3, endRadius: max(w, h) * 0.75))
            }
        }
        .opacity(appeared ? 1 : 0)
        .animation(.easeIn(duration: 1.2), value: appeared)
        .ignoresSafeArea()
    }
}

/// tiny deterministic generator (grain changes per frame, not per redraw)
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

#Preview {
    LoginView()
}
