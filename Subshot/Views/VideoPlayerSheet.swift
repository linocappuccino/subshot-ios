import SwiftUI
import AVKit

/// Vollbild-Player fuers Video-Feedback-Tool (2026-07-17, Lino: "Vollbild-
/// Video, langer/fester Druck pausiert + oeffnet Kommentarfeld, Enter
/// speichert, Video laeuft weiter"). Langer Druck pausiert UND oeffnet die
/// Kommentarleiste, Rueckgabetaste im Textfeld speichert den Kommentar bei
/// der aktuellen Abspielposition und startet die Wiedergabe automatisch
/// wieder — kein separater "Fortsetzen"-Tap noetig.
struct VideoPlayerSheet: View {
    let video: Video
    let version: VideoVersion
    var onVersionUpdated: (VideoVersion) -> Void

    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var showCommentField = false
    @State private var showCommentList = false
    @State private var commentText = ""
    @State private var authorName = ""
    @State private var comments: [VideoComment]
    @State private var posting = false
    @State private var errorMessage: String?
    @FocusState private var commentFieldFocused: Bool

    init(video: Video, version: VideoVersion, onVersionUpdated: @escaping (VideoVersion) -> Void) {
        self.video = video
        self.version = version
        self.onVersionUpdated = onVersionUpdated
        _comments = State(initialValue: version.comments)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    // 2026-07-21, #284 — "long-press while PLAYING OR
                    // PAUSED" — this fires regardless of the player's
                    // current play/pause state either way (it's a plain
                    // gesture on the view, not conditioned on isPlaying),
                    // pause() on an already-paused player is just a no-op.
                    .onLongPressGesture(minimumDuration: 0.4) {
                        player.pause()
                        showCommentField = true
                        commentFieldFocused = true
                    }
                    // 2026-07-21, #284 — swipe down closes the player
                    // (back to the Postproduction grid), swipe up reveals
                    // the comment list; a plain vertical-translation
                    // DragGesture rather than anything library-specific
                    // (web's VideoReviewModal has no swipe gestures at
                    // all to port from — this is a mobile-native addition
                    // the ticket asks for directly). Horizontal drags are
                    // ignored (scrubbing stays the system VideoPlayer's
                    // own built-in seek bar).
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                let v = value.translation.height
                                let h = value.translation.width
                                guard abs(v) > abs(h) * 1.5 else { return }
                                if v > 80 {
                                    dismiss()
                                } else if v < -80 {
                                    withAnimation { showCommentList = true }
                                }
                            }
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
                if showCommentList {
                    commentListOverlay
                }
                if showCommentField {
                    commentBar
                }
            }
        }
        .onAppear {
            guard let urlString = version.playbackUrl, let url = URL(string: urlString) else { return }
            let p = AVPlayer(url: url)
            player = p
            p.play()
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
            Button {
                withAnimation { showCommentList.toggle() }
            } label: {
                Label("\(comments.count)", systemImage: "bubble.left.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4))
                    .clipShape(Capsule())
            }
        }
        .padding()
    }

    private var commentListOverlay: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
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

    private var commentBar: some View {
        HStack(spacing: 8) {
            TextField(language.t("videoPlayerSheet.yourName"), text: $authorName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
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
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
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
            showCommentField = false
            player.play()
        } catch {
            errorMessage = error.localizedDescription
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
