import AppKit
import MetalKit
import OSCCore

/// The single-line composer: committed text, a caret (UTF-16 offset, as AppKit's text
/// input APIs count), the IME's in-progress composition, and autocomplete for mentions
/// and commands.
struct InputLine {
    enum CompletionKind { case mention, command }

    private(set) var text = ""
    private(set) var caret = 0
    var marked = ""
    private(set) var completions: [String] = []
    private(set) var completionKind = CompletionKind.mention
    var completionIndex = 0

    private var caretIndex: String.Index { String.Index(utf16Offset: caret, in: text) }
    var textBeforeCaret: String { String(text[..<caretIndex]) }
    var textAfterCaret: String { String(text[caretIndex...]) }

    /// Newlines are kept (messages may have several lines); \r isn't allowed in messages.
    mutating func insert(_ s: String) {
        let clean = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
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

    /// `/partial` while the caret is still in a line's first word.
    private var commandQuery: String? {
        let before = textBeforeCaret
        guard before.hasPrefix("/"), !before.contains(where: \.isWhitespace) else { return nil }
        return before.lowercased()
    }

    /// The command typed so far, once it's followed by a space (for its usage line).
    var typedCommand: String? {
        guard text.hasPrefix("/"), let space = text.firstIndex(where: \.isWhitespace) else { return nil }
        return text[..<space].lowercased()
    }

    mutating func updateCompletions(labels: [String], commands: [String] = []) {
        if let query = commandQuery {
            if completionKind != .command { completionIndex = 0 }
            completionKind = .command
            completions = commands.filter { $0.hasPrefix(query) }
        } else if let query = mentionQuery {
            if completionKind != .mention { completionIndex = 0 }
            completionKind = .mention
            let p = query.prefix.lowercased()
            completions = Array(labels.filter { $0.lowercased().hasPrefix(p) }.sorted().prefix(5))
        } else {
            completions = []
        }
        completionIndex = min(completionIndex, max(0, completions.count - 1))
    }

    /// True while what's typed isn't already exactly one of the suggestions.
    var wantsCompletion: Bool {
        guard !completions.isEmpty else { return false }
        switch completionKind {
        case .command: return commandQuery.map { !completions.contains($0) } ?? false
        case .mention: return mentionQuery.map { !completions.contains($0.prefix) } ?? false
        }
    }

    mutating func acceptCompletion() {
        guard completions.indices.contains(completionIndex) else { return }
        let range: Range<String.Index>
        let replacement: String
        switch completionKind {
        case .command:
            guard commandQuery != nil else { return }
            range = text.startIndex..<caretIndex
            replacement = completions[completionIndex] + " "
        case .mention:
            guard let query = mentionQuery else { return }
            range = query.range
            replacement = "@" + completions[completionIndex] + " "
        }
        text.replaceSubrange(range, with: replacement)
        caret = range.lowerBound.utf16Offset(in: text) + replacement.utf16.count
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

    /// Two-finger scroll flies up and down the wall (respecting natural scrolling), sideways
    /// orbits; with ⌥ it moves forward and back. Pinch also zooms.
    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        let unit: Float = event.hasPreciseScrollingDeltas ? 1 : 12   // mouse wheels report lines
        let dx = Float(event.scrollingDeltaX) * unit, dy = Float(event.scrollingDeltaY) * unit
        if event.modifierFlags.contains(.option) {
            renderer.camera.zoom(by: dy * 0.008)
        } else if abs(dx) > abs(dy) {
            renderer.camera.orbit(dx: dx, dy: 0)
        } else {
            renderer.readingMode = false
            renderer.camera.liftTarget += dy * 0.03
        }
    }

    override func magnify(with event: NSEvent) {
        renderer?.camera.zoom(by: Float(event.magnification))
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
        } else if isReturn, event.modifierFlags.contains(.shift), input.marked.isEmpty, controller?.browser.isOpen != true {
            // ⇧⏎: a new line in the message instead of sending it.
            input.insert("\n")
            refreshCompletions()
        } else {
            interpretKeyEvents([event])
        }
    }

    /// Dev: puts text in the input as if typed (snapshots of the composer).
    func devType(_ text: String) {
        input.insert(text)
        refreshCompletions()
    }

    /// Dev: presses Return (send, or the browser's join) or Tab (take the completion).
    func devPressReturn() { doCommand(by: #selector(insertNewline(_:))) }
    func devPressTab() { doCommand(by: #selector(insertTab(_:))) }

    /// ⌘L. The input line switches between chatting and filtering rooms.
    func toggleBrowser() {
        guard let browser = controller?.browser else { return }
        if browser.isOpen { browser.close() } else { browser.open() }
        input.clear()
    }

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        input.insert(s)
        refreshCompletions()
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)) where controller?.browser.isOpen == true:
            controller?.browser.submit(input.text)
            input.clear()
        case #selector(moveUp(_:)) where controller?.browser.isOpen == true:
            controller?.browser.move(-1)
        case #selector(moveDown(_:)) where controller?.browser.isOpen == true:
            controller?.browser.move(1)
        // The list runs left to right along the row in front, so ←/→ move through it too.
        case #selector(moveLeft(_:)) where controller?.browser.isOpen == true:
            controller?.browser.move(-1)
        case #selector(moveRight(_:)) where controller?.browser.isOpen == true:
            controller?.browser.move(1)
        case #selector(cancelOperation(_:)) where controller?.browser.isOpen == true:
            controller?.browser.cancel()
            input.clear()
            return
        case #selector(insertNewline(_:)):
            if input.wantsCompletion {
                input.acceptCompletion()
            } else if let controller {
                controller.submit(input.text, labels: labelsToFingerprints())
                input.clear()
            }
        // ⌥⏎ and ⌃⏎ also add a line, as in other Mac text fields.
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)):
            guard controller?.browser.isOpen != true else { return }
            input.insert("\n")
        case #selector(insertTab(_:)):
            input.acceptCompletion()
        case #selector(deleteBackward(_:)): input.deleteBackward()
        case #selector(deleteForward(_:)): input.deleteForward()
        // With help open and nothing typed, ←→ move between its walls.
        case #selector(moveLeft(_:)) where controller?.help != nil && input.text.isEmpty:
            controller?.pageHelp(-1)
        case #selector(moveRight(_:)) where controller?.help != nil && input.text.isEmpty:
            controller?.pageHelp(1)
        case #selector(moveLeft(_:)) where controller?.showingRoomInfo == true && input.text.isEmpty:
            controller?.pageInfo(-1)
        case #selector(moveRight(_:)) where controller?.showingRoomInfo == true && input.text.isEmpty:
            controller?.pageInfo(1)
        case #selector(moveLeft(_:)): input.move(-1)
        case #selector(moveRight(_:)): input.move(1)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)): input.moveToStart()
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)): input.moveToEnd()
        case #selector(moveUp(_:)):
            if input.completions.isEmpty { controller?.moveFocus(-1) } else { input.cycleCompletion(-1) }
        case #selector(moveDown(_:)):
            if input.completions.isEmpty { controller?.moveFocus(1) } else { input.cycleCompletion(1) }
        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)):
            renderer?.camera.liftTarget += 8
        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)):
            renderer?.camera.liftTarget -= 8
        case #selector(cancelOperation(_:)):
            if !input.completions.isEmpty {
                input.updateCompletions(labels: [])
            } else if controller?.help != nil {
                controller?.help = nil
            } else if controller?.showingRoomInfo == true {
                controller?.showingRoomInfo = false
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
        if let browser = controller?.browser, browser.isOpen {
            browser.setQuery(input.text)      // in the browser, typing filters rooms
            return
        }
        let me = controller?.me
        input.updateCompletions(labels: labelsToFingerprints().filter { $0.value != me }.map(\.key),
                                commands: Help.names(forOperator: controller?.isOperator ?? false))
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
