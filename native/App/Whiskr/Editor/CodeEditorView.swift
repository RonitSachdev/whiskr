import AppKit
import WhiskrKit

/// One editor on a document: the line numbers, the text view in its scroll view, and the colours of the
/// lines on screen. TextKit 2 lays out only what is near the viewport, so a 50,000-line file opens and
/// scrolls as a short one does; the painter colours each paragraph as TextKit brings it in.
final class CodeEditorView: NSView, NSTextLayoutManagerDelegate, NSTextViewDelegate {
    let document: FileDocument
    let textView: CodeTextView
    let scrollView = NSScrollView()
    private let gutter: LineGutter
    private let layoutManager = NSTextLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    /// Lines whose colours are on screen as they should be.
    private var painted = IndexSet()
    private var waiting = IndexSet()
    private var paintScheduled = false
    private var observers: [Observing] = []
    /// The scroll and selection kept across a reload from the disk.
    private var keptPlace: (line: Int, selection: NSRange, oldLines: LineIndex)?
    /// Called when the scroll changes (the Markdown preview beside follows it).
    var onScroll: ((Int) -> Void)?

    init(document: FileDocument) {
        self.document = document
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layoutManager.textContainer = container
        document.contentStorage.addTextLayoutManager(layoutManager)
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        gutter = LineGutter()
        super.init(frame: .zero)
        layoutManager.delegate = self
        textView.document = document
        textView.delegate = self
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(String(localized: "Editor, \(document.name)", comment: "Accessibility: the editor and its file"))

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        gutter.editor = self

        for view in [gutter, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification, object: textView)

        document.attach(self, FileDocument.Editing(
            edited: { [weak self] lines, recoloured in self?.edited(lines: lines, recoloured: recoloured) },
            willReload: { [weak self] in self?.keepPlace() },
            didReload: { [weak self] in self?.restorePlace() }))
        observers.append(Observing { [weak self] in self?.applySettings() })
    }

    required init?(coder: NSCoder) {
        fatalError("CodeEditorView is created in code")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        document.detach(self)
        document.contentStorage.removeTextLayoutManager(layoutManager)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textView.applyStyle()
        gutter.needsDisplay = true
    }

    /// Font, theme, wrapping and invisibles, followed as they change in Settings.
    private func applySettings() {
        let preferences = EditorPreferences.shared
        let wrap = preferences.wrapLines
        _ = preferences.showInvisibles
        _ = ThemeStore.shared.palette
        _ = preferences.font
        _ = preferences.tabWidth
        EditorStyle.shared.refresh()
        textView.applyStyle()
        // The whole text takes the font and tab width (layout follows; colours are rendering attributes).
        let storage = document.storage
        if storage.length > 0 {
            document.contentStorage.performEditingTransaction {
                storage.addAttributes(EditorStyle.shared.baseAttributes, range: NSRange(location: 0, length: storage.length))
            }
        }
        setWrapping(wrap)
        layoutManager.invalidateLayout(for: layoutManager.documentRange)
        repaintAll()
        gutter.font = EditorStyle.shared.font
        gutter.needsDisplay = true
    }

    private func setWrapping(_ wrap: Bool) {
        scrollView.hasHorizontalScroller = !wrap
        textView.isHorizontallyResizable = !wrap
        container.widthTracksTextView = wrap
        if wrap {
            textView.frame.size.width = scrollView.contentSize.width
            container.size = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: Colours

    /// TextKit is bringing a paragraph in (it scrolled into view, or was edited): its line gets coloured.
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = EditorLayoutFragment(textElement: textElement, range: textElement.elementRange)
        if EditorPreferences.shared.showInvisibles {
            let style = EditorStyle.shared
            fragment.invisibles = [.font: style.font, .foregroundColor: style.color(.punctuation).withAlphaComponent(0.55)]
        }
        if let start = textElement.elementRange?.location {
            let offset = document.contentStorage.offset(from: document.contentStorage.documentRange.location, to: start)
            let line = document.lines.line(at: offset)
            if !painted.contains(line) { waiting.insert(line) }
            schedulePaint()
        }
        return fragment
    }

    private func edited(lines: Range<Int>, recoloured: Range<Int>) {
        // Lines after an edit move; their colours follow the text, but are worked out again from here on.
        if lines.lowerBound < (painted.last ?? -1) + 1 { painted.remove(integersIn: lines.lowerBound..<Int.max) }
        gutter.needsDisplay = true
        // Told while the storage is still being edited: what is on screen is asked once the edit is done.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let visible = self.visibleLines()
            self.waiting.insert(integersIn: visible)
            self.waiting.insert(integersIn: recoloured.clamped(to: visible))
            self.schedulePaint()
        }
    }

    private func repaintAll() {
        painted.removeAll()
        waiting.insert(integersIn: visibleLines())
        schedulePaint()
    }

    private func schedulePaint() {
        guard !paintScheduled else { return }
        paintScheduled = true
        DispatchQueue.main.async { [weak self] in self?.paint() }
    }

    /// Colours the waiting lines with their tokens' colours (rendering attributes: no layout is redone).
    private func paint() {
        paintScheduled = false
        guard document.isText else { return }
        let style = EditorStyle.shared
        style.refresh()
        let storage = document.contentStorage
        let start = storage.documentRange.location
        let count = document.lines.lineCount
        for line in waiting where line < count && !painted.contains(line) {
            let range = document.lines.range(ofLine: line)
            guard let from = storage.location(start, offsetBy: range.lowerBound), let to = storage.location(from, offsetBy: range.count),
                  let lineRange = NSTextRange(location: from, end: to) else { continue }
            layoutManager.removeRenderingAttribute(.foregroundColor, for: lineRange)
            for token in document.tokens(line: line) where token.kind != .plain {
                guard let tokenStart = storage.location(from, offsetBy: token.range.lowerBound),
                      let tokenEnd = storage.location(tokenStart, offsetBy: token.range.count),
                      let tokenRange = NSTextRange(location: tokenStart, end: tokenEnd) else { continue }
                layoutManager.addRenderingAttribute(.foregroundColor, value: style.color(token.kind), for: tokenRange)
            }
            painted.insert(line)
        }
        waiting.removeAll()
    }

    /// The lines on screen (and a screenful either side), from the layout of the visible rectangle.
    func visibleLines() -> Range<Int> {
        let count = document.lines.lineCount
        guard count > 0 else { return 0..<0 }
        let visible = scrollView.contentView.bounds
        let top = line(atY: visible.minY), bottom = line(atY: visible.maxY)
        let margin = max(20, bottom - top)
        return max(0, top - margin)..<min(count, bottom + margin + 1)
    }

    /// The line at a height in the text view.
    func line(atY y: CGFloat) -> Int {
        let point = NSPoint(x: 0, y: max(0, y - textView.textContainerOrigin.y))
        guard let fragment = layoutManager.textLayoutFragment(for: point), let location = fragment.rangeInElement.location as NSTextLocation? else {
            return y <= 0 ? 0 : document.lines.lineCount - 1
        }
        return document.lines.line(at: document.contentStorage.offset(from: document.contentStorage.documentRange.location, to: location))
    }

    @objc private func scrolled() {
        gutter.needsDisplay = true
        let visible = visibleLines()
        let missing = IndexSet(integersIn: visible).subtracting(painted)
        if !missing.isEmpty {
            waiting.formUnion(missing)
            schedulePaint()
        }
        onScroll?(line(atY: scrollView.contentView.bounds.minY))
    }

    /// The first line fully on screen, for the preview beside.
    var topLine: Int { line(atY: scrollView.contentView.bounds.minY) }

    // MARK: Reloading

    private func keepPlace() {
        keptPlace = (topLine, textView.selectedRange(), document.lines)
    }

    private func restorePlace() {
        painted.removeAll()
        guard let kept = keptPlace else { return repaintAll() }
        keptPlace = nil
        let lines = document.lines
        let location = FileSync.carry(offset: kept.selection.location, from: kept.oldLines, to: lines)
        let end = FileSync.carry(offset: NSMaxRange(kept.selection), from: kept.oldLines, to: lines)
        textView.setSelectedRange(NSRange(location: location, length: max(0, end - location)))
        let line = min(kept.line, lines.lineCount - 1)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollTo(line: line)
            self.repaintAll()
        }
    }

    /// Scrolls so `line` is the first on screen.
    private func scrollTo(line: Int) {
        let storage = document.contentStorage
        guard let location = storage.location(storage.documentRange.location, offsetBy: document.lines.starts[min(line, document.lines.lineCount - 1)]) else { return }
        layoutManager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layoutManager.textLayoutFragment(for: location) else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y - 1)))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    func textViewDidChangeSelection(_ notification: Notification) {
        gutter.needsDisplay = true
        EditorStatus.shared.update(from: self)
    }
}

/// A paragraph's layout that also draws invisibles (Settings › Editor › Show invisibles): a faint dot
/// for each space, an arrow for each tab, a mark at each line's end. Made and drawn on the main thread;
/// the setting is read when it is made (turning it on or off lays the text out again).
nonisolated final class EditorLayoutFragment: NSTextLayoutFragment, @unchecked Sendable {
    /// How the marks are drawn; nil while invisibles are hidden.
    var invisibles: [NSAttributedString.Key: Any]?

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let attributes = invisibles else { return }
        for line in textLineFragments {
            let text = line.attributedString.string as NSString
            let range = line.characterRange
            for index in range.lowerBound..<range.upperBound {
                let character = text.character(at: index)
                let mark: String
                switch character {
                case 0x20: mark = "·"
                case 0x09: mark = "→"
                case 0x0A: mark = "¬"
                default: continue
                }
                let position = line.locationForCharacter(at: index)
                let origin = CGPoint(x: point.x + line.typographicBounds.minX + position.x, y: point.y + line.typographicBounds.minY)
                (mark as NSString).draw(at: origin, withAttributes: attributes)
            }
        }
    }

    override var renderingSurfaceBounds: CGRect {
        // The pilcrow may sit past the text's own bounds.
        super.renderingSurfaceBounds.insetBy(dx: -12, dy: 0)
    }
}

/// Line numbers beside the text, in the theme's faint colour; the cursor's line stronger.
final class LineGutter: NSView {
    weak var editor: CodeEditorView?
    var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private var width: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        width = widthAnchor.constraint(equalToConstant: 44)
        width?.isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("LineGutter is created in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor else { return }
        let document = editor.document
        let colors = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance)).terminal
        Palette.nsColor(colors.background).setFill()
        bounds.fill()
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 1.5), weight: .regular)
        let digits = max(3, String(document.lines.lineCount).count)
        let needed = ceil(CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: numberFont]).width + 26)
        if abs((width?.constant ?? 0) - needed) > 0.5 {
            width?.constant = needed
            return
        }
        let faint = Palette.nsColor(colors.foreground.mixed(with: colors.background, 0.62))
        let strong = Palette.nsColor(colors.foreground.mixed(with: colors.background, 0.2))
        let textView = editor.textView
        let clip = editor.scrollView.contentView.bounds
        guard let manager = textView.textLayoutManager, let storage = textView.textContentStorage else { return }
        let cursorLine = document.lines.line(at: textView.selectedRange().location)
        let origin = textView.textContainerOrigin.y
        let start = storage.documentRange.location
        guard let top = manager.textLayoutFragment(for: NSPoint(x: 0, y: max(0, clip.minY - origin))) else { return }
        manager.enumerateTextLayoutFragments(from: top.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let y = frame.minY + origin - clip.minY
            if y > self.bounds.height { return false }
            let offset = storage.offset(from: start, to: fragment.rangeInElement.location)
            let line = document.lines.line(at: offset)
            let first = fragment.textLineFragments.first
            let baseline = (first?.typographicBounds.minY ?? 0) + (first?.glyphOrigin.y ?? numberFont.ascender)
            let label = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: line == cursorLine ? strong : faint]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: self.bounds.width - 14 - size.width, y: y + baseline - numberFont.ascender + (self.font.pointSize - numberFont.pointSize) / 2),
                       withAttributes: attributes)
            return true
        }
    }
}
