import Foundation

/// iOS port of the web app's lib/media.ts `isVideoUrl` (2026-07-21 feature —
/// idea images can now also be real video files, Lino: "in der
/// Ideenkachel kann man bis jetzt nur Bilder hochladen, aber noch keine
/// Videos"). Same case-insensitive file-extension check on the idea
/// image's URL/storage-key string, kept in exact sync with the backend's
/// own `_ALLOWED_IDEA_MEDIA_TYPES` video entries (app/main.py) — mp4/mov/
/// webm route through AsyncIdeaVideoThumbnail, everything else (including
/// GIFs, see isGifUrl below) keeps rendering through AsyncShotThumbnail.
func isVideoUrl(_ url: String) -> Bool {
    let lower = url.lowercased()
    return [".mp4", ".mov", ".webm"].contains { lower.hasSuffix($0) }
}

/// 2026-07-22 — unlike the web app (a plain `<img src="....gif">` already
/// autoplays natively in every browser, see media.ts's own doc comment for
/// why GIFs are deliberately excluded from isVideoUrl/AuthVideo there),
/// iOS's `UIImage(data:)` — what AsyncShotThumbnail decodes every idea
/// image with — only ever keeps a GIF's FIRST frame; there's no built-in
/// SwiftUI/UIKit API that animates one from a plain UIImage. This helper
/// exists so a call site COULD detect a GIF explicitly, but nothing in this
/// feature actually branches on it: a GIF still correctly skips
/// isVideoUrl (so it isn't wrongly handed to AVPlayer, which can't decode
/// GIF at all) and falls through to AsyncShotThumbnail same as any other
/// still image — it just renders as a static first frame instead of
/// animating, a known gap flagged in this feature's own commit/Todoist
/// entry rather than silently left unmentioned. Real GIF animation would
/// need a frame-by-frame CGImageSource-driven decoder, out of scope here.
func isGifUrl(_ url: String) -> Bool {
    url.lowercased().hasSuffix(".gif")
}
