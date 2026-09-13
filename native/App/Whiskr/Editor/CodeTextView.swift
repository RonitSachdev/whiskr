import AppKit
import WhiskrKit

/// The editor's text view (TextKit 2): plain text, no smart quotes or spelling, the find bar, and a
/// code editor's keys: Return keeps the indentation (one level more after an opening bracket), Tab and
/// ⇧Tab indent and outdent a selection of lines, Backspace in leading spaces removes one level, a
/// closing bracket on an empty line steps back, ⌃G goes to a line. The line the cursor is on is tinted.
final class CodeTextView: NSTextView {
    weak var document: FileDocument?
    /// Go to Line (⌘L, ⌃G) asks the page to show its field.
    var onGoToLine: (() -> Void)?

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
        let colors = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance)).terminal
        backgroundColor = Palette.nsColor(colors.background)
        insertionPointColor = Palette.nsColor(colors.cursor)
        selectedTextAttributes = [.backgroundColor: Palette.nsColor(colors.selection)]
        typingAttributes = style.baseAttributes
        font = style.font
        needsDisplay = true
    }

    /// The tint of the cursor's line: the foreground at a whisper.
    private var currentLineColor: NSColor {
        let colors = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance)).terminal
        return Palette.nsColor(colors.background.mixed(with: colors.foreground, colors.isDark ? 0.06 : 0.045))
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let line = currentLineRect(), line.intersects(rect) else { return }
        currentLineColor.setFill()
        line.fill()
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
        // The tint moves with the cursor: the old line and the new one are redrawn.
        if let lastLineRect { setNeedsDisplay(lastLineRect) }
        lastLineRect = currentLineRect()
        if let lastLineRect { setNeedsDisplay(lastLineRect) }
    }

    // MARK: Keys

    private var indentUnit: String { document?.indentation.unit ?? "    " }
    private var language: SyntaxLanguage { document?.language ?? .plain }
    private var nsText: NSString { string as NSString }

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
        let indent = TextEdits.newlineIndent(after: before, unit: indentUnit, language: language)
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
        // A closing bracket typed on a line of only indentation lines up with the line that opened it.
        if let text = string as? String, ["}", "]", ")"].contains(text), replacementRange.location == NSNotFound || replacementRange.length == 0 {
            let selection = selectedRange()
            let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
            let before = nsText.substring(with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
            if !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }), language != .plain, language != .markdown {
                let outdented = TextEdits.outdentedForClosing(before, unit: indentUnit)
                super.insertText(outdented + text, replacementRange: NSRange(location: lineRange.location, length: before.utf16.count))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func keyDown(with event: NSEvent) {
        // ⌃G: Go to Line, as in many editors (Editor › Go to Line is ⌘L).
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == "g" {
            onGoToLine?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Editor menu

    @objc func toggleComment(_ sender: Any?) {
        if let marker = language.lineComment {
            replaceLines { TextEdits.toggleLineComment($0, marker: marker) }
        } else if let block = language.blockComment {
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
            return language.lineComment != nil || language.blockComment != nil
        case #selector(shiftRight(_:)), #selector(shiftLeft(_:)), #selector(goToLine(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
