import SwiftUI
import AVKit

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

    /// Matches web's OPEN_TRANSITION/CLOSE_TRANSITION cubic-bezier(0.16, 1,
    /// 0.3, 1) — SwiftUI's timingCurve takes the same 4 control points.
    private static let openAnimation = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.48)
    private static let closeAnimation = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.38)
    private static let closeDuration = 0.38

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
        }
        .onDisappear { player?.pause() }
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
