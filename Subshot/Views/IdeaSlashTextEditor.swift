import SwiftUI
import UIKit

/// 2026-07-21, #277 — iOS port of the web app's RichTextEditor.tsx
/// slash-command state machine (see IdeaEditSheet's "Beschreibung"
/// section). Typing "/" at the top level offers Szene/Shot (🎬) or
/// Zwischenschritt (🔀); typing "/" again INSIDE one of those offers
/// Titel (📝, once per block) then Dialog (🗣️), one level deep only —
/// neither Dialog nor Titel supports its own nested "/". Each block
/// closes on a double-Enter (an Enter press on an already-blank line)
/// EXCEPT Titel, which is always exactly one line and closes on any
/// single Enter. A literal end-marker line ("-- end scene"/
/// "--- end dialog"/"--- end title") is left behind when a block closes —
/// this is what the small grey divider line actually IS (see
/// IdeaSlashEditorController.styledText), matching the backend's own
/// three regexes exactly (`_IDEA_SCENE_END_MARKER_RE` etc. in
/// app/main.py) so approve_idea can find block boundaries.
///
/// Deliberately simpler than the web version in a few ways:
/// - State (which block/sub-block is open) is DERIVED FRESH from the text
///   on every keystroke by scanning backward from the cursor's line,
///   instead of mirrored in separate mutable flags that can drift out of
///   sync with the text (the exact bug class web's own
///   reopenEnclosingBlock/deriveOpenBlockFromContent fallback exists to
///   patch over) — there is exactly one source of truth here, so e.g. a
///   fresh remount or a deleted end-marker can never leave the state
///   machine confused about what's actually open.
/// - The slash-menu itself is a plain SwiftUI `.confirmationDialog` (see
///   IdeaEditSheet), not a floating popup positioned at the caret — no
///   caret-to-screen-coordinate math, a much smaller surface to get wrong
///   without a compiler on hand to check it.
/// - No Shift+Enter-stays-inside-the-block escape hatch (iOS's software
///   keyboard Return key carries no reliable shift-modifier signal the
///   way a hardware Enter/Shift+Enter combo does in a browser) and no
///   "click back into an already-closed block to reopen it" gesture —
///   both are web-only polish on top of the core open/close/nesting
///   machine this ticket asks to port, not part of it.
enum IdeaSlashOption: Identifiable, CaseIterable {
    case scene, intermediate, dialog, title
    var id: Self { self }

    var icon: String {
        switch self {
        case .scene: return "🎬"
        case .intermediate: return "🔀"
        case .dialog: return "🗣️"
        case .title: return "📝"
        }
    }

    var label: String {
        switch self {
        case .scene: return "Szene/Shot"
        case .intermediate: return "Zwischenschritt"
        case .dialog: return "Dialog"
        case .title: return "Titel"
        }
    }

    /// Full marker line text — MUST match the backend's
    /// `_IDEA_SCENE_MARKER`/`_IDEA_INTERMEDIATE_MARKER`/
    /// `_IDEA_DIALOG_MARKER`/`_IDEA_TITLE_MARKER` constants in
    /// app/main.py exactly, including the trailing colon.
    var markerLine: String { "\(icon) \(label):" }
}

/// Owns the live text plus the slash-menu's pending-options state
/// (surfaced to IdeaEditSheet's `.confirmationDialog`) and every bit of
/// the open/close/nesting logic — the UITextView wrapper below is a thin
/// UIKit shell around this, so the state machine itself stays plain,
/// testable-by-reading Swift with no UIKit-specific control flow mixed
/// into it beyond the small `apply` helper that actually pokes the
/// UITextView.
final class IdeaSlashEditorController: ObservableObject {
    @Published var text: String
    @Published var pendingSlashOptions: [IdeaSlashOption]?
    weak var textView: UITextView?
    /// Fires after every committed change (typed characters AND this
    /// controller's own marker/end-marker insertions) — IdeaEditSheet
    /// hooks this to its existing scheduleAutosave().
    var onTextChanged: (() -> Void)?

    private var slashTriggerRange: NSRange?

    init(initialText: String) {
        self.text = initialText
    }

    // MARK: - marker/regex constants (must match app/main.py exactly)

    static let sceneMarkerLine = IdeaSlashOption.scene.markerLine
    static let intermediateMarkerLine = IdeaSlashOption.intermediate.markerLine
    static let dialogMarkerLine = IdeaSlashOption.dialog.markerLine
    static let titleMarkerLine = IdeaSlashOption.title.markerLine
    static let dialogIcon = IdeaSlashOption.dialog.icon
    static let sceneEndMarker = "-- end scene"
    static let dialogEndMarker = "--- end dialog"
    static let titleEndMarker = "--- end title"

    private static func endRegex(_ word: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try — pattern is a fixed literal, never user input.
        try! NSRegularExpression(pattern: "^-+\\s*end\\s*\(word)$", options: [.caseInsensitive])
    }
    private static let sceneEndRE = endRegex("scene")
    private static let dialogEndRE = endRegex("dialog")
    private static let titleEndRE = endRegex("title")

    private static func isEndMarker(_ line: String, _ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    // MARK: - line helpers

    private func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Index into `lines(of:)`'s result for the line containing UTF-16
    /// offset `location`.
    private func lineIndex(in ns: NSString, at location: Int) -> Int {
        let clamped = min(max(location, 0), ns.length)
        let before = ns.substring(to: clamped)
        return before.components(separatedBy: "\n").count - 1
    }

    private func trimmed(_ s: Substring) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    private func isLineEmpty(_ s: Substring) -> Bool { trimmed(s).isEmpty }

    /// Dialog continuation lines are pre-seeded with just the icon prefix
    /// (matches web's isDialogLineEmpty) — that alone must ALSO count as
    /// "blank", or Dialog could never close (every fresh continuation
    /// line would otherwise look like real content forever).
    private func isDialogLineEmpty(_ s: Substring) -> Bool {
        let t = trimmed(s)
        return t.isEmpty || t == Self.dialogIcon
    }

    /// Scans lines strictly BEFORE `idx` backward for the nearest
    /// enclosing Szene/Zwischenschritt block and whether a Dialog
    /// sub-block is still open within it. Mirrors the web app's
    /// deriveOpenBlockFromContent, minus Titel — Titel is always exactly
    /// the one line right after "📝 Titel:", so it never needs a
    /// multi-line backward scan (see isTitleOpen below).
    private func blockState(lines: [Substring], beforeIndex idx: Int) -> (sceneOpen: Bool, dialogOpen: Bool) {
        var i = idx - 1
        var dialogOpen = false
        var dialogDecided = false
        while i >= 0 {
            let t = trimmed(lines[i])
            if !dialogDecided {
                if Self.isEndMarker(t, Self.dialogEndRE) {
                    dialogDecided = true
                } else if t == Self.dialogMarkerLine {
                    dialogOpen = true
                    dialogDecided = true
                }
            }
            if Self.isEndMarker(t, Self.sceneEndRE) { return (false, false) }
            if t == Self.sceneMarkerLine || t == Self.intermediateMarkerLine { return (true, dialogOpen) }
            i -= 1
        }
        return (false, false)
    }

    /// Titel mode only ever lasts exactly one line — the one right after
    /// "📝 Titel:", before the very next Enter — so this is just an
    /// adjacency check, not a scan.
    private func isTitleOpen(lines: [Substring], atIndex idx: Int) -> Bool {
        idx > 0 && trimmed(lines[idx - 1]) == Self.titleMarkerLine
    }

    /// Has the scene block enclosing `idx` already used its one allowed
    /// Titel? Scans back to the enclosing scene marker (or falls out to
    /// "not inside a scene at all") looking for a titleMarkerLine or a
    /// title-end-marker line.
    private func hasUsedTitle(lines: [Substring], beforeIndex idx: Int) -> Bool {
        var i = idx - 1
        while i >= 0 {
            let t = trimmed(lines[i])
            if t == Self.titleMarkerLine { return true }
            if Self.isEndMarker(t, Self.titleEndRE) { return true }
            if Self.isEndMarker(t, Self.sceneEndRE) { return false }
            if t == Self.sceneMarkerLine || t == Self.intermediateMarkerLine { return false }
            i -= 1
        }
        return false
    }

    // MARK: - UITextViewDelegate entry point

    /// Returns true to let the native edit proceed unmodified, or false
    /// if this function already applied its OWN edit instead (marker
    /// insertion, end-marker insertion, dialog continuation line) — every
    /// branch that returns false has already called `apply(...)` itself.
    func shouldChange(textView: UITextView, range: NSRange, replacementText insert: String) -> Bool {
        let full = textView.text ?? ""
        let ns = full as NSString
        let currentLines = lines(of: full)
        let idx = min(lineIndex(in: ns, at: range.location), max(currentLines.count - 1, 0))

        // "/" trigger — only at start-of-line-or-after-whitespace (not
        // mid-word, so e.g. "10/07" never triggers it), and never while
        // inside Dialog/Titel (neither supports its own nested slash).
        if insert == "/" {
            let charBefore: String? = range.location > 0
                ? ns.substring(with: NSRange(location: range.location - 1, length: 1))
                : nil
            let triggerOK = charBefore == nil || charBefore == "\n" || charBefore?.first?.isWhitespace == true
            guard triggerOK, !isTitleOpen(lines: currentLines, atIndex: idx) else { return true }
            let state = blockState(lines: currentLines, beforeIndex: idx)
            guard !state.dialogOpen else { return true }
            let options: [IdeaSlashOption] = state.sceneOpen
                ? (hasUsedTitle(lines: currentLines, beforeIndex: idx) ? [.dialog] : [.title, .dialog])
                : [.scene, .intermediate]
            // Captures the "/" itself (about to be inserted, length 1) so
            // confirmSlash can delete exactly that character later —
            // mirrors web's own "delete the triggering / immediately
            // before the caret" step in confirmSlash.
            slashTriggerRange = NSRange(location: range.location, length: 1)
            pendingSlashOptions = options
            return true
        }

        guard insert == "\n" else { return true }
        guard idx < currentLines.count else { return true }
        let currentLine = currentLines[idx]

        // Titel: ANY Enter ends it immediately (single line, never
        // double — unlike Dialog/Szene below).
        if isTitleOpen(lines: currentLines, atIndex: idx) {
            closeTitle(textView: textView, at: range)
            return false
        }

        let state = blockState(lines: currentLines, beforeIndex: idx)
        if state.dialogOpen {
            if isDialogLineEmpty(currentLine) {
                closeDialog(textView: textView, at: range)
            } else {
                insertDialogContinuation(textView: textView, at: range)
            }
            return false
        }
        if state.sceneOpen {
            if isLineEmpty(currentLine) {
                closeScene(textView: textView, at: range)
                return false
            }
            return true // plain Enter, an ordinary new content line inside the still-open scene
        }
        return true
    }

    // MARK: - confirmationDialog entry points (called from IdeaEditSheet)

    func confirm(_ option: IdeaSlashOption) {
        guard let textView, let triggerRange = slashTriggerRange else { return }
        pendingSlashOptions = nil
        slashTriggerRange = nil
        switch option {
        case .scene, .intermediate:
            let insertion = "\(option.markerLine)\n"
            apply(insertion, in: textView, range: triggerRange, cursorOffset: (insertion as NSString).length)
        case .dialog:
            let seed = "\(Self.dialogIcon) "
            let insertion = "\(option.markerLine)\n\(seed)"
            apply(insertion, in: textView, range: triggerRange, cursorOffset: (insertion as NSString).length)
        case .title:
            let insertion = "\(option.markerLine)\n"
            apply(insertion, in: textView, range: triggerRange, cursorOffset: (insertion as NSString).length)
        }
    }

    /// Escape/"Abbrechen" — matches web's own Escape handling: just closes
    /// the menu, the already-typed "/" stays as plain text.
    func cancelSlash() {
        pendingSlashOptions = nil
        slashTriggerRange = nil
    }

    // MARK: - close/continuation mutation helpers

    /// Replaces the blank line's would-be-just-"\n" Enter with the end
    /// marker plus a fresh blank line right after it for continued
    /// typing — same shape a plain Enter would have left behind, just
    /// with the cap inserted where an empty line already was.
    private func closeScene(textView: UITextView, at range: NSRange) {
        let insertion = "\(Self.sceneEndMarker)\n\n"
        apply(insertion, in: textView, range: range, cursorOffset: (insertion as NSString).length)
    }

    private func closeDialog(textView: UITextView, at range: NSRange) {
        let insertion = "\(Self.dialogEndMarker)\n\n"
        apply(insertion, in: textView, range: range, cursorOffset: (insertion as NSString).length)
    }

    /// Unlike closeScene/closeDialog, the Titel content line is NOT
    /// assumed blank — it keeps whatever was typed; the end marker is
    /// inserted as an EXTRA line after it instead of replacing anything.
    private func closeTitle(textView: UITextView, at range: NSRange) {
        let insertion = "\n\(Self.titleEndMarker)\n"
        apply(insertion, in: textView, range: range, cursorOffset: (insertion as NSString).length)
    }

    /// The "next dialogue line" gesture: plain Enter on a non-empty line
    /// while Dialog is still open. Each continuation line is re-prefixed
    /// with just the icon (not the full "Dialog:" label, which only the
    /// header line carries), so every dialogue entry stays visibly
    /// marked, not just the first one.
    private func insertDialogContinuation(textView: UITextView, at range: NSRange) {
        let insertion = "\n\(Self.dialogIcon) "
        apply(insertion, in: textView, range: range, cursorOffset: (insertion as NSString).length)
    }

    /// Replaces `range` in `textView` with `replacement`, moves the caret
    /// to `range.location + cursorOffset`, and pushes the new text back
    /// into `text`. Restyles immediately (not just on the next real
    /// keystroke) — assigning `.text`/`.attributedText` programmatically,
    /// unlike an actual user keystroke, never fires `textViewDidChange`
    /// on its own, so this is the only place these particular edits get
    /// re-styled at all.
    private func apply(_ replacement: String, in textView: UITextView, range: NSRange, cursorOffset: Int) {
        let full = textView.text ?? ""
        guard let swiftRange = Range(range, in: full) else { return }
        var new = full
        new.replaceSubrange(swiftRange, with: replacement)
        text = new
        textView.attributedText = styledText(baseFont: textView.font ?? .preferredFont(forTextStyle: .subheadline))
        textView.selectedRange = NSRange(location: range.location + cursorOffset, length: 0)
        onTextChanged?()
    }

    // MARK: - styling (small grey end-marker lines)

    /// 2026-07-21, #277 — end-marker lines render smaller/greyed-out, same
    /// intent as web's own `<code>` + scoped CSS treatment (visibly a
    /// system divider, not regular editable-looking text). Every other
    /// line keeps `baseFont`/`.label`.
    func styledText(baseFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: UIColor.label]
        let markerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(10, baseFont.pointSize - 4)),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let allLines = text.components(separatedBy: "\n")
        for (i, line) in allLines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            let isMarker = Self.isEndMarker(t, Self.sceneEndRE)
                || Self.isEndMarker(t, Self.dialogEndRE)
                || Self.isEndMarker(t, Self.titleEndRE)
            result.append(NSAttributedString(string: line, attributes: isMarker ? markerAttrs : bodyAttrs))
            if i < allLines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
            }
        }
        return result
    }
}

/// Thin UIViewRepresentable shell — every bit of the slash-command state
/// machine lives in IdeaSlashEditorController above, this just wires a
/// plain UITextView's delegate callbacks into it (a plain SwiftUI
/// TextEditor has no per-keystroke interception point, so a UIKit
/// representable is the only way to detect "Enter was just pressed on
/// THIS line" reliably).
struct IdeaSlashTextEditor: UIViewRepresentable {
    @ObservedObject var controller: IdeaSlashEditorController
    var isEditable: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .subheadline)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.isEditable = isEditable
        controller.textView = tv
        tv.attributedText = controller.styledText(baseFont: tv.font ?? .preferredFont(forTextStyle: .subheadline))
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.isEditable = isEditable
        guard uiView.text != controller.text else { return }
        let selected = uiView.selectedRange
        uiView.attributedText = controller.styledText(baseFont: uiView.font ?? .preferredFont(forTextStyle: .subheadline))
        let maxLocation = (uiView.text as NSString).length
        uiView.selectedRange = NSRange(location: min(selected.location, maxLocation), length: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: IdeaSlashEditorController
        init(controller: IdeaSlashEditorController) { self.controller = controller }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            controller.shouldChange(textView: textView, range: range, replacementText: text)
        }

        func textViewDidChange(_ textView: UITextView) {
            controller.text = textView.text
            let selected = textView.selectedRange
            textView.attributedText = controller.styledText(baseFont: textView.font ?? .preferredFont(forTextStyle: .subheadline))
            textView.selectedRange = selected
            controller.onTextChanged?()
        }
    }
}
