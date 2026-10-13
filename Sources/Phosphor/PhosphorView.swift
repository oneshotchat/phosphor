import AppKit
import MetalKit
import OSCCore

/// The single-line composer: committed text, a caret (UTF-16 offset, as AppKit's text
/// input APIs count), the IME's in-progress composition, and autocomplete for mentions
/// and commands.
struct InputLine {
    enum CompletionKind { case mention, command, reaction }

    private(set) var text = ""
    private(set) var caret = 0
    var marked = ""
    private(set) var completions: [String] = []
    private(set) var completionKind = CompletionKind.mention
    /// What Tab cycles through after /react (the quick reactions) or /unreact (your own
    /// reactions on that message).
    private(set) var reactionOptions: [String] = Emoji.quickReactions.map(\.emoji)
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

    /// Where a quick reaction goes: after `/react ` (or `/react 12 `, or `/unreact `), at
    /// the end of the line, holding nothing yet or one of the quick reactions (so Tab can
    /// swap it for the next).
    private var reactionSpot: Range<String.Index>? {
        guard caretIndex == text.endIndex, text.hasPrefix("/react ") || text.hasPrefix("/unreact ") else { return nil }
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let last = words.removeLast()
        guard last.isEmpty || reactionOptions.contains(last),
              words.count == 1 || (words.count == 2 && Int(words[1]) != nil) else { return nil }
        return text.index(text.endIndex, offsetBy: -last.count)..<text.endIndex
    }

    /// The quick reaction in the line now, if any.
    private var currentReaction: Int? {
        reactionSpot.flatMap { spot in reactionOptions.firstIndex(of: String(text[spot])) }
    }

    /// Tab (⇧Tab back) after `/react `: puts the next quick reaction in the line, replacing
    /// the one there. Returns false if there's no reaction spot.
    mutating func cycleReaction(_ delta: Int) -> Bool {
        guard let spot = reactionSpot else { return false }
        let count = reactionOptions.count
        guard count > 0 else { return true }
        let next = currentReaction.map { ($0 + delta + count) % count } ?? (delta > 0 ? 0 : count - 1)
        let emoji = reactionOptions[next]
        text.replaceSubrange(spot, with: emoji)
        caret = text.utf16.count
        completionIndex = next
        return true
    }

    /// Turns a `:shortcode:` just typed (ending at the caret) into its emoji, in place.
    mutating func expandShortcode() {
        let before = textBeforeCaret
        guard before.hasSuffix(":"), let start = before.dropLast().lastIndex(of: ":") else { return }
        let code = String(before[start...])
        guard !code.contains(" "), case let emoji = Emoji.expand(code), emoji != code else { return }
        text.replaceSubrange(start..<caretIndex, with: emoji)
        caret = start.utf16Offset(in: text) + emoji.utf16.count
    }

    mutating func updateCompletions(labels: [String], commands: [String] = [], reactions: [String]? = nil) {
        reactionOptions = reactions ?? Emoji.quickReactions.map(\.emoji)
        if reactionSpot != nil {
            completionKind = .reaction
            completions = reactionOptions
            completionIndex = currentReaction ?? 0
        } else if let query = commandQuery {
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
        case .reaction: return reactionSpot.map { $0.isEmpty } ?? false     // Return with none yet takes 👍
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
        case .reaction:
            guard let spot = reactionSpot else { return }
            range = spot
            replacement = completions[completionIndex]
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
        } else if renderer.readingMode, renderer.readingScrollLimit > 0 {
            // Reading a message too tall for the screen: scroll through it.
            renderer.readingScroll -= dy * 0.03
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

    func clearInput() {
        input.clear()
    }

    /// Dev: puts text in the input as if typed (snapshots of the composer).
    func devType(_ text: String) {
        // A key at a time, as typing does, so shortcodes and suggestions behave the same.
        for ch in text { insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
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
            if controller?.contactPrompt != nil {
                // Answering a rename or remove prompt.
                controller?.answerContactPrompt(input.text, labels: labelsToFingerprints())
                if controller?.contactPrompt == nil { input.clear() }
            } else if input.text.isEmpty, controller?.showingContacts == true, controller?.contactsPage == 1,
                      controller?.selectedPlace != nil {
                // Return on one of a contact's rooms: go there.
                controller?.goToPlace()
            } else if input.text.isEmpty, let petname = controller?.startRename() {
                // Return on someone picked on a wall: name them, starting from their petname.
                input.insert(petname)
            } else if input.wantsCompletion {
                input.acceptCompletion()
            } else if let controller {
                controller.submit(input.text, labels: labelsToFingerprints())
                input.clear()
                if let next = controller.takePendingInput() { input.insert(next) }     // e.g. /side's ready-made @mention
            }
        // ⌥⏎ and ⌃⏎ also add a line, as in other Mac text fields.
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)):
            guard controller?.browser.isOpen != true else { return }
            input.insert("\n")
        case #selector(insertTab(_:)):
            if !input.cycleReaction(1) { input.acceptCompletion() }
        case #selector(insertBacktab(_:)):
            _ = input.cycleReaction(-1)
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
        case #selector(moveLeft(_:)) where controller?.showingContacts == true && input.text.isEmpty:
            controller?.pageContacts(-1)
        case #selector(moveRight(_:)) where controller?.showingContacts == true && input.text.isEmpty:
            controller?.pageContacts(1)
        // Otherwise the arrows move the caret (these must come after every wall's ←→).
        case #selector(moveLeft(_:)): input.move(-1)
        case #selector(moveRight(_:)): input.move(1)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)): input.moveToStart()
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)): input.moveToEnd()
        // On the contacts wall, ↑↓ pick someone; on their own wall, one of their rooms.
        case #selector(moveUp(_:)) where controller?.showingContacts == true && input.completions.isEmpty:
            if controller?.contactsPage == 1 { controller?.movePlaceSelection(-1) } else { controller?.moveContactSelection(-1) }
        case #selector(moveDown(_:)) where controller?.showingContacts == true && input.completions.isEmpty:
            if controller?.contactsPage == 1 { controller?.movePlaceSelection(1) } else { controller?.moveContactSelection(1) }
        // On the people wall, ↑↓ pick someone (when nothing's being completed).
        case #selector(moveUp(_:)) where controller?.showingRoomInfo == true && controller?.infoPage == 1 && input.completions.isEmpty:
            controller?.movePersonSelection(-1)
        case #selector(moveDown(_:)) where controller?.showingRoomInfo == true && controller?.infoPage == 1 && input.completions.isEmpty:
            controller?.movePersonSelection(1)
        case #selector(moveUp(_:)):
            // ↑↓ pick people or commands from a list; quick reactions are Tab's, so here
            // they still move between messages.
            if input.completions.isEmpty || input.completionKind == .reaction { controller?.moveFocus(-1) } else { input.cycleCompletion(-1) }
        case #selector(moveDown(_:)):
            if input.completions.isEmpty || input.completionKind == .reaction { controller?.moveFocus(1) } else { input.cycleCompletion(1) }
        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)):
            renderer?.camera.liftTarget += 8
        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)):
            renderer?.camera.liftTarget -= 8
        case #selector(cancelOperation(_:)):
            if controller?.contactPrompt != nil {
                controller?.contactPrompt = nil
                input.clear()
            } else if !input.completions.isEmpty {
                input.updateCompletions(labels: [])
            } else if controller?.help != nil {
                controller?.help = nil
            } else if controller?.showingContacts == true, controller?.selectedPlace != nil {
                controller?.selectedPlace = nil
            } else if controller?.showingContacts == true, controller?.contactsPage == 1 {
                controller?.pageContacts(-1)
            } else if controller?.showingContacts == true, controller?.selectedContact != nil {
                controller?.selectedContact = nil
            } else if controller?.showingContacts == true {
                controller?.showingContacts = false
            } else if controller?.showingRoomInfo == true, controller?.selectedPerson != nil {
                controller?.selectedPerson = nil
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
        controller?.inputEmpty = input.text.isEmpty
        if let browser = controller?.browser, browser.isOpen {
            browser.setQuery(input.text)      // in the browser, typing filters rooms
            return
        }
        if controller?.contactPrompt != nil { return input.updateCompletions(labels: []) }   // a petname, not a command or mention
        let me = controller?.me
        // After /unreact, Tab offers only the reactions you put on that message.
        var reactions: [String]?
        if input.text.hasPrefix("/unreact ") {
            let args = input.text.dropFirst("/unreact ".count).split(separator: " ").dropLast(input.text.hasSuffix(" ") ? 0 : 1)
            reactions = controller?.myReactions(args.joined(separator: " ")) ?? []
        }
        input.updateCompletions(labels: labelsToFingerprints().filter { $0.value != me }.map(\.key),
                                commands: Help.names(forOperator: controller?.isOperator ?? false), reactions: reactions)
    }

    /// Tripcode label → fingerprint for everyone in view; labels are unique by construction.
    private func labelsToFingerprints() -> [String: String] {
        var map: [String: String] = [:]
        for (fp, label) in controller?.state?.labels ?? [:] { map[label] = fp }
        return map
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        if controller?.contactPrompt?.isQuestion == true { return }     // a yes/no question: ⏎ or esc
        input.marked = ""
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        input.insert(typed)
        if typed == ":", controller?.contactPrompt == nil { input.expandShortcode() }    // :+1: → 👍, as you type
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
