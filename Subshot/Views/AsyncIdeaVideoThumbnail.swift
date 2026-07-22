import SwiftUI
import AVKit

/// Video counterpart to AsyncShotThumbnail — for idea images that turned out
/// to be real video files (mp4/mov/webm), 2026-07-22 iOS port of the web
/// app's AuthVideo.tsx (2026-07-21, see media.ts's isVideoUrl). Mirrors
/// fetchImage's own dual-path handling (see that method's #248 doc comment):
/// `IdeaImage.imageUrl` is now a presigned R2 URL computed fresh per-
/// response, which streams straight into AVPlayer(url:) with no auth header
/// needed at all — same as VideoPlayerSheet's real Postproduction playback
/// already does for `version.playbackUrl`. The old relative-path/Bearer-
/// fetch scheme is kept as a defensive fallback (downloads to a local temp
/// file first) only in case any idea image URL is ever still on it.
///
/// Always autoplays muted+looped, no user-facing controls — matches
/// AuthVideo.tsx's `<video autoPlay loop muted playsInline>` exactly, and is
/// deliberately NOT AVKit's `VideoPlayer` (what VideoPlayerSheet uses for
/// real Postproduction video review) — that shows system play/pause/scrub
/// controls on tap, wrong for something that's meant to behave like an
/// auto-looping animated image (per AuthVideo.tsx's own doc comment: "these
/// are silent GIF-like clips in an idea tile, not a video anyone expects to
/// hear"), not a video a user pauses or scrubs.
struct AsyncIdeaVideoThumbnail: View {
    let path: String

    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var loopObserver: NSObjectProtocol?

    /// Shared across instances, same reasoning as AsyncShotThumbnail.cache —
    /// only used by the defensive local-download fallback below (the
    /// primary presigned-URL path streams directly, nothing to cache).
    /// Caches the LOCAL temp file URL the bytes were written to, keyed by
    /// path.
    private static let cache = NSCache<NSString, NSURL>()

    var body: some View {
        ZStack {
            if let player {
                LoopingVideoLayerView(player: player)
            } else if failed {
                Image(systemName: "video.slash")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            await load()
        }
        .onDisappear {
            player?.pause()
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
            }
        }
    }

    private func load() async {
        // 2026-07-22 (#248) — a presigned R2 URL streams straight into
        // AVPlayer(url:), no Bearer header needed, no need to buffer the
        // whole clip into a local temp file first.
        if path.hasPrefix("http"), let url = URL(string: path) {
            setUpPlayer(url: url)
            return
        }
        // Defensive fallback for the old relative-path/Bearer-auth scheme —
        // shouldn't occur for idea images post-#248, kept only for parity
        // with fetchImage's own dual-path handling.
        let key = path as NSString
        if let cachedURL = Self.cache.object(forKey: key) {
            setUpPlayer(url: cachedURL as URL)
            return
        }
        // Same three-attempt/backoff shape as AsyncShotThumbnail.load — a
        // single transient network blip shouldn't permanently blank a tile.
        for attempt in 0..<3 {
            do {
                let data = try await APIClient.shared.fetchMediaData(path: path)
                let pathExtension = (path as NSString).pathExtension.lowercased()
                let ext = ["mp4", "mov", "webm"].contains(pathExtension) ? pathExtension : "mp4"
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                try data.write(to: tempURL)
                Self.cache.setObject(tempURL as NSURL, forKey: key)
                setUpPlayer(url: tempURL)
                return
            } catch {
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 400_000_000 * UInt64(attempt + 1))
                }
            }
        }
        failed = true
    }

    private func setUpPlayer(url: URL) {
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
        player = newPlayer
        newPlayer.play()
    }
}

/// Chrome-less looping video surface — a plain `UIViewRepresentable` around
/// `AVPlayerLayer`, deliberately lower-level than AVKit's `VideoPlayer` (see
/// AsyncIdeaVideoThumbnail's own doc comment for why: no system controls,
/// nothing to tap/pause/scrub, just a looping clip filling its frame like an
/// `<img>` would).
private struct LoopingVideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerContainer {
        let view = PlayerLayerContainer()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainer, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerContainer: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer {
            // Safe force-cast — layerClass above guarantees `layer` is
            // always an AVPlayerLayer for this view.
            layer as! AVPlayerLayer
        }
    }
}
