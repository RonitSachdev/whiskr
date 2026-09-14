import AppKit
import WhiskrKit

/// What the editor draws under its text besides the cursor's line, as VS Code does: indent guides (a thin
/// line at each level of indentation, the cursor's block's stronger), the bracket pair at the cursor, and
/// the other places the word at the cursor occurs. Each is worked out for the lines on screen only, after
/// the cursor rests (50 ms for brackets, 250 ms for words, VS Code's delays), and drawn in
/// `CodeTextView.drawBackground`, in the theme's `EditorColorKey` colours.
@MainActor
final class EditorDecorations {
    private unowned let textView: CodeTextView
    /// The other occurrences of the word at the cursor, on screen.
    private(set) var occurrences: [NSRange] = []
    private(set) var bracket: BracketMatching.Match?
    private var bracketWork: DispatchWorkItem?
    private var occurrencesWork: DispatchWorkItem?

    init(textView: CodeTextView) {
        self.textView = textView
    }

    // MARK: Following the editor

    /// The cursor moved (or a selection changed).
    func selectionChanged() {
        let selection = textView.selectedRange()
        // Still in the highlighted word: the highlights stay until the work below says otherwise.
        if !occurrences.contains(where: { NSLocationInRange(selection.location, $0) || NSMaxRange($0) == selection.location }) {
            setOccurrences([])
        }
        scheduleBracket()
        scheduleOccurrences()
        textView.setNeedsDisplay(textView.visibleRect)
    }

    /// The text changed: what was found is out of date at once, and found again once typing rests.
    func textChanged() {
        setOccurrences([])
        setBracket(nil)
        scheduleBracket()
        scheduleOccurrences()
        // Indentation may have changed: the guides on screen are drawn again.
        textView.setNeedsDisplay(textView.visibleRect)
    }

    /// Other lines came on screen: their occurrences are found once the scrolling rests.
    func scrolled() {
        scheduleOccurrences(after: 0.05)
    }

    private func scheduleBracket() {
        bracketWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setBracket(self?.findBracket()) }
        bracketWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func scheduleOccurrences(after delay: Double = 0.25) {
        occurrencesWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.occurrencesWork = nil
            self.setOccurrences(self.findOccurrences())
        }
        occurrencesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setOccurrences(_ ranges: [NSRange]) {
        guard ranges != occurrences else { return }
        for range in occurrences + ranges { invalidate(range) }
        occurrences = ranges
    }

    private func setBracket(_ match: BracketMatching.Match?) {
        guard match != bracket else { return }
        for old in [bracket, match].compactMap(\.self) {
            invalidate(NSRange(location: old.open, length: 1))
            invalidate(NSRange(location: old.close, length: 1))
        }
        bracket = match
    }

    private func invalidate(_ range: NSRange) {
        for rect in rects(for: range) { textView.setNeedsDisplay(rect.insetBy(dx: -1, dy: -1)) }
    }

    // MARK: Finding

    private func findBracket() -> BracketMatching.Match? {
        let selection = textView.selectedRange()
        guard selection.length == 0, textView.selectedRanges.count == 1 else { return nil }
        // Not in a line too long to highlight in (a minified file's): finding where a box goes in a
        // paragraph of thousands of wrapped lines held every keystroke up for seconds.
        if let document = textView.document, document.lines.lineCount > 0,
           document.lines.range(ofLine: document.lines.line(at: min(selection.location, document.lines.length))).count > Self.longestHighlightedLine { return nil }
        let text = textView.nsText
        let context = textView.tokenContexts()
        return BracketMatching.match(in: text, at: selection.location, brackets: textView.pairs.brackets) { context($0) == .code }
    }

    /// Lines longer than this (a minified file's) get no occurrences: thousands of boxes on one line say
    /// nothing, and finding their places would hold the editor up.
    private static let longestHighlightedLine = 10_000
    /// At most this many boxes on screen.
    private static let mostOccurrences = 500

    private func findOccurrences() -> [NSRange] {
        guard let document = textView.document, textView.selectedRanges.count == 1 else { return [] }
        let text = textView.nsText
        let selection = textView.selectedRange()
        var found: [NSRange] = []
        for line in visibleLines() {
            let range = document.lines.range(ofLine: line)
            guard range.count <= Self.longestHighlightedLine else { continue }
            found += Occurrences.highlights(in: text, selection: selection, visible: NSRange(location: range.lowerBound, length: range.count))
            if found.count > Self.mostOccurrences { return Array(found.prefix(Self.mostOccurrences)) }
        }
        return found
    }

    /// The lines TextKit has laid out around the screen (its viewport).
    private func visibleLines() -> Range<Int> {
        guard let document = textView.document, document.lines.lineCount > 0, let manager = textView.textLayoutManager,
              let storage = textView.textContentStorage, let viewport = manager.textViewportLayoutController.viewportRange else { return 0..<0 }
        let start = storage.documentRange.location
        let first = document.lines.line(at: storage.offset(from: start, to: viewport.location))
        let last = document.lines.line(at: storage.offset(from: start, to: viewport.endLocation))
        return first..<min(last + 1, document.lines.lineCount)
    }

    // MARK: Drawing

    /// The decorations in `rect`, drawn over the background and under the text.
    func draw(in rect: NSRect) {
        guard let document = textView.document, document.isText else { return }
        let colors = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(textView.effectiveAppearance)).editor
        if !occurrences.isEmpty {
            Palette.nsColor(colors[.wordHighlight]).setFill()
            for range in occurrences {
                for box in rects(for: range) where box.intersects(rect) { box.fill() }
            }
        }
        if let bracket {
            Palette.nsColor(colors[.bracketMatch]).setFill()
            for offset in [bracket.open, bracket.close] {
                for box in rects(for: NSRange(location: offset, length: 1)) where box.intersects(rect) { box.fill() }
            }
        }
        drawGuides(in: rect, normal: Palette.nsColor(colors[.indentGuide]), active: Palette.nsColor(colors[.indentGuideActive]))
    }

    private func drawGuides(in rect: NSRect, normal: NSColor, active: NSColor) {
        guard let document = textView.document else { return }
        var fragments: [(line: Int, frame: NSRect)] = []
        enumerateFragments(in: rect) { fragments.append(($0, $1)) }
        guard let first = fragments.first?.line, let last = fragments.last?.line else { return }
        let tabSize = document.tabWidth
        let indentSize = document.indentation.usesTabs ? tabSize : document.indentation.width
        // Only a line's start matters (its indentation): not a minified file's whole line.
        let text = textView.nsText
        let lines = IndentGuides.Lines(count: document.lines.lineCount, tabSize: tabSize, indentSize: indentSize, offSide: textView.indentsOffSide) { line in
            let range = document.lines.range(ofLine: line)
            return text.substring(with: NSRange(location: range.lowerBound, length: min(range.count, 1000)))
        }
        let levels = IndentGuides.levels(first..<(last + 1), of: lines)
        let cursorLine = document.lines.line(at: min(textView.selectedRange().location, text.length))
        let visible = visibleLines()
        let activeBlock = IndentGuides.active(at: cursorLine, in: lines, bounds: visible.isEmpty ? first..<(last + 1) : visible)
        let font = textView.font ?? EditorStyle.shared.font
        let column = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(indentSize)
        let left = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        let scale = textView.window?.backingScaleFactor ?? 2
        for (line, frame) in fragments {
            let level = levels[line - first]
            guard level > 0 else { continue }
            for index in 0..<level {
                let isActive = index + 1 == activeBlock.level && activeBlock.lines.contains(line)
                (isActive ? active : normal).setFill()
                let x = (left + CGFloat(index) * column) * scale
                NSRect(x: x.rounded() / scale, y: frame.minY, width: 1, height: frame.height).fill()
            }
        }
    }

    /// Each paragraph in `rect` with its line and its frame in the text view.
    private func enumerateFragments(in rect: NSRect, _ body: (Int, NSRect) -> Void) {
        guard let document = textView.document, let manager = textView.textLayoutManager, let storage = textView.textContentStorage else { return }
        let origin = textView.textContainerOrigin
        guard let top = manager.textLayoutFragment(for: NSPoint(x: 0, y: max(0, rect.minY - origin.y))) else { return }
        let start = storage.documentRange.location
        // Laid out as it goes (what is on screen already is), so each frame is where it is drawn and the walk
        // stops below `rect` rather than running through the file's estimated frames.
        manager.enumerateTextLayoutFragments(from: top.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > rect.maxY { return false }
            let line = document.lines.line(at: storage.offset(from: start, to: fragment.rangeInElement.location))
            body(line, NSRect(x: rect.minX, y: frame.minY, width: rect.width, height: frame.height))
            return true
        }
    }

    /// The rectangles a range of characters takes on screen.
    func rects(for range: NSRange) -> [NSRect] {
        guard let manager = textView.textLayoutManager, let storage = textView.textContentStorage,
              let start = storage.location(storage.documentRange.location, offsetBy: range.location),
              let end = storage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        let origin = textView.textContainerOrigin
        var rects: [NSRect] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return rects
    }
}
