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
                    .onLongPressGesture(minimumDuration: 0.4) {
                        player.pause()
                        showCommentField = true
                        commentFieldFocused = true
                    }
            }
            VStack {
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
                    Text("Noch keine Kommentare.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ForEach(comments.sorted(by: { $0.timestampSeconds < $1.timestampSeconds })) { comment in
                        Button {
                            player?.seek(to: CMTime(seconds: comment.timestampSeconds, preferredTimescale: 600))
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(timeLabel(comment.timestampSeconds))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(comment.authorName).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                                    Text(comment.comment).font(.caption).foregroundStyle(.white)
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
            TextField("Dein Name", text: $authorName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            TextField("Kommentar…", text: $commentText)
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
}
