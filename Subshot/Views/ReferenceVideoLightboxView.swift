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
///
/// 2026-09-13, Lino: "wenn man ... den Bildschirm vom iphone dreht, dreht
/// sich das video nicht mit und wird nicht fullscreen" — TWO attempts at
/// making the app's real UIInterfaceOrientation actually rotate while this
/// view is on screen (an AppDelegate escape hatch flipping the allowed
/// orientation mask, see SubshotApp.swift's git history) both left the
/// video closing itself the instant the phone rotated instead. Root cause
/// unconfirmed (no device here to attach a debugger to), but changing the
/// REAL interface orientation mid-presentation is exactly the kind of thing
/// that can put a `.fullScreenCover`'s hosting/presenting view controllers
/// through real trait-collection churn, which is a plausible way for
/// SwiftUI to lose this view's state (including whatever keeps it
/// presented) without any code here ever calling dismiss().
///
/// This version sidesteps that whole subsystem: the app's interface
/// orientation stays locked to portrait the entire time (SubshotApp's
/// AppDelegate never changes what it returns), and instead this view fakes
/// the rotation purely visually — `rotationEffect` + a frame with width/
/// height swapped, driven by `UIDevice.current.orientation` (the physical
/// accelerometer reading, completely separate from `UIInterfaceOrientation`
/// and the app's own orientation mask). Nothing about the window/view-
/// controller hierarchy ever changes, so there's nothing there left to
/// tear this view's state down. Same technique several mainstream apps use
/// for "rotate this one video into fullscreen without letting the whole
/// app rotate". UNVERIFIED — no compiler here, see project memory (iOS: no
/// compiler here) — the rotation math especially needs confirming on a
/// real device.
struct ReferenceVideoLightboxView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var appeared = false
    /// Physical device orientation (accelerometer), NOT the app's
    /// UIInterfaceOrientation — see this file's own doc comment above for
    /// why those are deliberately kept separate here. `.faceUp`/`.faceDown`/
    /// `.unknown` carry no usable rotation info and are ignored, keeping
    /// whatever this last resolved to rather than snapping to 0°.
    @State private var deviceOrientation: UIDeviceOrientation = .portrait

    /// Matches web's OPEN_TRANSITION/CLOSE_TRANSITION cubic-bezier(0.16, 1,
    /// 0.3, 1) — SwiftUI's timingCurve takes the same 4 control points.
    private static let openAnimation = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.48)
    private static let closeAnimation = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.38)
    private static let closeDuration = 0.38
    private static let rotateAnimation = Animation.easeInOut(duration: 0.3)

    /// UIDeviceOrientation.landscapeLeft/.landscapeRight are the INVERSE of
    /// the equivalent UIInterfaceOrientation names (a well-known gotcha) —
    /// landscapeLeft means the device was turned so its LEFT edge is now up
    /// top, which needs the content rotated +90° (clockwise) to read
    /// upright; landscapeRight is the mirror, -90°.
    private var rotationDegrees: Double {
        switch deviceOrientation {
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        default: return 0
        }
    }
    private var isRotated: Bool { rotationDegrees != 0 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let player {
                    ZStack {
                        VideoPlayer(player: player)
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
                    // Swapped width/height BEFORE rotating: a 90°-rotated
                    // WxH box has a HxW bounding box, so setting this to
                    // (screen height x screen width) up front means the
                    // ROTATED result exactly fills the still-portrait-
                    // shaped screen (geo.size) again — standard "fake
                    // rotation" trick, see this file's own doc comment.
                    .frame(
                        width: isRotated ? geo.size.height : geo.size.width,
                        height: isRotated ? geo.size.width : geo.size.height
                    )
                    .rotationEffect(.degrees(rotationDegrees))
                    .animation(Self.rotateAnimation, value: rotationDegrees)
                    .scaleEffect(appeared ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                // Swipe-to-dismiss only makes sense held
                                // upright — while "rotated" the video fills
                                // the screen edge-to-edge with no safe
                                // margin for an accidental swipe, and the
                                // × button (which rotates along with
                                // everything else above) still works.
                                guard !isRotated else { return }
                                let v = value.translation.height
                                let h = value.translation.width
                                guard abs(v) > abs(h) * 1.5, v > 80 else { return }
                                dismiss()
                            }
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            let p = AVPlayer(url: url)
            p.allowsExternalPlayback = false
            player = p
            p.play()
            withAnimation(Self.openAnimation) { appeared = true }
            // UIDevice orientation notifications are opt-in — nothing
            // fires without this.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            deviceOrientation = UIDevice.current.orientation
        }
        .onDisappear {
            player?.pause()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let orientation = UIDevice.current.orientation
            if orientation.isLandscape || orientation.isPortrait {
                deviceOrientation = orientation
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
