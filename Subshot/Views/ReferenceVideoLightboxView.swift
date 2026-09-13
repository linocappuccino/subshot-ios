import SwiftUI
import AVKit
import UIKit

/// 2026-09-08, Lino: "wenn man darauf klickt, soll sich das video in einer
/// lightbox öffnen (auch in der ios app)" — minimal fullscreen video-only
/// viewer for the Scribble Video thumbnail (ReferenceVideoBlockView),
/// presented via `.fullScreenCover`. Deliberately NOT VideoPlayerSheet
/// (comments/frame-save/download — none of that applies to a single
/// unversioned reference file, same reasoning as web's
/// ReferenceVideoLightbox skipping VideoReviewModal) — just autoplay +
/// close, same swipe-down-to-dismiss + frosted close-button convention
/// VideoPlayerSheet already uses for visual consistency.
///
/// 2026-09-10, Lino: "kann das scribble video nicht so öffnen wie die
/// videos auf der linocappuccino webseite, quasi in einem lightbox player
/// mit der gleichen open animation?" — web's own port of that site's FLIP
/// transition (see ReferenceVideoBlock.tsx) anchors the animation to the
/// EXACT clicked thumbnail's on-screen rect, which relies on
/// `matchedGeometryEffect`-style geometry sharing between the thumbnail and
/// the modal content — SwiftUI's `matchedGeometryEffect` does NOT bridge
/// across a `.fullScreenCover` presentation boundary (separate view/window
/// hierarchy), so a pixel-anchored version isn't reliably achievable here
/// the same way without a much larger custom-presentation rewrite (no
/// compiler in this sandbox to verify that kind of change against). This is
/// the closest safe analog instead: a scale+fade "grow in" using the SAME
/// timing curve/duration as web's OPEN_TRANSITION
/// (`cubic-bezier(0.16, 1, 0.3, 1)`, 480ms), reversed on explicit close (the
/// × button — NOT the swipe-to-dismiss gesture, which already has its own
/// implicit motion from the drag itself and shouldn't also fade).
/// UNVERIFIED — no compiler here, see project memory (iOS: no compiler here).
struct ReferenceVideoLightboxView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var appeared = false
    /// 2026-09-13, Lino: "wenn man das video im portrait modus ansieht und
    /// dann das handy dreht schliesst es das video" — the swipe-to-dismiss
    /// DragGesture below reports its `.translation` in this view's OWN
    /// local coordinate space, and that space's bounds literally swap
    /// (width↔height) mid-touch as the interface rotates — a finger that
    /// never actually moved can end up looking like a huge vertical swipe
    /// once the frame under it has flipped shape, which was silently
    /// triggering `dismiss()`. Two-part guard: `isLandscape` disables the
    /// gesture for good once actually in landscape (there's no reason to
    /// swipe-dismiss a landscape fullscreen video anyway, the × button
    /// still works), and `rotationCooldownUntil` additionally blocks any
    /// dismiss for a short window starting the moment a rotation is
    /// DETECTED (device sensor fires close to instantly, well before the
    /// ~0.3–0.5s interface-rotation animation finishes) — covers the
    /// portrait→landscape transition itself, not just the landscape state
    /// after it completes.
    @State private var isLandscape = false
    @State private var rotationCooldownUntil = Date.distantPast

    /// Matches web's OPEN_TRANSITION/CLOSE_TRANSITION cubic-bezier(0.16, 1,
    /// 0.3, 1) — SwiftUI's timingCurve takes the same 4 control points.
    private static let openAnimation = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.48)
    private static let closeAnimation = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.38)
    private static let closeDuration = 0.38
    private static let rotationCooldownDuration: TimeInterval = 0.6

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .scaleEffect(appeared ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                guard !isLandscape, Date() >= rotationCooldownUntil else { return }
                                let v = value.translation.height
                                let h = value.translation.width
                                guard abs(v) > abs(h) * 1.5, v > 80 else { return }
                                dismiss()
                            }
                    )
            }
            VStack {
                HStack {
                    closeButton
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 22)
                Spacer()
            }
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            let p = AVPlayer(url: url)
            p.allowsExternalPlayback = false
            player = p
            p.play()
            withAnimation(Self.openAnimation) { appeared = true }
            // 2026-09-13, Lino: "wenn man ... den Bildschirm vom iphone
            // dreht, dreht sich das video nicht mit und wird nicht
            // fullscreen" — the rest of the app is portrait-locked (see
            // AppDelegate), which silently blocked this too. Opt in only
            // for as long as this lightbox is on screen (see
            // OrientationLock's own doc comment).
            OrientationLock.shared.setAllowsLandscape(true)
            // UIDevice orientation notifications are opt-in — nothing
            // fires without this, so isLandscape/rotationCooldownUntil
            // above would otherwise never update.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            isLandscape = UIDevice.current.orientation.isLandscape
        }
        .onDisappear {
            player?.pause()
            OrientationLock.shared.setAllowsLandscape(false)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            rotationCooldownUntil = Date().addingTimeInterval(Self.rotationCooldownDuration)
            let orientation = UIDevice.current.orientation
            // .faceUp/.faceDown/.unknown (phone laid flat, or the sensor
            // momentarily can't tell) carry no usable portrait/landscape
            // info — keep whatever isLandscape already was rather than
            // guessing, same idea as OrientationLock only ever getting
            // told definite states.
            if orientation.isLandscape {
                isLandscape = true
            } else if orientation.isPortrait {
                isLandscape = false
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Explicit close (the × button) fades/shrinks the content out first,
    /// THEN dismisses — same "animate, wait, then actually go away" shape
    /// as web's requestClose. Swipe-to-dismiss bypasses this entirely (see
    /// this file's own doc comment above).
    private func requestClose() {
        withAnimation(Self.closeAnimation) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDuration) {
            dismiss()
        }
    }

    /// Same frosted-glass circular close button as VideoPlayerSheet's own
    /// closeButton (see that file's doc comment for why this style was
    /// chosen over a flat xmark.circle.fill glyph).
    private var closeButton: some View {
        Button {
            requestClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
    }
}
