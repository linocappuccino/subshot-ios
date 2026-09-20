import SwiftUI
import Combine
import AVKit
import Photos
import UIKit

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
    /// 2026-08-09 — download the whole video (not just the current frame)
    /// to Photos, same permission/flow shape as saveFrameButton.
    @State private var downloadingVideo = false
    @State private var videoJustSaved = false
    /// 2026-08-09, Lino: "können wir hier einfach den avatar neben dem
    /// kommentareingabefeld anzeigen anstatt den namen" — the signed-in
    /// user's own profile, fetched once in the .task below (authorName
    /// itself is still derived from it and still sent to the API
    /// unchanged, just no longer shown as an editable text field).
    @State private var me: Me?
    /// 2026-09-20 (2nd follow-up), Lino, emphatic: "das video wird immer
    /// noch kleiner wenn die tastatur erscheint! FIXEN! DAS VIDEO DARF DIE
    /// GRÖSSE NIE ÄNDERN egal was auf dem bildschirm passiert!" — the
    /// previous fix (fixed top section + flexible ScrollView +
    /// `.safeAreaInset(.bottom)` for the input bar) relied on SwiftUI's
    /// own implicit keyboard-avoidance space-redistribution, which turned
    /// out to still shrink the video: once the keyboard reduces the
    /// available height for the WHOLE VStack, an `.aspectRatio(.fit)`
    /// video has no fixed minimum of its own — `.fit` means exactly
    /// "shrink to whatever you're given," so any reduction anywhere
    /// upstream reaches it. This time: `.ignoresSafeArea(.keyboard)` on
    /// the ENTIRE screen (see body's own doc comment) makes it
    /// STRUCTURALLY impossible for the keyboard to change what height
    /// anything gets proposed, video included — full stop, no implicit
    /// system behavior involved. The one thing that still needs to move
    /// (`commentBar`) does so manually instead, padded by a tracked
    /// `keyboardHeight` from raw `UIResponder` notifications (see
    /// subscribeToKeyboard()/unsubscribeFromKeyboard() below) — a
    /// deliberately more manual, more verbose mechanism than relying on
    /// SwiftUI's own keyboard-avoidance, chosen specifically because that
    /// implicit mechanism is the thing that broke the video's size in the
    /// first place.
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardObserver: NSObjectProtocol?

    /// 2026-09-20 (3rd round), Lino, still emphatic after round 2:
    /// "das video wird immer noch verkleinert wenn die tastatur
    /// erscheint!... das Video MUSS immer die gleiche grösse behalten!
    /// ohne kompromisse." Rounds 1 and 2 both tried to keep the video's
    /// size stable by controlling how SwiftUI's LAYOUT NEGOTIATION treats
    /// it (fixed section vs. flexible ScrollView, then
    /// `.ignoresSafeArea(.keyboard)`) — evidently still not enough;
    /// something in this view's tree (candidates: the `.toolbar(.keyboard)`
    /// accessory itself, or an interaction between `.fullScreenCover` and
    /// keyboard presentation) still reaches the video's `.aspectRatio(.fit)`
    /// sizing, which by definition ADAPTS to whatever it's proposed.
    /// Removing that dependency entirely this time: an explicit, hardcoded
    /// `.frame(width:height:)` computed directly from `UIScreen.main.
    /// bounds` (device screen size, NOT a GeometryReader's live proposed
    /// size — that would still fluctuate with the keyboard) — this makes
    /// the video's size a fixed number, structurally outside SwiftUI's
    /// layout negotiation altogether, so NOTHING happening anywhere else
    /// in the tree can change it, regardless of which exact mechanism was
    /// actually responsible for the previous two rounds' failures.
    private var videoSize: CGSize {
        let width = UIScreen.main.bounds.width
        return CGSize(width: width, height: width * 9.0 / 16.0)
    }

    /// 2026-09-20 (4th round), Lino: "öffnet sich nun die tastatur,
    /// verschiebt es das video weiter nach oben über den phone rand
    /// hinaus.. das video darfs sich in der POSITION NICHT verschieben!"
    /// — round 3's hardcoded `.frame` fixed the SIZE, but the video was
    /// still a sibling inside the SAME VStack as the keyboard-responsive
    /// comment area, so the whole VStack (and everything in it, video
    /// included) could still be pushed/translated by whatever was still
    /// reacting to the keyboard. Fixed this round by giving the video its
    /// own completely separate ZStack LAYER (see body below) instead of a
    /// shared parent with anything keyboard-related — measured once here
    /// so the OTHER layer knows how much top space to reserve.
    @State private var topLayerHeight: CGFloat = 0

    init(video: Video, version: VideoVersion, projectId: String? = nil, onVersionUpdated: @escaping (VideoVersion) -> Void) {
        self.video = video
        self.version = version
        self.projectId = projectId
        self.onVersionUpdated = onVersionUpdated
        _comments = State(initialValue: version.comments)
    }

    var body: some View {
        // 2026-09-20 (6th round), Lino, with a screen recording proving it
        // this time: the X-button/handlebar/video-top all scroll clean
        // OFF the top edge of the screen when the keyboard opens — not a
        // subtle size/layout miscalculation, the ENTIRE content is being
        // translated upward by something outside this view's own layout
        // tree entirely (rounds 1-5, all pure SwiftUI-layout fixes —
        // `.ignoresSafeArea(.keyboard)` at every level tried, a hardcoded
        // frame, two independent ZStack layers — none of them stopped it,
        // which only makes sense if the push happens ABOVE this view, most
        // likely `.fullScreenCover`'s own hosting controller getting
        // automatically resized/transformed for the keyboard by UIKit in
        // a way no SwiftUI-side layout modifier has jurisdiction over).
        // Changed strategy entirely this round: instead of trying to
        // prevent whatever is causing the push, MEASURE the actual on-
        // screen position via a `GeometryReader` in `.global` coordinate
        // space and actively cancel out any drift with an equal-and-
        // opposite `.offset()` — this corrects for the shift regardless
        // of its root cause, since it reacts to the real observed
        // position rather than assuming why it moved.
        GeometryReader { outerGeo in
            content
                .offset(y: -outerGeo.frame(in: .global).minY)
        }
        .ignoresSafeArea()
    }

    private var content: some View {
        // 2026-09-20 (4th round), Lino: "das video darfs sich in der
        // POSITION NICHT verschieben! egal was passiert!" — rounds 1-3 all
        // kept the video as a SIBLING inside one shared VStack alongside
        // the keyboard-responsive comment area, so however that keyboard-
        // avoidance was still reaching the tree (never fully pinned down
        // across 3 rounds), the whole VStack — video included — could
        // still get pushed/translated. Fixed this round by making the
        // video (+handlebar+topBar+error) a COMPLETELY SEPARATE ZStack
        // layer from the keyboard-responsive content, not a flow sibling
        // of it at all — nothing that layer does can ever reach this one.
        // `topLayerHeight` is measured (not hand-guessed) so the other
        // layer knows how much top space to leave clear.
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            // Keyboard-responsive layer: buttons row, comment list, input
            // bar. Free to shift/resize with the keyboard however it
            // wants (commentBar's own bottom padding does that, same
            // `keyboardHeight` tracking as round 2) — none of it can
            // reach the video layer below, since they're independent
            // ZStack children, not a shared VStack flow.
            VStack(spacing: 0) {
                Spacer().frame(height: topLayerHeight)
                HStack {
                    Spacer()
                    controlCluster
                }
                .padding(.trailing, 16)
                .padding(.top, 16)
                ScrollView {
                    commentListContent
                        .padding(12)
                }
                // 2026-09-20, Lino, with screenshots: "die kommentare
                // müssten doch links bündig sein?! werden aber irgendwie
                // fast in der mitte dargestellt" — root cause was
                // commentListContent's VStack having no minHeight given to
                // this ScrollView either: with topLayerHeight (the video,
                // deliberately fixed/maxed — see videoSize's own doc
                // comment, MUST NOT shrink) plus commentBar's keyboard
                // padding both eating into this VStack's remaining space,
                // a plain `.frame(maxHeight: .infinity)` can get squeezed
                // toward 0pt on a small phone with the keyboard open,
                // leaving nothing to actually scroll/tap even though the
                // comments themselves are still there. `minHeight`
                // guarantees at least ~2 comment rows stay usable no
                // matter how tight it gets — the video's own size/position
                // is untouched either way, this only ever affects the
                // space already left over for the comment list.
                .frame(minHeight: 120, maxHeight: .infinity)
                .scrollDismissesKeyboard(.immediately)
                .background(.black.opacity(0.5))
                commentBar
                    .padding(.bottom, keyboardHeight)
                    .animation(.easeOut(duration: 0.25), value: keyboardHeight)
            }

            // Keyboard-IMMUNE layer: handlebar/topBar/video/error. Pinned
            // to the top of the outer ZStack, which itself always spans
            // the exact full screen — this layer's own proposed size
            // never changes for any reason, keyboard included.
            VStack(spacing: 0) {
                // Small handlebar (2026-07-21, #284: "a small handlebar
                // shows at the top") — a purely visual affordance for the
                // swipe-down-to-close gesture below, same idea as a
                // native iOS sheet's own grabber.
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                topBar
                // 2026-09-20 — full screen width now (was inset 12pt each
                // side), per "so gross wie möglich (bildschirmbreite)" —
                // maximizes the video's size within its fixed 16:9 ratio.
                if let player {
                    VideoPlayer(player: player)
                        // 2026-09-20 (3rd round) — hardcoded frame, not
                        // `.aspectRatio(.fit)`, see `videoSize`'s own doc
                        // comment on the struct for why.
                        .frame(width: videoSize.width, height: videoSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .padding(.top, 8)
                        // 2026-09-20, Lino: "die kommentar funktion soll IMMER
                        // geöffnet sein unter dem Video (unter den Buttons)...
                        // die video grösse soll sich dabei NICHT ändern" — the
                        // comment list/bar below are no longer a toggled
                        // overlay (see controlCluster/commentListOverlay's own
                        // doc comments), so there's nothing left to "reveal"
                        // via a swipe up. Swipe DOWN to close is unchanged.
                        .gesture(
                            DragGesture(minimumDistance: 30)
                                .onEnded { value in
                                    let v = value.translation.height
                                    let h = value.translation.width
                                    guard abs(v) > abs(h) * 1.5, v > 80 else { return }
                                    dismiss()
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
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.red.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 12)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { topLayerHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, newValue in topLayerHeight = newValue }
                }
            )
        }
        // 2026-09-20 (5th round), Lino, still emphatic: "das video wird in
        // der ios app immer noch nach oben geschoben... das video darf
        // sich NIE VERSCHIEBEN!!!" — found the actual bug in round 4's own
        // code: `.ignoresSafeArea(.keyboard)` was applied only to the
        // INNER "rest" VStack, not to this outer ZStack itself. That meant
        // the ZStack's OWN proposed size (from whatever presents it — the
        // fullScreenCover) could still shrink for the keyboard, and BOTH
        // children — including the supposedly "immune" video layer — got
        // proposed that smaller size regardless of being a separate ZStack
        // child; being a separate layer only stops SIBLINGS from pushing
        // each other, it does nothing about the shared PARENT shrinking.
        // Moved here, to the true outermost container, so the keyboard
        // categorically cannot change what size ANYTHING in this screen is
        // proposed — the video layer's own manual keyboard-response
        // (commentBar's `keyboardHeight` padding, still inside the inner
        // VStack) is unaffected by this, those are two independent
        // mechanisms, not in tension with each other.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbar {
            // 2026-09-20, Lino: "man muss die tastatur aber auch wieder
            // schliessen können wenn sie mal geöffnet wurde" — explicit,
            // always-visible way to dismiss it (return-to-send doesn't
            // count as "closing without sending").
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(language.t("common.done")) { commentFieldFocused = false }
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
            subscribeToKeyboard()
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
            if let fetchedMe = try? await APIClient.shared.me() {
                me = fetchedMe
                if authorName.isEmpty { authorName = fetchedMe.name ?? fetchedMe.email }
            }
        }
        .onDisappear {
            player?.pause()
            unsubscribeFromKeyboard()
        }
        .preferredColorScheme(.dark)
    }

    /// 2026-09-20 — raw `UIResponder` keyboard notifications instead of
    /// any SwiftUI-native keyboard-avoidance mechanism, deliberately: see
    /// `keyboardHeight`'s own doc comment for why the implicit approach
    /// was the actual bug. `keyboardWillChangeFrameNotification` alone
    /// covers both show AND hide (the frame's `origin.y` lands at/beyond
    /// the screen height when hidden, giving `max(0, ...)` a clean 0) —
    /// no separate will-hide observer needed.
    private func subscribeToKeyboard() {
        guard keyboardObserver == nil else { return }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIScreen.main.bounds.height
            keyboardHeight = max(0, screenHeight - frame.origin.y)
        }
    }

    private func unsubscribeFromKeyboard() {
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
        keyboardObserver = nil
    }

    private var topBar: some View {
        HStack {
            closeButton
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom)
        // 2026-08-09, Lino: "den X Button ein wenig weiter runter nehmen" —
        // was the default symmetric `.padding()` (~16pt), sitting right
        // under the handlebar; nudged down a bit further.
        .padding(.top, 22)
    }

    /// 2026-08-06, Lino: "können wir da den x button schöner machen um das
    /// video zu schliessen?" — was a flat two-tone `xmark.circle.fill`
    /// glyph; swapped for a frosted-glass circular backdrop (same material
    /// AVKit's own transport-bar chrome uses) with a plain bold xmark
    /// centered inside, closer to how native fullscreen media viewers
    /// (Photos, Camera) style their own close buttons.
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

    /// 2026-07-26 — bottom-trailing custom row: "Teilen" (share) button on
    /// the left, comment button on the right/outer corner ("Display share
    /// button soll links neben den Volumen button... Kommentar soll nach
    /// rechts unten"), a little spacing between them.
    private var controlCluster: some View {
        HStack(spacing: 14) {
            saveFrameButton
            videoDownloadButton
            commentButton
        }
    }

    /// 2026-07-27, Lino: pause on a frame you like, tap this to save that
    /// exact frame to Photos — same "pause first, capture what's showing"
    /// intent as web's downloadCurrentFrame in VideoReviewModal.tsx, just
    /// via Photos instead of a browser download. Also pauses on tap itself
    /// (same as commentButton above) so the frame can't drift mid-capture
    /// if the user taps while still playing.
    /// 2026-08-09, Lino: "das symbol für den thumbnail download button ist
    /// nicht klar genug... muss selbsterklärend sein" — a bare
    /// "square.and.arrow.down" (generic "download something") is
    /// indistinguishable at a glance from videoDownloadButton right next
    /// to it. Rather than guessing at an unverifiable exotic SF Symbol name
    /// with no compiler to check it (this button's own prior doc comment
    /// already flagged that exact risk), the fix is a small caption label
    /// under the icon — "photo"/"video" are both long-stable, definitely-
    /// real SF Symbols, and the text removes any remaining ambiguity
    /// regardless of icon recognition.
    private var saveFrameButton: some View {
        Button {
            Task { await saveCurrentFrame() }
        } label: {
            VStack(spacing: 2) {
                if savingFrame {
                    ProgressView().tint(.white)
                } else if frameJustSaved {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                } else {
                    // 2026-09-20, Lino: "weiss man nicht was die buttons
                    // Bild und Video machen.. irgendwie muss da ein
                    // download symbol hin" — the "photo"/"video" glyph +
                    // caption alone still read as generic media icons, not
                    // as a download action. A small "arrow.down.circle.fill"
                    // badge (both real, long-stable SF Symbols) pinned to
                    // the corner makes the download intent unambiguous
                    // without guessing at an exotic combined symbol name.
                    Image(systemName: "photo")
                        .font(.system(size: 16, weight: .semibold))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white, .blue)
                                .offset(x: 7, y: 7)
                        }
                }
                if !savingFrame {
                    Text(language.t("videoPlayerSheet.saveFrameShort"))
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(savingFrame)
        .accessibilityLabel(language.t("videoPlayerSheet.saveFrame"))
    }

    /// 2026-08-09, Lino: "es braucht noch einen video download button" —
    /// downloads the full video (not just the current frame) to Photos,
    /// same permission/flow shape as saveFrameButton, backed by
    /// downloadVideo() below.
    private var videoDownloadButton: some View {
        Button {
            Task { await downloadVideo() }
        } label: {
            VStack(spacing: 2) {
                if downloadingVideo {
                    ProgressView().tint(.white)
                } else if videoJustSaved {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                } else {
                    // 2026-09-20 — same download badge as saveFrameButton
                    // above, same reasoning.
                    Image(systemName: "video")
                        .font(.system(size: 16, weight: .semibold))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white, .blue)
                                .offset(x: 7, y: 7)
                        }
                }
                if !downloadingVideo {
                    Text(language.t("videoPlayerSheet.saveVideoShort"))
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(downloadingVideo)
        .accessibilityLabel(language.t("videoPlayerSheet.saveVideo"))
    }

    /// 2026-07-26 — replaces the old broken long-press: an always-tappable
    /// button that pauses playback (so the timestamp a new comment lands
    /// on doesn't keep drifting while typing, same intent the long-press
    /// originally had).
    /// 2026-09-20 — the comment list/bar are no longer a toggled panel
    /// this button opens (see body's own doc comment, always visible
    /// below the video now) — tapping just pauses and jumps focus straight
    /// to the input field, a quick "reply now" shortcut instead of a
    /// show/hide action.
    private var commentButton: some View {
        Button {
            player?.pause()
            commentFieldFocused = true
        } label: {
            // 2026-08-09, Lino: "abgeschlossene kommentare sollen nicht auf
            // dem Player gezählt werden (nur offene kommentare sollen als
            // zahl gezeigt/gezählt werden)" — was comments.count (every
            // comment regardless of resolved status).
            Label("\(comments.filter { !$0.resolved }.count)", systemImage: "bubble.left.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .accessibilityLabel(language.t("videoPlayerSheet.comments"))
    }

    /// 2026-09-20 — was `commentListOverlay`: owned its own ScrollView +
    /// fixed `maxHeight: 180` + rounded card. Now just the plain content —
    /// `body`'s own ScrollView (the flexible region between the buttons
    /// and the bottom-pinned input bar) wraps it instead, so it can
    /// actually grow/shrink with whatever space the keyboard leaves rather
    /// than being capped at a fixed height.
    private var commentListContent: some View {
        // 2026-09-20, Lino, with screenshots: comment rows showed up
        // floating near the horizontal center instead of flush against
        // the left edge. `VStack(alignment: .leading)`'s `alignment` only
        // governs how ITS OWN children line up relative to EACH OTHER
        // inside the VStack's own (content-hugging) width — it says
        // nothing about where the VStack itself sits inside its parent.
        // Since this VStack lives directly inside a `ScrollView` (see
        // body above) and comments are short, it hugged a narrow width
        // and the ScrollView then centered that narrow block within the
        // full-width scroll area (a ScrollView centers a narrower-than-
        // viewport child by default) — exactly the "shifted toward the
        // middle" look in the screenshots. `.frame(maxWidth: .infinity,
        // alignment: .leading)` forces the VStack itself to claim the
        // ScrollView's FULL width, so its children's `.leading` alignment
        // now has the whole width to actually align against.
        VStack(alignment: .leading, spacing: 8) {
            // 2026-09-20 — was closable (a chevron button here cleared
            // showCommentPanel); the panel is now always open (see
            // body's own doc comment), so there's nothing left to
            // close — just a plain section label.
            Text(language.t("videoPlayerSheet.comments"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            if comments.isEmpty {
                Text(language.t("videoPlayerSheet.noComments"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(comments.sorted(by: { ($0.timestampSeconds ?? -1) < ($1.timestampSeconds ?? -1) })) { comment in
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

                        if let ts = comment.timestampSeconds {
                            Button {
                                player?.seek(to: CMTime(seconds: ts, preferredTimescale: 600))
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(timeLabel(ts))
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(comment.authorName).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                                        // 2026-09-20, Lino: "lange kommentare die über 2 zeilen
                                        // gehen werden zentriert dargestellt" — VStack(alignment:
                                        // .leading) only positions this Text's WHOLE bounding box
                                        // against its siblings (the author name above it); it says
                                        // nothing about how a SINGLE Text's own wrapped lines align
                                        // relative to EACH OTHER once it spans multiple lines —
                                        // Text centers those by default unless told otherwise. Same
                                        // family of bug as commentListContent's own VStack fix
                                        // above, one level deeper.
                                        Text(comment.comment)
                                            .font(.caption)
                                            .foregroundStyle(comment.resolved ? .white.opacity(0.5) : .white)
                                            .strikethrough(comment.resolved)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                            }
                        } else {
                            // 2026-08-07 — a system notice (e.g. the
                            // subtitle-correction "Info" comment) has no
                            // timestamp to seek to (nil server-side, not
                            // pinned to a moment) — plain text instead of
                            // the seek Button above, same shape otherwise.
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(comment.authorName).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                                    // Same multi-line-centering fix as the timestamped branch above.
                                    Text(comment.comment)
                                        .font(.caption)
                                        .foregroundStyle(comment.resolved ? .white.opacity(0.5) : .white)
                                        .strikethrough(comment.resolved)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 2026-08-09, Lino: "können wir hier einfach den avatar neben dem
    /// kommentareingabefeld anzeigen anstatt den namen" — replaces the
    /// small editable name TextField with the signed-in user's own
    /// MemberAvatar (same component TeamSheet/PostproductionListView use
    /// elsewhere). `authorName` itself is unchanged underneath (still
    /// auto-filled from `me` in the .task above, still what postComment()
    /// actually sends) — this is purely a visual swap, not a behavior
    /// change, so there's no longer a way to override the name inline here.
    private var commentBar: some View {
        HStack(spacing: 8) {
            if let me {
                MemberAvatar(name: me.name, email: me.email, userId: me.id, avatarUrl: me.avatarUrl, size: 34)
            }
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
            // 2026-09-20 — used to also close the (then-toggled) comment
            // panel here; it's always open now, nothing to close.
            // 2026-08-05, Lino: "spielt das video automatisch wieder ab,
            // das ist falsch, man soll wieder auf das video klicken" —
            // used to auto-resume here; now stays paused, same as
            // finishing typing without sending would leave it.
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

    /// 2026-08-09, Lino: "es braucht noch einen video download button" —
    /// downloads the full video file (not just the current frame, see
    /// saveCurrentFrame above) to Photos. Same permission gate/flow shape
    /// as saveCurrentFrame; `creationRequestForAssetFromVideo(atFileURL:)`
    /// is the video counterpart of that function's own
    /// `creationRequestForAsset(from: UIImage)` — both real, long-stable
    /// Photos APIs (iOS 9+). Downloads to a plain temp file first (Photos
    /// needs a real file URL, not a stream) and cleans it up either way.
    private func downloadVideo() async {
        guard let urlString = version.playbackUrl, let remoteURL = URL(string: urlString), !downloadingVideo else { return }
        downloadingVideo = true
        defer { downloadingVideo = false }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                errorMessage = language.t("videoPlayerSheet.photoLibraryDenied")
                return
            }
            let (downloadedURL, _) = try await URLSession.shared.download(from: remoteURL)
            try FileManager.default.moveItem(at: downloadedURL, to: tmpURL)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tmpURL)
            }
            videoJustSaved = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            videoJustSaved = false
        } catch {
            errorMessage = language.t("videoPlayerSheet.videoSaveFailed")
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
