import AppKit
import WhiskrKit

/// The editor's text view (TextKit 2): plain text, no smart quotes or spelling, the find bar, and a
/// code editor's keys: Return keeps the indentation (one level more after an opening bracket), Tab and
/// ⇧Tab indent and outdent a selection of lines, Backspace in leading spaces removes one level, a
/// closing bracket on an empty line steps back. Brackets and quotes close themselves and wrap a selection,
/// as the language's configuration says (VS Code's rules, `AutoClosing`); the Editor menu moves, copies
/// and deletes lines. The line the cursor is on is tinted; indent guides, the bracket pair at the cursor
/// and the other occurrences of its word are drawn under the text (`EditorDecorations`).
final class CodeTextView: NSTextView {
    weak var document: FileDocument?
    /// Go to Line (⌘L, ⌃G) asks the page to show its field.
    var onGoToLine: (() -> Void)?
    private lazy var decorations = EditorDecorations(textView: self)
    /// Closings the editor added as their openings were typed, while the cursor stays inside the pair.
    private var addedClosings = AutoClosing.Added()

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        // No checking of any kind runs over code: AppKit's text checker otherwise re-reads every paragraph
        // whose look changes (a comment opened above thousands of lines held the main thread for a second).
        enabledTextCheckingTypes = 0
        inlinePredictionType = .no
        smartInsertDeleteEnabled = false
        usesAdaptiveColorMappingForDarkAppearance = false
        allowsCharacterPickerTouchBarItem = false
        textContainerInset = NSSize(width: 6, height: 10)
        drawsBackground = true
        setAccessibilityRoleDescription(String(localized: "editor", comment: "Accessibility: the role of the code editor"))
    }

    required init?(coder: NSCoder) {
        fatalError("CodeTextView is created in code")
    }

    // MARK: Look

    /// The theme's colours and the editor's font, again whenever either changes.
    func applyStyle() {
        let style = EditorStyle.shared
        let variant = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance))
        backgroundColor = Palette.nsColor(variant.terminal.background)
        insertionPointColor = Palette.nsColor(variant.editor[.cursor])
        selectedTextAttributes = [.backgroundColor: Palette.nsColor(variant.editor[.selection])]
        typingAttributes = style.baseAttributes(tabWidth: document?.tabWidth ?? EditorPreferences.shared.tabWidth)
        font = style.font
        needsDisplay = true
    }

    /// The tint of the cursor's line (`EditorColorKey.lineHighlight`).
    private var currentLineColor: NSColor {
        Palette.nsColor(ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance)).editor[.lineHighlight])
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let line = currentLineRect(), line.intersects(rect) {
            currentLineColor.setFill()
            line.fill()
        }
        decorations.draw(in: rect)
    }

    /// The whole width of the line fragment holding the cursor, while nothing is selected.
    func currentLineRect() -> NSRect? {
        guard selectedRange().length == 0, let manager = textLayoutManager, let storage = textContentStorage,
              let location = storage.location(storage.documentRange.location, offsetBy: selectedRange().location) else { return nil }
        var rect: NSRect?
        manager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = frame
            return false
        }
        guard let frame = rect else { return nil }
        let height = max(frame.height, (font?.boundingRectForFont.height ?? 16))
        return NSRect(x: 0, y: frame.minY + textContainerOrigin.y, width: bounds.width, height: height)
    }

    private var lastLineRect: NSRect?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        followGuardedLine()
        // The tint moves with the cursor: the old line and the new one are redrawn.
        if let lastLineRect { setNeedsDisplay(lastLineRect) }
        lastLineRect = currentLineRect()
        if let lastLineRect { setNeedsDisplay(lastLineRect) }
        guard !stillSelecting else { return }
        addedClosings.keep(inside: selectedRange())
        decorations.selectionChanged()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = enclosingScrollView?.contentView else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func scrolled() { decorations.scrolled() }

    /// In a line kept from being edited (`FileDocument.guardedLine`) the view is not editable, so there is no
    /// caret: AppKit places a caret by reading its whole line, a minified file's 2 MB on every layout. Text
    /// can still be selected and copied there; the rest of the file is edited as usual.
    func followGuardedLine() {
        let editable = !(document?.isInGuardedLine(selectedRange().location) ?? false)
        if isEditable != editable { isEditable = editable }
    }

    /// Every change of the text, typed or not, passes here first: the closings the editor added move with
    /// it (or are forgotten), and what is drawn under the text is found again.
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        // A line too long to edit smoothly stays as it is until Edit Anyway (the page's bar says so).
        if replacementStrings != nil, document?.blocksEdit(of: affectedRanges.map(\.rangeValue)) == true { return false }
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else { return false }
        // No strings: only attributes change.
        guard let replacementStrings else { return true }
        for (index, value) in affectedRanges.enumerated().reversed() {
            let replacement = index < replacementStrings.count ? (replacementStrings[index] as NSString).length : 0
            addedClosings.edited(value.rangeValue, replacementLength: replacement)
        }
        decorations.textChanged()
        return true
    }

    // MARK: Keys

    private var indentUnit: String { document?.indentation.unit ?? "    " }
    private var language: CodeLanguage { document?.language ?? .plainText }
    /// The text itself, not a copy (`string` bridges the storage's whole text into a new String).
    var nsText: NSString { textStorage?.mutableString ?? NSString() }

    /// The range of whole lines the selection touches (a selection ending at a line's start leaves that
    /// line out), without the last line's "\n".
    private var selectedLineRange: NSRange {
        let selection = selectedRange()
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, nsText.character(at: end - 1) == 0x0A { end -= 1 }
        let start = nsText.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let last = nsText.lineRange(for: NSRange(location: max(start, end), length: 0))
        var upper = NSMaxRange(last)
        if upper > start, upper <= nsText.length, upper > 0, nsText.character(at: upper - 1) == 0x0A { upper -= 1 }
        return NSRange(location: start, length: max(0, upper - start))
    }

    /// Replaces whole lines, undoably, keeping them selected.
    private func replaceLines(_ transform: ([String]) -> [String]) {
        let range = selectedLineRange
        let lines = nsText.substring(with: range).components(separatedBy: "\n")
        let replaced = transform(lines).joined(separator: "\n")
        guard replaced != nsText.substring(with: range) else { return }
        insertText(replaced, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: (replaced as NSString).length))
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let lineStart = nsText.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = nsText.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        var lineEnd = 0, contentsEnd = 0
        nsText.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: NSMaxRange(selection), length: 0))
        let after = nsText.substring(with: NSRange(location: NSMaxRange(selection), length: max(0, min(contentsEnd - NSMaxRange(selection), 1000))))
        let previousLine = lineStart > 0 ? nsText.substring(with: nsText.lineRange(for: NSRange(location: lineStart - 1, length: 0))).trimmingCharacters(in: .newlines) : nil
        let indent = TextEdits.newlineIndent(after: before, following: after, previousLine: previousLine, unit: indentUnit, configuration: languageConfiguration)
        let next = NSMaxRange(selection) < nsText.length ? nsText.character(at: NSMaxRange(selection)) : 0
        let opener = before.trimmingCharacters(in: .whitespaces).last
        // Between a pair of brackets: the closing one goes on a line of its own below the cursor.
        if let opener, let close = Self.pairs[opener], next == close.utf16.first {
            let base = String(before.prefix { $0 == " " || $0 == "\t" })
            insertText("\n" + indent + "\n" + base, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1 + (indent as NSString).length, length: 0))
            return
        }
        insertText("\n" + indent, replacementRange: selection)
    }

    private static let pairs: [Character: String] = ["{": "}", "[": "]", "(": ")"]

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, nsText.substring(with: selection).contains("\n") {
            return shiftRight(sender)
        }
        if document?.indentation.usesTabs == true { return insertText("\t", replacementRange: selection) }
        // Spaces to the next tab stop.
        let lineStart = nsText.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let column = selection.location - lineStart
        let width = max(1, document?.indentation.width ?? 4)
        insertText(String(repeating: " ", count: width - column % width), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) { shiftLeft(sender) }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        // Between an empty pair the editor closed: both go.
        if selection.length == 0, selectedRanges.count == 1, selection.location > 0,
           AutoClosing.deletesPair(at: place(for: selection, findingContext: false), pairs: pairs) {
            return insertText("", replacementRange: NSRange(location: selection.location - 1, length: 2))
        }
        guard selection.length == 0, document?.indentation.usesTabs == false, selection.location > 0 else { return super.deleteBackward(sender) }
        let lineStart = nsText.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let leading = nsText.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let width = max(1, document?.indentation.width ?? 4)
        // In the leading spaces, Backspace takes back one level of indentation.
        guard !leading.isEmpty, leading.allSatisfy({ $0 == " " }) else { return super.deleteBackward(sender) }
        let remove = leading.count % width == 0 ? width : leading.count % width
        insertText("", replacementRange: NSRange(location: selection.location - remove, length: remove))
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Typed (not pasted or put in place by a command): pairs close, are typed over, wrap a selection.
        if let text = string as? String, replacementRange.location == NSNotFound, !hasMarkedText(), selectedRanges.count == 1,
           typeAroundPairs(text) { return }
        // A closing bracket typed on a line of only indentation lines up with the line that opened it.
        if let text = string as? String, ["}", "]", ")"].contains(text), replacementRange.location == NSNotFound || replacementRange.length == 0 {
            let selection = selectedRange()
            let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
            let before = nsText.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
            if !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }), !language.isPlainText, language != .markdown {
                let outdented = TextEdits.outdentedForClosing(before, unit: indentUnit)
                super.insertText(outdented + text, replacementRange: NSRange(location: lineRange.location, length: before.utf16.count))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Pairs

    /// The language's brackets and quotes (its VS Code language configuration).
    var pairs: EditingPairs { languageConfiguration.editingPairs }

    /// The language's configuration says blocks go by indentation (`folding.offSide`: Python, YAML): a blank
    /// line before a dedent belongs to the block below (indent guides).
    var indentsOffSide: Bool { languageConfiguration.offSide }

    private var languageConfiguration: LanguageConfiguration { language.configuration }

    /// The cursor's surroundings in its line (at most a thousand characters each way: a minified file's one
    /// line is not copied on every key), and, if asked, the token it is in.
    private func place(for selection: NSRange, findingContext: Bool = true) -> AutoClosing.Place {
        let reach = 1000
        let lineStart = lineStart(of: selection.location)
        var lineEnd = 0, contentsEnd = 0
        nsText.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: NSMaxRange(selection), length: 0))
        let from = max(lineStart, selection.location - reach), to = min(contentsEnd, NSMaxRange(selection) + reach)
        return AutoClosing.Place(before: nsText.substring(with: NSRange(location: from, length: selection.location - from)),
                                 after: nsText.substring(with: NSRange(location: NSMaxRange(selection), length: to - NSMaxRange(selection))),
                                 selected: nsText.substring(with: selection),
                                 closerWasAdded: addedClosings.isClosing(at: NSMaxRange(selection)),
                                 context: findingContext ? typingContext(at: selection.location) : .code)
    }

    /// Where the line holding `offset` starts (from the document's line index, not by scanning back).
    private func lineStart(of offset: Int) -> Int {
        guard let document, document.lines.lineCount > 0 else { return nsText.lineRange(for: NSRange(location: offset, length: 0)).location }
        return document.lines.starts[document.lines.line(at: offset)]
    }

    /// Lines longer than this are not lexed to decide whether a pair closes (VS Code's "cheap to tokenize"):
    /// in a minified file's one line, an opening is just typed.
    private static let longestLexedLine = 10_000

    /// Typing `text` next to a pair: steps over a closing the editor added, closes an opening, or wraps the
    /// selection. False when it is just typed.
    private func typeAroundPairs(_ text: String) -> Bool {
        let pairs = pairs
        let selection = selectedRange()
        let matters = pairs.autoClosingPairs.contains { $0.open.hasSuffix(text) || $0.close == text }
            || (selection.length > 0 && pairs.surroundingPairs.contains { $0.open == text })
        guard matters else { return false }
        let line = document.map { $0.lines.range(ofLine: $0.lines.line(at: selection.location)) }
        let isLong = (line?.count ?? 0) > Self.longestLexedLine
        guard let typing = AutoClosing.typing(text, at: place(for: selection, findingContext: !isLong), pairs: pairs) else { return false }
        if isLong, case .close = typing { return false }
        let length = (text as NSString).length
        switch typing {
        case .overtype:
            setSelectedRange(NSRange(location: selection.location + length, length: 0))
        case .close(let open, let close):
            super.insertText(open + close, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + length, length: 0))
            addedClosings.add(open: selection.location, close: selection.location + (open as NSString).length)
        case .surround(let open, let close):
            let inner = nsText.substring(with: selection)
            super.insertText(open + inner + close, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + (open as NSString).length, length: selection.length))
        }
        return true
    }

    /// What each character is in, by its line's tokens (looked up once per line): code, a string or a
    /// comment.
    func tokenContexts() -> (Int) -> TokenContext {
        guard let document else { return { _ in .code } }
        var lines: [Int: (start: Int, tokens: [SyntaxToken])] = [:]
        return { offset in
            let line = document.lines.line(at: offset)
            // A line too long to lex at every rest of the cursor counts as code.
            let range = document.lines.range(ofLine: line)
            let entry = lines[line] ?? (range.lowerBound, range.count > Self.longestLexedLine ? [] : document.tokens(line: line))
            lines[line] = entry
            return Self.token(at: offset - entry.start, in: entry.tokens).map { document.context(of: $0.scopes) } ?? .code
        }
    }

    /// Where typing at `offset` lands: in the token of the character before it, unless that token is a
    /// string or block comment that closed right there (`"abc"|` is code again).
    private func typingContext(at offset: Int) -> TokenContext {
        guard let document, document.lines.lineCount > 0 else { return .code }
        let line = document.lines.line(at: offset)
        let column = offset - document.lines.starts[line]
        let tokens = document.tokens(line: line)
        guard column > 0 else { return Self.token(at: 0, in: tokens).map { document.context(of: $0.scopes) } ?? .code }
        guard let token = Self.token(at: column - 1, in: tokens) else { return .code }
        let context = document.context(of: token.scopes)
        guard token.range.upperBound == column, context != .code else { return context }
        // The grammar's closing quote (`punctuation.definition.string.end`), or a whole string token.
        if context == .string, token.scopes.scope.hasPrefix("punctuation.definition.string.end") { return .code }
        let text = (document.lineText(line) as NSString).substring(with: NSRange(location: token.range.lowerBound, length: token.range.count))
        if context == .string, text.count >= 2, let quote = text.first, "\"'`".contains(quote), text.last == quote { return .code }
        if context == .comment, let block = languageConfiguration.blockComment, text.hasSuffix(block.close) { return .code }
        return context
    }

    /// The token covering a column, found by halves (a minified line has thousands).
    private static func token(at column: Int, in tokens: [SyntaxToken]) -> SyntaxToken? {
        var low = 0, high = tokens.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = tokens[middle].range
            if range.contains(column) { return tokens[middle] }
            if column < range.lowerBound { high = middle - 1 } else { low = middle + 1 }
        }
        return nil
    }

    // MARK: Lines

    /// Editor › Move Line Up (⌥↑) and Move Line Down (⌥↓), as in VS Code and Cursor.
    @objc func moveLineUp(_ sender: Any?) { apply(LineMoves.move(nsText, selection: selectedRange(), up: true), named: String(localized: "Move Line Up")) }
    @objc func moveLineDown(_ sender: Any?) { apply(LineMoves.move(nsText, selection: selectedRange(), up: false), named: String(localized: "Move Line Down")) }
    /// Editor › Copy Line Up (⇧⌥↑) and Copy Line Down (⇧⌥↓).
    @objc func copyLineUp(_ sender: Any?) { apply(LineMoves.copy(nsText, selection: selectedRange(), up: true), named: String(localized: "Copy Line Up")) }
    @objc func copyLineDown(_ sender: Any?) { apply(LineMoves.copy(nsText, selection: selectedRange(), up: false), named: String(localized: "Copy Line Down")) }
    /// Editor › Delete Line (⇧⌘K).
    @objc func deleteLine(_ sender: Any?) { apply(LineMoves.delete(nsText, selection: selectedRange()), named: String(localized: "Delete Line")) }

    /// One replacement, undoable under its command's name, then the selection it leaves.
    private func apply(_ edit: LineMoves.Edit?, named name: String) {
        guard let edit, shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        breakUndoCoalescing()
        textStorage?.replaceCharacters(in: edit.range, with: edit.text)
        didChangeText()
        undoManager?.setActionName(name)
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    /// Editor › Go to Bracket (⇧⌘\): from a bracket to its partner, else to the closing bracket of the pair
    /// the cursor is in (VS Code's Go to Bracket).
    @objc func goToMatchingBracket(_ sender: Any?) {
        let offset = selectedRange().location
        let context = tokenContexts()
        let brackets = pairs.brackets
        let target: Int
        if let match = BracketMatching.match(in: nsText, at: offset, brackets: brackets, isCode: { context($0) == .code }) {
            target = offset == match.open || offset == match.open + 1 ? match.close : match.open
        } else if let enclosing = BracketMatching.enclosing(in: nsText, at: offset, brackets: brackets, isCode: { context($0) == .code }) {
            target = enclosing.close
        } else {
            return
        }
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    // MARK: Editor menu

    @objc func toggleComment(_ sender: Any?) {
        if let marker = languageConfiguration.lineComment {
            replaceLines { TextEdits.toggleLineComment($0, marker: marker) }
        } else if let block = languageConfiguration.blockComment {
            replaceLines { lines in TextEdits.toggleBlockComment(lines.joined(separator: "\n"), open: block.open, close: block.close).components(separatedBy: "\n") }
        }
    }

    @objc func shiftRight(_ sender: Any?) {
        replaceLines { TextEdits.shiftRight($0, unit: indentUnit) }
    }

    @objc func shiftLeft(_ sender: Any?) {
        replaceLines { TextEdits.shiftLeft($0, width: document?.indentation.width ?? 4) }
    }

    @objc func goToLine(_ sender: Any?) { onGoToLine?() }

    /// Puts the cursor at the start of a line (1-based) and column, and scrolls it to the upper third.
    func show(line: Int, column: Int? = nil) {
        guard let document else { return }
        let index = min(max(line - 1, 0), document.lines.lineCount - 1)
        let range = document.lines.range(ofLine: index)
        let offset = range.lowerBound + min(max((column ?? 1) - 1, 0), range.count)
        setSelectedRange(NSRange(location: offset, length: 0))
        scrollToLine(index)
    }

    /// Scrolls so a line sits a third of the way down.
    func scrollToLine(_ index: Int) {
        guard let document, let manager = textLayoutManager, let storage = textContentStorage, let clip = enclosingScrollView?.contentView else { return }
        let offset = document.lines.starts[min(index, document.lines.lineCount - 1)]
        guard let location = storage.location(storage.documentRange.location, offsetBy: offset) else { return }
        manager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = manager.textLayoutFragment(for: location) else { return }
        let y = fragment.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.height / 3
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, y)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleComment(_:)):
            return languageConfiguration.lineComment != nil || languageConfiguration.blockComment != nil
        case #selector(shiftRight(_:)), #selector(shiftLeft(_:)), #selector(goToLine(_:)):
            return true
        case #selector(moveLineUp(_:)), #selector(moveLineDown(_:)), #selector(copyLineUp(_:)), #selector(copyLineDown(_:)), #selector(deleteLine(_:)):
            return isEditable
        case #selector(goToMatchingBracket(_:)):
            return !pairs.brackets.isEmpty
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
