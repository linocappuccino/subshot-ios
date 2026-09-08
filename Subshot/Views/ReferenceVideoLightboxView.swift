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
/// UNVERIFIED — no compiler here, see project memory (iOS: no compiler here).
struct ReferenceVideoLightboxView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
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
        }
        .onAppear {
            let p = AVPlayer(url: url)
            p.allowsExternalPlayback = false
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
        .preferredColorScheme(.dark)
    }

    /// Same frosted-glass circular close button as VideoPlayerSheet's own
    /// closeButton (see that file's doc comment for why this style was
    /// chosen over a flat xmark.circle.fill glyph).
    private var closeButton: some View {
        Button {
            dismiss()
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
