import SwiftUI
import UIKit
import Combine

/// 2026-08-09 (#36) — Lino: "hier werden die / funktionen in der
/// szenenübersicht nicht angenommen sondern verschwinden einfach, fixen"
/// then, on clarification, confirmed the actual ask: "Die Ideen-Slash-
/// Funktionen (Dialog/Titel/Beschreibung) sollen NEU auch beim Bearbeiten
/// einer Szenen-Beschreibung verfügbar sein." — this is a genuinely NEW
/// feature (confirmed: neither web's SceneEditModal nor iOS's
/// SceneEditSheet ever had any "/" handling for a Scene's description
/// field before this), not a regression.
///
/// Deliberately a SEPARATE, smaller controller from
/// IdeaSlashEditorController (IdeaSlashTextEditor.swift) rather than a
/// shared/generalized one, even though the two overlap a lot: a Scene's
/// description has no enclosing "🎬 Szene/Shot:" marker to scan back to —
/// the whole text implicitly already IS inside one scene, so there's no
/// Szene/Zwischenschritt option to offer at all, and the Dialog/Titel/
/// Beschreibung open/close scan needs to run to the very top of the text
/// instead of stopping at a scene boundary that will never exist here.
/// Retrofitting that as a mode flag onto the Idea controller's already
/// delicately-tuned backward-scan (blockState/hasUsedTitle/
/// hasUsedDescription all specifically rely on finding a scene/end-scene
/// marker to know when to stop) risked a subtle regression there with no
/// compiler on hand to catch it — a second, smaller state machine scoped
/// to exactly what this needs is the lower-risk shape. Marker vocabulary/
/// end-caps/close gestures (double-Enter closes Dialog/Beschreibung,
/// single Enter closes Titel) are copied verbatim from IdeaSlashTextEditor
/// so a Scene description and an Idea description read identically once
/// approve_idea/whatever future scene-side parser touches them.
enum SceneSlashOption: Identifiable, CaseIterable {
    case dialog, title, description
    var id: Self { self }

    var icon: String {
        switch self {
        case .dialog: return "🗣️"
        case .title: return "📝"
        case .description: return "📄"
        }
    }

    var label: String {
        switch self {
        case .dialog: return "Dialog"
        case .title: return "Titel"
        case .description: return "Beschreibung"
        }
    }

    /// Same marker vocabulary as IdeaSlashOption.markerLine — kept
    /// textually identical (not just visually) in case a later backend
    /// parser wants to treat a Scene description's blocks the same way
    /// _parse_idea_scene_markers already treats an Idea's.
    var markerLine: String { "\(icon) \(label):" }
}

final class SceneSlashEditorController: ObservableObject {
    @Published var text: String
    @Published var pendingSlashOptions: [SceneSlashOption]?
    @Published var slashAnchorPoint: CGPoint?
    weak var textView: UITextView?
    var onTextChanged: (() -> Void)?

    private var slashTriggerRange: NSRange?

    init(initialText: String) {
        self.text = initialText
    }

    // MARK: - marker/regex constants (identical vocabulary to IdeaSlashTextEditor.swift)

    static let dialogMarkerLine = SceneSlashOption.dialog.markerLine
    static let titleMarkerLine = SceneSlashOption.title.markerLine
    static let descriptionMarkerLine = SceneSlashOption.description.markerLine
    static let dialogIcon = SceneSlashOption.dialog.icon
    static let dialogEndMarker = "--- end dialog"
    static let titleEndMarker = "--- end title"
    static let descriptionEndMarker = "--- end description"

    private static func endRegex(_ word: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try — pattern is a fixed literal, never user input.
        try! NSRegularExpression(pattern: "^-+\\s*end\\s*\(word)$", options: [.caseInsensitive])
    }
    private static let dialogEndRE = endRegex("dialog")
    private static let titleEndRE = endRegex("title")
    private static let descriptionEndRE = endRegex("description")

    private static func isEndMarker(_ line: String, _ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    // MARK: - line helpers

    private func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private func lineIndex(in ns: NSString, at location: Int) -> Int {
        let clamped = min(max(location, 0), ns.length)
        let before = ns.substring(to: clamped)
        return before.components(separatedBy: "\n").count - 1
    }

    private func trimmed(_ s: Substring) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    private func isLineEmpty(_ s: Substring) -> Bool { trimmed(s).isEmpty }

    private func fullLineRange(in ns: NSString, at location: Int) -> NSRange {
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        var length = lineRange.length
        if length > 0, ns.character(at: lineRange.location + length - 1) == 10 {
            length -= 1
        }
        return NSRange(location: lineRange.location, length: length)
    }

    private func isDialogLineEmpty(_ s: Substring) -> Bool {
        let t = trimmed(s)
        return t.isEmpty || t == Self.dialogIcon
    }

    /// Scans lines strictly BEFORE `idx` backward to the very TOP of the
    /// text (no enclosing scene marker to stop at, unlike
    /// IdeaSlashEditorController.blockState — the whole description
    /// implicitly is one scene already) for whether a Dialog or
    /// Beschreibung block is still open.
    private func openBlocks(lines: [Substring], beforeIndex idx: Int) -> (dialogOpen: Bool, descriptionOpen: Bool) {
        var i = idx - 1
        var dialogOpen = false, dialogDecided = false
        var descriptionOpen = false, descriptionDecided = false
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
            if !descriptionDecided {
                if Self.isEndMarker(t, Self.descriptionEndRE) {
                    descriptionDecided = true
                } else if t == Self.descriptionMarkerLine {
                    descriptionOpen = true
                    descriptionDecided = true
                }
            }
            if dialogDecided && descriptionDecided { break }
            i -= 1
        }
        return (dialogOpen, descriptionOpen)
    }

    private func isTitleOpen(lines: [Substring], atIndex idx: Int) -> Bool {
        idx > 0 && trimmed(lines[idx - 1]) == Self.titleMarkerLine
    }

    private func hasUsedTitle(lines: [Substring], beforeIndex idx: Int) -> Bool {
        var i = idx - 1
        while i >= 0 {
            let t = trimmed(lines[i])
            if t == Self.titleMarkerLine || Self.isEndMarker(t, Self.titleEndRE) { return true }
            i -= 1
        }
        return false
    }

    private func hasUsedDescription(lines: [Substring], beforeIndex idx: Int) -> Bool {
        var i = idx - 1
        while i >= 0 {
            let t = trimmed(lines[i])
            if t == Self.descriptionMarkerLine || Self.isEndMarker(t, Self.descriptionEndRE) { return true }
            i -= 1
        }
        return false
    }

    // MARK: - UITextViewDelegate entry point

    func shouldChange(textView: UITextView, range: NSRange, replacementText insert: String) -> Bool {
        let full = textView.text ?? ""
        let ns = full as NSString
        let currentLines = lines(of: full)
        let idx = min(lineIndex(in: ns, at: range.location), max(currentLines.count - 1, 0))

        if insert == "/" {
            let charBefore: String? = range.location > 0
                ? ns.substring(with: NSRange(location: range.location - 1, length: 1))
                : nil
            let triggerOK = charBefore == nil || charBefore == "\n" || charBefore?.first?.isWhitespace == true
            guard triggerOK, !isTitleOpen(lines: currentLines, atIndex: idx) else { return true }
            let open = openBlocks(lines: currentLines, beforeIndex: idx)
            guard !open.dialogOpen, !open.descriptionOpen else { return true }
            var options: [SceneSlashOption] = []
            if !hasUsedDescription(lines: currentLines, beforeIndex: idx) { options.append(.description) }
            if !hasUsedTitle(lines: currentLines, beforeIndex: idx) { options.append(.title) }
            options.append(.dialog)

            slashTriggerRange = NSRange(location: range.location, length: 1)
            if let uiPos = textView.position(from: textView.beginningOfDocument, offset: range.location) {
                let caretRect = textView.caretRect(for: uiPos)
                let windowRect = textView.convert(caretRect, to: nil)
                slashAnchorPoint = CGPoint(x: windowRect.midX, y: windowRect.minY)
            }
            pendingSlashOptions = options
            return true
        }

        guard insert == "\n" else { return true }
        guard idx < currentLines.count else { return true }
        let currentLine = currentLines[idx]

        if isTitleOpen(lines: currentLines, atIndex: idx) {
            closeTitle(textView: textView, at: range)
            return false
        }

        let open = openBlocks(lines: currentLines, beforeIndex: idx)
        let lineRange = fullLineRange(in: ns, at: range.location)
        if open.descriptionOpen {
            if isLineEmpty(currentLine) {
                closeDescription(textView: textView, at: lineRange)
                return false
            }
            return true
        }
        if open.dialogOpen {
            if isDialogLineEmpty(currentLine) {
                closeDialog(textView: textView, at: lineRange)
            } else {
                insertDialogContinuation(textView: textView, at: range)
            }
            return false
        }
        return true
    }

    // MARK: - confirmationDialog/popover entry points

    func confirm(_ option: SceneSlashOption) {
        guard let textView, let triggerRange = slashTriggerRange else { return }
        pendingSlashOptions = nil
        slashTriggerRange = nil
        slashAnchorPoint = nil
        switch option {
        case .dialog:
            let seed = "\(Self.dialogIcon) "
            let insertion = "\(option.markerLine)\n\(seed)"
            apply(insertion, in: textView, range: triggerRange, cursorOffset: (insertion as NSString).length)
        case .title, .description:
            let insertion = "\(option.markerLine)\n"
            apply(insertion, in: textView, range: triggerRange, cursorOffset: (insertion as NSString).length)
        }
    }

    func cancelSlash() {
        pendingSlashOptions = nil
        slashTriggerRange = nil
        slashAnchorPoint = nil
    }

    // MARK: - close/continuation mutation helpers

    private func closeDialog(textView: UITextView, at range: NSRange) {
        let insertion = "\(Self.dialogEndMarker)\n\n"
        apply(insertion, in: textView, range: range, cursorOffset: (insertion as NSString).length)
    }

    private func closeDescription(textView: UITextView, at range: NSRange) {
        let insertion = "\(Self.descriptionEndMarker)\n\n"
        apply(insertion, in: textView, range: range, cursorOffset: (insertion as NSString).length)
    }

    private func closeTitle(textView: UITextView, at range: NSRange) {
        let insertion = "\n\(Self.titleEndMarker)\n"
        apply(insertion, in: textView, range: range, cursorOffset: (insertion as NSString).length)
    }

    private func insertDialogContinuation(textView: UITextView, at range: NSRange) {
        let insertion = "\n\(Self.dialogIcon) "
        apply(insertion, in: textView, range: range, cursorOffset: (insertion as NSString).length)
    }

    private func apply(_ replacement: String, in textView: UITextView, range: NSRange, cursorOffset: Int) {
        let full = textView.text ?? ""
        guard let swiftRange = Range(range, in: full) else { return }
        var new = full
        new.replaceSubrange(swiftRange, with: replacement)
        text = new
        textView.attributedText = styledText(baseFont: textView.font ?? .preferredFont(forTextStyle: .body))
        textView.selectedRange = NSRange(location: range.location + cursorOffset, length: 0)
        onTextChanged?()
    }

    // MARK: - styling (small grey end-marker lines, same treatment as IdeaSlashTextEditor)

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
            let isMarker = Self.isEndMarker(t, Self.dialogEndRE)
                || Self.isEndMarker(t, Self.titleEndRE)
                || Self.isEndMarker(t, Self.descriptionEndRE)
            result.append(NSAttributedString(string: line, attributes: isMarker ? markerAttrs : bodyAttrs))
            if i < allLines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
            }
        }
        return result
    }
}

/// Thin UIViewRepresentable shell, same shape as IdeaSlashTextEditor.
struct SceneSlashTextEditor: UIViewRepresentable {
    @ObservedObject var controller: SceneSlashEditorController
    var isEditable: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        // Scrollable + a fixed frame range (set at the call site), same
        // shape as IdeaSlashTextEditor — a plain UIViewRepresentable
        // UITextView doesn't auto-grow to fit content without extra
        // sizeThatFits plumbing (iOS 16+), which neither editor implements;
        // matching the ALREADY-WORKING pattern here rather than trying
        // untested auto-sizing behavior with no compiler to check it.
        tv.isScrollEnabled = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.isEditable = isEditable
        controller.textView = tv
        tv.attributedText = controller.styledText(baseFont: tv.font ?? .preferredFont(forTextStyle: .body))
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.isEditable = isEditable
        guard uiView.text != controller.text else { return }
        let selected = uiView.selectedRange
        uiView.attributedText = controller.styledText(baseFont: uiView.font ?? .preferredFont(forTextStyle: .body))
        let maxLocation = (uiView.text as NSString).length
        uiView.selectedRange = NSRange(location: min(selected.location, maxLocation), length: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: SceneSlashEditorController
        init(controller: SceneSlashEditorController) { self.controller = controller }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            controller.shouldChange(textView: textView, range: range, replacementText: text)
        }

        func textViewDidChange(_ textView: UITextView) {
            controller.text = textView.text
            let selected = textView.selectedRange
            textView.attributedText = controller.styledText(baseFont: textView.font ?? .preferredFont(forTextStyle: .body))
            textView.selectedRange = selected
            controller.onTextChanged?()
        }
    }
}
