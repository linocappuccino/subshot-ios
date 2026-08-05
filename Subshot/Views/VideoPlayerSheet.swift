import SwiftUI
import AVKit
import Photos

/// Vollbild-Player fuers Video-Feedback-Tool.
///
/// 2026-07-26 — full control-layout rework, Lino (after actually using the
/// #284 build): "öffnet man ein Video, kann man KEINE kommentare machen?
/// wieso?" Root cause: the ONLY way in was a `.onLongPressGesture` layered
/// on top of AVKit's `VideoPlayer` — that view installs its OWN UIKit
/// gesture recognizers internally (tap-to-toggle-chrome, double-tap-seek,
/// long-press for the system context menu), which routinely win the
/// recognizer race against a SwiftUI `.gesture`/`.onLongPressGesture`
/// layered on top of it, so the long-press silently did nothing most of
/// the time — not a logic bug, a gesture-conflict bug. Fixed by dropping
/// the long-press entirely in favor of an explicit, always-tappable button
/// (see `commentButton` below) that pauses + opens the comment panel no
/// matter what AVKit's own recognizers are doing.
/// Also addresses: the old comment-count button lived in `topBar` (top
/// trailing), the exact corner AVKit's own fullscreen chrome renders its
/// AirPlay/PiP icons in — Lino: "der kommentar button... ist zu nahe am
/// Volumen button, soll nach rechts unten". Moved to a bottom-trailing
/// custom cluster instead, well clear of that native corner —
/// `player.allowsExternalPlayback = false` below also drops the native
/// AirPlay icon.
/// 2026-07-27 — the custom "Teilen" button (reused ShareLinkSheet) that
/// used to sit in this cluster was removed again: Lino doesn't want a
/// share affordance inside the iOS video player itself (unlike web).
/// `saveFrameButton`/`commentButton` also nudged up (`.padding(.bottom, 56)`
/// on the cluster) — they were overlapping AVKit's own transport bar.
/// NOT changed: AVKit's native bottom-right "..." (playback speed) menu —
/// there is no public API to selectively hide just that button while
/// keeping the rest of the system transport bar (play/pause/scrub); doing
/// so would mean replacing AVKit's entire control surface with a fully
/// custom one (`showsPlaybackControls = false` + hand-built scrubber),
/// which is too large/too risky to ship blind with no compiler here to
/// verify it against. Flagged back to Lino rather than guessed at.
struct VideoPlayerSheet: View {
    let video: Video
    let version: VideoVersion
    /// 2026-07-26 — nil for VideoPanelView.swift's superseded/dead call
    /// site (no project id in scope there, see that file's own doc
    /// comment); the live PostproductionListView call site always passes
    /// a real value. The share button hides itself when nil.
    var projectId: String? = nil
    var onVersionUpdated: (VideoVersion) -> Void

    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    /// 2026-07-26 — was two separate bools (showCommentField/
    /// showCommentList); Lino: "drückt man [den Kommentar-Button], sieht
    /// man die anderen Kommentare UND kann direkt einen neuen Kommentar
    /// einfügen" — one tap now always reveals BOTH together instead of the
    /// add-bar only being reachable via the old long-press.
    @State private var showCommentPanel = false
    @State private var commentText = ""
    @State private var authorName = ""
    @State private var comments: [VideoComment]
    @State private var posting = false
    @State private var errorMessage: String?
    @FocusState private var commentFieldFocused: Bool
    // 2026-07-27, Lino: "hat man pause gedrückt auf einem video soll man
    // diesen frame per download button direkt als PNg downloadn können" —
    // iOS has no "Downloads" concept, Photos is the platform-native
    // equivalent (same reasoning as reusing ShareLinkSheet/ActivityView
    // above instead of a literal port of anything web-specific).
    @State private var savingFrame = false
    @State private var frameJustSaved = false

    init(video: Video, version: VideoVersion, projectId: String? = nil, onVersionUpdated: @escaping (VideoVersion) -> Void) {
        self.video = video
        self.version = version
        self.projectId = projectId
        self.onVersionUpdated = onVersionUpdated
        _comments = State(initialValue: version.comments)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    // 2026-07-21, #284 — swipe down closes the player
                    // (back to the Postproduction grid), swipe up reveals
                    // the comment panel; a plain vertical-translation
                    // DragGesture rather than anything library-specific
                    // (web's VideoReviewModal has no swipe gestures at
                    // all to port from — this is a mobile-native addition
                    // the ticket asks for directly). Horizontal drags are
                    // ignored (scrubbing stays the system VideoPlayer's
                    // own built-in seek bar). The long-press-to-comment
                    // gesture that used to live here is gone — see this
                    // struct's own top-of-file doc comment for why.
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                let v = value.translation.height
                                let h = value.translation.width
                                guard abs(v) > abs(h) * 1.5 else { return }
                                if v > 80 {
                                    dismiss()
                                } else if v < -80 {
                                    withAnimation { showCommentPanel = true }
                                }
                            }
                    )
                    // 2026-08-05, Lino: "egal wo man auf das video klickt,
                    // soll das video stoppen oder weiter spielen" — NOT a
                    // `.gesture()` (a plain `.onTapGesture`/`.gesture`
                    // modifier here would COMPETE with AVKit's own internal
                    // tap recognizer for exclusive ownership, the exact
                    // failure mode this file's own top-of-file doc comment
                    // already documents for the old long-press-to-comment
                    // gesture — it silently lost that race most of the
                    // time). `.simultaneousGesture` explicitly does NOT
                    // claim exclusivity, so this fires ALONGSIDE AVKit's own
                    // tap-to-show/hide-chrome behavior instead of racing it,
                    // and never swallows a tap that lands on the native
                    // transport bar/scrub controls when they're visible.
                    .simultaneousGesture(
                        TapGesture().onEnded { togglePlayback() }
                    )
            }
            VStack {
                // Small handlebar (2026-07-21, #284: "a small handlebar
                // shows at the top") — a purely visual affordance for the
                // swipe-down-to-close gesture above, same idea as a
                // native iOS sheet's own grabber.
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                topBar
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.red.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if !showCommentPanel {
                    // 2026-07-26 — bottom-trailing custom cluster, well
                    // clear of AVKit's own top-trailing AirPlay/PiP corner
                    // (see doc comment above). Hidden while the panel is
                    // open — the panel's own send button takes over.
                    HStack {
                        Spacer()
                        controlCluster
                    }
                    .padding(.trailing, 16)
                    // 2026-07-27, Lino: "die buttons unten überdecken nun
                    // die videoplayer buttons" — AVKit's own native
                    // transport bar (play/pause/scrub) sits right at the
                    // bottom edge; raised well clear of it (was 8).
                    .padding(.bottom, 56)
                }
                if showCommentPanel {
                    commentListOverlay
                    commentBar
                }
            }
        }
        .onAppear {
            guard let urlString = version.playbackUrl, let url = URL(string: urlString) else { return }
            let p = AVPlayer(url: url)
            // 2026-07-26 — drops the native AirPlay ("Bildschirm
            // freigeben") icon from AVKit's own top-trailing chrome now
            // that a custom "Teilen" button exists (see controlCluster);
            // avoids two overlapping "share to somewhere" affordances.
            p.allowsExternalPlayback = false
            player = p
            p.play()
        }
        .task {
            // 2026-07-23 (#322) — authorName started every long-press comment
            // completely empty, forcing a name re-typed by hand each time
            // before the (otherwise-ready) send button would even enable —
            // real friction on the "long-press, type, done" flow this sheet
            // was actually built for. Same name ?? email fallback SceneEditSheet
            // already uses for a known collaborator.
            // Guard against clobbering a name the user already started typing
            // while this (network-dependent) fetch was still in flight.
            if authorName.isEmpty, let me = try? await APIClient.shared.me() {
                authorName = me.name ?? me.email
            }
        }
        .onDisappear { player?.pause() }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
            Spacer()
        }
        .padding()
    }

    /// 2026-07-26 — bottom-trailing custom row: "Teilen" (share) button on
    /// the left, comment button on the right/outer corner ("Display share
    /// button soll links neben den Volumen button... Kommentar soll nach
    /// rechts unten"), a little spacing between them.
    private var controlCluster: some View {
        HStack(spacing: 14) {
            saveFrameButton
            commentButton
        }
    }

    /// 2026-07-27, Lino: pause on a frame you like, tap this to save that
    /// exact frame to Photos — same "pause first, capture what's showing"
    /// intent as web's downloadCurrentFrame in VideoReviewModal.tsx, just
    /// via Photos instead of a browser download. Also pauses on tap itself
    /// (same as commentButton above) so the frame can't drift mid-capture
    /// if the user taps while still playing.
    private var saveFrameButton: some View {
        Button {
            Task { await saveCurrentFrame() }
        } label: {
            Group {
                if savingFrame {
                    ProgressView().tint(.white)
                } else if frameJustSaved {
                    Image(systemName: "checkmark")
                } else {
                    // "square.and.arrow.down" — long-stable SF Symbol (iOS
                    // 13+), deliberately not "photo.badge.arrow.down"
                    // (unverifiable whether that exact symbol name exists,
                    // no compiler here to check — see this file's own
                    // doc comment about not guessing at unverifiable stuff).
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.45))
            .clipShape(Circle())
        }
        .disabled(savingFrame)
        .accessibilityLabel(language.t("videoPlayerSheet.saveFrame"))
    }

    /// 2026-07-26 — replaces the old broken long-press: an always-tappable
    /// button that pauses playback (so the timestamp a new comment lands
    /// on doesn't keep drifting while typing, same intent the long-press
    /// originally had) and opens the merged list+add panel in one go.
    private var commentButton: some View {
        Button {
            player?.pause()
            withAnimation { showCommentPanel.toggle() }
            if showCommentPanel { commentFieldFocused = true }
        } label: {
            Label("\(comments.count)", systemImage: "bubble.left.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .accessibilityLabel(language.t("videoPlayerSheet.comments"))
    }

    private var commentListOverlay: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // 2026-07-26 — the comment button that opens this panel
                // hides itself while the panel is showing (see body
                // above), so there needs to be an explicit close affordance
                // in here instead of relying purely on the swipe-down
                // gesture.
                HStack {
                    Text(language.t("videoPlayerSheet.comments"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button {
                        withAnimation { showCommentPanel = false }
                    } label: {
                        Image(systemName: "chevron.down.circle.fill")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                if comments.isEmpty {
                    Text(language.t("videoPlayerSheet.noComments"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ForEach(comments.sorted(by: { $0.timestampSeconds < $1.timestampSeconds })) { comment in
                        HStack(alignment: .top, spacing: 8) {
                            // 2026-07-21, #284 — resolved/open checkbox
                            // (mirrors web's VideoReviewModal.
                            // toggleResolved); its own tap target, kept
                            // separate from the seek-to-timestamp Button
                            // below so the two never fight over the same
                            // tap.
                            Button {
                                Task { await toggleResolved(comment) }
                            } label: {
                                Image(systemName: comment.resolved ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(comment.resolved ? .green : .white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 1)

                            Button {
                                player?.seek(to: CMTime(seconds: comment.timestampSeconds, preferredTimescale: 600))
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(timeLabel(comment.timestampSeconds))
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(comment.authorName).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                                        Text(comment.comment)
                                            .font(.caption)
                                            .foregroundStyle(comment.resolved ? .white.opacity(0.5) : .white)
                                            .strikethrough(comment.resolved)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 180)
        .background(.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // 2026-07-26, Lino: "Das momentane Kommentarfeld... soll fast
    // bildschirmbreit sein" — was constrained by a fixed 100pt name field
    // PLUS padding applied twice (once around the HStack, again around the
    // whole bar), eating ~64pt of horizontal space on top of that on a
    // ~390pt-wide phone. authorName is already auto-filled from the
    // signed-in account (see the .task above) — shrunk to a small,
    // still-editable 64pt field instead of dropping it outright, single
    // outer padding, so the comment TextField itself gets the vast
    // majority of the screen width.
    private var commentBar: some View {
        HStack(spacing: 6) {
            TextField(language.t("videoPlayerSheet.yourName"), text: $authorName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .font(.caption)
            TextField(language.t("videoPlayerSheet.commentPlaceholder"), text: $commentText)
                .textFieldStyle(.roundedBorder)
                .focused($commentFieldFocused)
                .onSubmit { Task { await postComment() } }
            Button {
                Task { await postComment() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(posting || authorName.trimmingCharacters(in: .whitespaces).isEmpty || commentText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    /// 2026-08-05 — backs the tap-anywhere-on-the-video gesture above.
    /// `player.rate != 0` (not `timeControlStatus == .playing`) is the
    /// right check here: `.playing` briefly reports `.waitingToPlayAtSpecifiedRate`
    /// during buffering, which would make a tap-to-pause during a brief
    /// stall read as "already paused" and incorrectly call `.play()` again.
    private func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 {
            player.play()
        } else {
            player.pause()
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func postComment() async {
        guard let player else { return }
        let trimmedName = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedComment.isEmpty else { return }
        posting = true
        defer { posting = false }
        do {
            let timestamp = player.currentTime().seconds
            let comment = try await APIClient.shared.createVideoComment(
                versionId: version.id, timestampSeconds: timestamp, authorName: trimmedName, comment: trimmedComment
            )
            comments.append(comment)
            var updated = version
            updated.comments = comments
            onVersionUpdated(updated)
            commentText = ""
            showCommentPanel = false
            player.play()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 2026-07-27 — grabs whatever frame `player` is currently showing via
    /// `AVAssetImageGenerator` and saves it to Photos.
    /// `appliesPreferredTrackTransform = true` matters here: without it, a
    /// portrait phone-shot video (this app's normal case, see #341's
    /// aspect-ratio fix elsewhere) comes back sideways, since the raw pixel
    /// buffer ignores the track's rotation transform.
    ///
    /// NOTE for whoever wires this into Xcode: `PHPhotoLibrary.
    /// requestAuthorization(for: .addOnly)` needs `NSPhotoLibraryAddUsageDescription`
    /// set in Info.plist (Xcode's Info tab → "Privacy - Add Photo Only Usage
    /// Description") — this is the FIRST feature in this app that writes to
    /// Photos, so that key doesn't exist yet. Without it the app crashes the
    /// moment this button is tapped, not silently fails.
    private func saveCurrentFrame() async {
        guard let player, let currentItem = player.currentItem, !savingFrame else { return }
        player.pause()
        savingFrame = true
        defer { savingFrame = false }
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                errorMessage = language.t("videoPlayerSheet.photoLibraryDenied")
                return
            }
            let generator = AVAssetImageGenerator(asset: currentItem.asset)
            generator.appliesPreferredTrackTransform = true
            let requestedTime = player.currentTime()
            let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                generator.generateCGImageAsynchronously(for: requestedTime) { image, _, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
            let uiImage = UIImage(cgImage: cgImage)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
            }
            frameJustSaved = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            frameJustSaved = false
        } catch {
            errorMessage = language.t("videoPlayerSheet.frameSaveFailed")
        }
    }

    /// 2026-07-21, #284 — see the checkbox in commentListOverlay above.
    private func toggleResolved(_ comment: VideoComment) async {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let nextStatus = comment.resolved ? "open" : "resolved"
        do {
            let updated = try await APIClient.shared.patchVideoCommentStatus(comment.id, status: nextStatus)
            comments[index] = updated
            var updatedVersion = version
            updatedVersion.comments = comments
            onVersionUpdated(updatedVersion)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
