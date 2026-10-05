import AppKit
import MetalKit
import OSCCore

/// The single-line composer: committed text, a caret (UTF-16 offset, as AppKit's text
/// input APIs count), the IME's in-progress composition, and mention autocomplete.
struct InputLine {
    private(set) var text = ""
    private(set) var caret = 0
    var marked = ""
    private(set) var completions: [String] = []
    var completionIndex = 0

    private var caretIndex: String.Index { String.Index(utf16Offset: caret, in: text) }
    var textBeforeCaret: String { String(text[..<caretIndex]) }
    var textAfterCaret: String { String(text[caretIndex...]) }

    mutating func insert(_ s: String) {
        let clean = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        text.insert(contentsOf: clean, at: caretIndex)
        caret += clean.utf16.count
    }

    mutating func deleteBackward() {
        guard caretIndex > text.startIndex else { return }
        let start = text.index(before: caretIndex)   // a whole grapheme, so emoji delete cleanly
        text.removeSubrange(start..<caretIndex)
        caret = start.utf16Offset(in: text)
    }

    mutating func deleteForward() {
        guard caretIndex < text.endIndex else { return }
        text.removeSubrange(caretIndex..<text.index(after: caretIndex))
    }

    mutating func move(_ delta: Int) {
        if delta < 0, caretIndex > text.startIndex { caret = text.index(before: caretIndex).utf16Offset(in: text) }
        if delta > 0, caretIndex < text.endIndex { caret = text.index(after: caretIndex).utf16Offset(in: text) }
    }

    mutating func moveToStart() { caret = 0 }
    mutating func moveToEnd() { caret = text.utf16.count }

    mutating func clear() {
        text = ""
        caret = 0
        marked = ""
        completions = []
    }

    /// `@partial` right before the caret, at the start or after whitespace.
    private var mentionQuery: (range: Range<String.Index>, prefix: String)? {
        let before = text[..<caretIndex]
        guard let at = before.lastIndex(of: "@") else { return nil }
        let prefix = before[before.index(after: at)...]
        guard !prefix.contains(where: \.isWhitespace) else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        return (at..<caretIndex, String(prefix))
    }

    mutating func updateCompletions(labels: [String]) {
        guard let query = mentionQuery else {
            completions = []
            return
        }
        let p = query.prefix.lowercased()
        completions = Array(labels.filter { $0.lowercased().hasPrefix(p) }.sorted().prefix(5))
        completionIndex = min(completionIndex, max(0, completions.count - 1))
    }

    /// True while the typed `@prefix` isn't already exactly one of the suggestions.
    var wantsCompletion: Bool {
        guard let query = mentionQuery, !completions.isEmpty else { return false }
        return !completions.contains(query.prefix)
    }

    mutating func acceptCompletion() {
        guard let query = mentionQuery, completions.indices.contains(completionIndex) else { return }
        let replacement = "@" + completions[completionIndex] + " "
        text.replaceSubrange(query.range, with: replacement)
        caret = query.range.lowerBound.utf16Offset(in: text) + replacement.utf16.count
        completions = []
    }

    mutating func cycleCompletion(_ delta: Int) {
        guard !completions.isEmpty else { return }
        completionIndex = (completionIndex + delta + completions.count) % completions.count
    }
}

/// Owns input: typing (via the text input system, so IME and the emoji picker work),
/// orbit/zoom, and message selection. The renderer reads `input` every frame.
final class PhosphorView: MTKView, NSTextInputClient {
    weak var renderer: Renderer?
    var controller: ChatController?
    private(set) var input = InputLine()

    override var acceptsFirstResponder: Bool { true }

    // MARK: mouse

    override func mouseDragged(with event: NSEvent) {
        renderer?.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        renderer?.camera.zoom(by: Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
        } else {
            interpretKeyEvents([event])
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        input.insert(s)
        refreshCompletions()
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if input.wantsCompletion {
                input.acceptCompletion()
            } else if let controller {
                controller.submit(input.text, labels: labelsToFingerprints())
                input.clear()
            }
        case #selector(insertTab(_:)):
            input.acceptCompletion()
        case #selector(deleteBackward(_:)): input.deleteBackward()
        case #selector(deleteForward(_:)): input.deleteForward()
        case #selector(moveLeft(_:)): input.move(-1)
        case #selector(moveRight(_:)): input.move(1)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)): input.moveToStart()
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)): input.moveToEnd()
        case #selector(moveUp(_:)):
            if input.completions.isEmpty { controller?.moveFocus(-1) } else { input.cycleCompletion(-1) }
        case #selector(moveDown(_:)):
            if input.completions.isEmpty { controller?.moveFocus(1) } else { input.cycleCompletion(1) }
        case #selector(cancelOperation(_:)):
            if !input.completions.isEmpty {
                input.updateCompletions(labels: [])
            } else if controller?.focus != nil {
                controller?.moveFocus(nil)
            } else {
                input.clear()
            }
            return
        default:
            return
        }
        refreshCompletions()
    }

    private func refreshCompletions() {
        let me = controller?.me
        input.updateCompletions(labels: labelsToFingerprints().filter { $0.value != me }.map(\.key))
    }

    /// Tripcode label → fingerprint for everyone in view; labels are unique by construction.
    private func labelsToFingerprints() -> [String: String] {
        var map: [String: String] = [:]
        for (fp, label) in controller?.state?.labels ?? [:] { map[label] = fp }
        return map
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        input.marked = ""
        input.insert((string as? NSAttributedString)?.string ?? string as? String ?? "")
        refreshCompletions()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        input.marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    }

    func unmarkText() {
        input.insert(input.marked)
        input.marked = ""
    }

    func selectedRange() -> NSRange { NSRange(location: input.caret, length: 0) }

    func markedRange() -> NSRange {
        input.marked.isEmpty ? NSRange(location: NSNotFound, length: 0)
                             : NSRange(location: input.caret, length: input.marked.utf16.count)
    }

    func hasMarkedText() -> Bool { !input.marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the IME candidate window goes: just above the input box.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = NSRect(x: bounds.width * 0.06 + 40, y: bounds.height * 0.07 + 34, width: 1, height: 18)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
