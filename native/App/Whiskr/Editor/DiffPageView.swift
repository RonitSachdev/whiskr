import AppKit
import Observation
import SwiftUI
import WhiskrKit

/// A file's changes in a tab: side by side or inline, in the editor's colours, the changed words tinted,
/// with next and previous change. It follows the disk: as Claude keeps editing, the diff stays current.
final class DiffPageView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let pageID: UUID
    let path: String
    let staged: Bool
    private let workbench: Workbench
    private let model: DiffModel
    private let header: NSHostingView<DiffHeader>
    private let scrollView = NSScrollView()
    private let table = DiffTable()
    private let empty: NSHostingView<DiffEmpty>
    private var observers: [Observing] = []
    private var heights: [CGFloat] = []
    private var measuredWidth: CGFloat = 0
    private var lastLayout: EditorPreferences.DiffLayout?

    init(pageID: UUID, path: String, staged: Bool, workbench: Workbench) {
        self.pageID = pageID
        self.path = path
        self.staged = staged
        self.workbench = workbench
        model = DiffModel(path: path, staged: staged, files: workbench.files)
        header = NSHostingView(rootView: DiffHeader(model: model, workbench: workbench))
        empty = NSHostingView(rootView: DiffEmpty(model: model, workbench: workbench))
        super.init(frame: .zero)
        header.sizingOptions = []
        empty.sizingOptions = []
        model.onStep = { [weak self] step in self?.step(step) }

        let column = NSTableColumn(identifier: .init("diff"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.setAccessibilityLabel(String(localized: "Changes to \(URL(fileURLWithPath: path).lastPathComponent)", comment: "Accessibility: the diff"))
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        for view in [header, scrollView, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: FilePageView.headerHeight),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.topAnchor.constraint(equalTo: header.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantsLayer = true
        observers.append(Observing { [weak self] in self?.update() })
        observers.append(PageDimming.attach(to: self, page: pageID, workbench: workbench))
    }

    required init?(coder: NSCoder) {
        fatalError("DiffPageView is created in code")
    }

    var focusTarget: NSView { table }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
        table.reloadData()
    }

    private func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Colors.terminalBackground.cgColor }
    }

    private func update() {
        _ = model.rows
        _ = ThemeStore.shared.palette
        _ = EditorPreferences.shared.font
        let layout = effectiveLayout
        updateLook()
        if layout != lastLayout {
            lastLayout = layout
            model.relayout(layout)
        }
        empty.isHidden = !model.rows.isEmpty || !model.loaded
        scrollView.isHidden = model.rows.isEmpty
        model.textCache.removeAll()
        measure(force: true)
        table.reloadData()
    }

    override func layout() {
        super.layout()
        if effectiveLayout != lastLayout {
            update()
        } else {
            measure(force: false)
        }
    }

    /// Side by side needs room: in a narrow pane the diff shows inline (as GitHub does), whatever is chosen.
    private var effectiveLayout: EditorPreferences.DiffLayout {
        let chosen = EditorPreferences.shared.diffLayout
        return chosen == .sideBySide && bounds.width > 0 && bounds.width < 760 ? .inline : chosen
    }

    /// Each row's height: its longest side's text wrapped at the column's width (monospaced, so counted).
    private func measure(force: Bool) {
        let width = scrollView.contentSize.width
        guard force || abs(width - measuredWidth) > 0.5 else { return }
        measuredWidth = width
        let metrics = DiffRowView.metrics()
        let sideBySide = model.layout == .sideBySide
        let textWidth = sideBySide ? (width / 2 - DiffRowView.gutter - 16) : (width - DiffRowView.gutter * 2 - 30)
        let perLine = max(8, Int(textWidth / metrics.advance))
        heights = model.rows.map { row in
            if row.kind == .hunk { return metrics.line + 14 }
            let longest = max(row.old.map { DiffModel.width(of: $0.text) } ?? 0, row.new.map { DiffModel.width(of: $0.text) } ?? 0)
            let lines = max(1, (longest + perLine - 1) / perLine)
            return CGFloat(lines) * metrics.line + 4
        }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<heights.count))
    }

    /// Next or previous change: the row where the following change begins scrolls to the upper third.
    private func step(_ direction: Int) {
        let starts = DiffLayout.changeStarts(model.rows)
        guard !starts.isEmpty else { return NSSound.beep() }
        let visible = table.rows(in: scrollView.contentView.bounds)
        let top = visible.location + 2
        let target = direction > 0 ? starts.first { $0 > top } ?? starts.last! : starts.last { $0 < top - 1 } ?? starts.first!
        let rect = table.rect(ofRow: max(0, target - 1))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 24)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func step(next: Bool) { step(next ? 1 : -1) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        heights.indices.contains(row) ? heights[row] : DiffRowView.metrics().line + 4
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: DiffRowView.identifier, owner: nil) as? DiffRowView ?? DiffRowView()
        view.identifier = DiffRowView.identifier
        view.configure(model: model, index: row)
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// The table: takes the keyboard (arrows scroll; the window's commands still reach the page).
private final class DiffTable: NSTableView {
    override var acceptsFirstResponder: Bool { true }
}

/// What the diff shows: its rows in the chosen layout, each side's tokens, and its counts. Read again,
/// off the main thread, when the repository changes on disk.
@MainActor @Observable
final class DiffModel {
    let path: String
    let staged: Bool
    private(set) var rows: [DiffRow] = []
    private(set) var tokens: [Int: (old: [SyntaxToken], new: [SyntaxToken])] = [:]
    private(set) var added = 0
    private(set) var removed = 0
    private(set) var loaded = false
    private(set) var isBinary = false
    private(set) var isNewFile = false
    /// The file is in conflict (a merge, rebase or stash left it so): the diff reads against your side,
    /// with the conflict markers and the other side's lines as added.
    private(set) var isConflicted = false
    private(set) var layout: EditorPreferences.DiffLayout = EditorPreferences.shared.diffLayout
    @ObservationIgnored var onStep: ((Int) -> Void)?
    /// Each row's drawn text, built once per theme and layout.
    @ObservationIgnored var textCache: [Int: (old: NSAttributedString?, new: NSAttributedString?)] = [:]
    @ObservationIgnored private var diff: FileDiff?
    @ObservationIgnored private weak var files: FilesCenter?
    @ObservationIgnored private var observer: Observing?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(path: String, staged: Bool, files: FilesCenter) {
        self.path = path
        self.staged = staged
        self.files = files
        observer = Observing { [weak self] in
            // Looked up again when the repository holding the file is found or replaced.
            _ = self?.files?.repositoryGeneration
            guard let self, let repository = self.repository else { return }
            _ = repository.diskVersion
            _ = repository.status
            self.reload()
        }
    }

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var language: SyntaxLanguage { SyntaxLanguage.detect(fileName: name, firstLine: nil) }

    private var repository: Repository? { files?.repository(containing: URL(fileURLWithPath: path)) }

    func reload() {
        guard let repository, let relative = repository.relativePath(of: URL(fileURLWithPath: path)) else { return }
        let untracked = repository.status?.untracked.contains { $0.path == relative } ?? false
        let conflicted = repository.status?.entries.contains { $0.path == relative && $0.isConflicted } ?? false
        let path = path, staged = staged
        loading?.cancel()
        loading = Task { [weak self] in
            let text = untracked && !staged ? nil : await repository.diff(path: relative, staged: staged)
            let diff: FileDiff? = await Task.detached(priority: .userInitiated) {
                if let text { return UnifiedDiff.parse(text).first }
                guard let data = FileManager.default.contents(atPath: path), case .text(let file) = TextFile.read(data) else { return nil }
                return UnifiedDiff.addedFile(path: relative, text: file.text)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isNewFile = untracked
            self.isConflicted = conflicted || diff?.isCombined == true
            self.take(diff)
        }
    }

    private func take(_ diff: FileDiff?) {
        self.diff = diff
        isBinary = diff?.isBinary ?? false
        let lines = diff?.hunks.flatMap(\.lines) ?? []
        added = lines.filter { $0.kind == .added }.count
        removed = lines.filter { $0.kind == .removed }.count
        relayout(layout)
        loaded = true
    }

    func relayout(_ layout: EditorPreferences.DiffLayout) {
        self.layout = layout
        guard let diff else {
            rows = []
            tokens = [:]
            return
        }
        let rows = layout == .sideBySide ? DiffLayout.sideBySide(diff) : DiffLayout.inline(diff)
        // Each side is lexed in order, its state carried down the hunk, so strings and comments that span
        // lines colour as they do in the editor.
        let lexer = SyntaxLexer(language: language)
        var oldState = LexerState.initial, newState = LexerState.initial
        var tokens: [Int: (old: [SyntaxToken], new: [SyntaxToken])] = [:]
        for (index, row) in rows.enumerated() {
            if row.kind == .hunk {
                oldState = .initial
                newState = .initial
                continue
            }
            var pair: (old: [SyntaxToken], new: [SyntaxToken]) = ([], [])
            if let old = row.old {
                let result = lexer.tokenize(old.text, from: oldState)
                pair.old = result.tokens
                oldState = result.end
            }
            if let new = row.new {
                if row.kind == .context, let old = row.old, old.text == new.text, row.old != nil {
                    pair.new = pair.old
                    newState = lexer.tokenize(new.text, from: newState).end
                } else {
                    let result = lexer.tokenize(new.text, from: newState)
                    pair.new = result.tokens
                    newState = result.end
                }
            }
            tokens[index] = pair
        }
        self.rows = rows
        self.tokens = tokens
    }

    /// A line's width in columns, tabs counted to their stops.
    nonisolated static func width(of text: String) -> Int {
        var columns = 0
        for unit in text.utf16 {
            columns = unit == 9 ? (columns / 4 + 1) * 4 : columns + 1
        }
        return columns
    }
}

/// One row of the diff, drawn directly: line numbers, the text in its colours, the added and removed
/// tints and the changed words a little stronger.
final class DiffRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffRow")
    static let gutter: CGFloat = 44

    private var row: DiffRow?
    private var index = 0
    private weak var model: DiffModel?

    override var isFlipped: Bool { true }

    func configure(model: DiffModel, index: Int) {
        self.model = model
        self.index = index
        row = model.rows.indices.contains(index) ? model.rows[index] : nil
        needsDisplay = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityText)
    }

    static func metrics() -> (advance: CGFloat, line: CGFloat, font: NSFont) {
        let font = NSFont.monospacedSystemFont(ofSize: max(10, EditorPreferences.shared.font.pointSize - 1), weight: .regular)
        let preferred = EditorPreferences.shared.fontFamily.isEmpty && ThemeStore.shared.fontFamily.isEmpty ? font
            : NSFont(descriptor: EditorPreferences.shared.font.fontDescriptor, size: font.pointSize) ?? font
        let advance = ("M" as NSString).size(withAttributes: [.font: preferred]).width
        return (advance, ceil(preferred.ascender - preferred.descender + preferred.leading + 3), preferred)
    }

    private var accessibilityText: String {
        guard let row else { return "" }
        switch row.kind {
        case .hunk: return row.header ?? ""
        case .context: return String(localized: "Line \(row.new?.number ?? 0): \(row.new?.text ?? "")")
        case .removed: return String(localized: "Removed line \(row.old?.number ?? 0): \(row.old?.text ?? "")")
        case .added: return String(localized: "Added line \(row.new?.number ?? 0): \(row.new?.text ?? "")")
        case .changed: return String(localized: "Line \(row.old?.number ?? 0) changed from \(row.old?.text ?? "") to \(row.new?.text ?? "")")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let model else { return }
        let terminal = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance)).terminal
        let background = terminal.background, foreground = terminal.foreground
        func tint(_ color: WhiskrKit.RGBColor, _ amount: Double) -> NSColor { Palette.nsColor(background.mixed(with: color, amount)) }
        let green = terminal.ansi[2], red = terminal.ansi[1]
        let strength = terminal.isDark ? 0.16 : 0.12
        let metrics = Self.metrics()
        let faint = Palette.nsColor(foreground.mixed(with: background, 0.6))

        if row.kind == .hunk {
            tint(foreground, 0.04).setFill()
            bounds.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: metrics.font, .foregroundColor: faint]
            ((row.header ?? "") as NSString).draw(at: NSPoint(x: 12, y: 7), withAttributes: attributes)
            return
        }
        let sideBySide = model.layout == .sideBySide
        if sideBySide {
            let half = (bounds.width / 2).rounded()
            drawSide(row.old, in: NSRect(x: 0, y: 0, width: half, height: bounds.height), removedSide: true,
                     tintColor: row.kind == .context || row.old == nil ? nil : red, strength: strength, metrics: metrics, faint: faint, background: background)
            drawSide(row.new, in: NSRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height), removedSide: false,
                     tintColor: row.kind == .context || row.new == nil ? nil : green, strength: strength, metrics: metrics, faint: faint, background: background)
            Palette.nsColor(background.mixed(with: foreground, 0.12)).setFill()
            NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()
        } else {
            let removed = row.kind == .removed
            let cell = removed ? row.old : row.new ?? row.old
            let color: WhiskrKit.RGBColor? = row.kind == .context ? nil : removed ? red : green
            if let color {
                tint(color, strength).setFill()
                bounds.fill()
            }
            let numbers: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: metrics.font.pointSize - 1, weight: .regular), .foregroundColor: faint]
            if let old = row.old, row.kind != .added { draw(number: old.number, right: Self.gutter - 8, y: 2, attributes: numbers) }
            if let new = row.new, row.kind != .removed { draw(number: new.number, right: Self.gutter * 2 - 8, y: 2, attributes: numbers) }
            let marker = row.kind == .added ? "+" : row.kind == .removed ? "−" : " "
            (marker as NSString).draw(at: NSPoint(x: Self.gutter * 2 + 2, y: 2), withAttributes: [.font: metrics.font, .foregroundColor: faint])
            if let cell {
                let text = attributed(cell, old: removed, color: color, strength: strength, background: background, metrics: metrics)
                text.draw(with: NSRect(x: Self.gutter * 2 + 18, y: 2, width: bounds.width - Self.gutter * 2 - 24, height: bounds.height),
                          options: [.usesLineFragmentOrigin])
            }
        }
    }

    private func drawSide(_ cell: DiffCell?, in rect: NSRect, removedSide: Bool, tintColor: WhiskrKit.RGBColor?, strength: Double, metrics: (advance: CGFloat, line: CGFloat, font: NSFont),
                          faint: NSColor, background: WhiskrKit.RGBColor) {
        guard let cell else {
            // No line on this side: a quiet hatch-free gap.
            Palette.nsColor(background.mixed(with: ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance)).terminal.foreground, 0.025)).setFill()
            rect.fill()
            return
        }
        if let tintColor {
            Palette.nsColor(background.mixed(with: tintColor, strength)).setFill()
            rect.fill()
        }
        let numbers: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: metrics.font.pointSize - 1, weight: .regular), .foregroundColor: faint]
        draw(number: cell.number, right: rect.minX + Self.gutter - 8, y: 2, attributes: numbers)
        let text = attributed(cell, old: removedSide, color: tintColor, strength: strength, background: background, metrics: metrics)
        text.draw(with: NSRect(x: rect.minX + Self.gutter, y: 2, width: rect.width - Self.gutter - 8, height: rect.height), options: [.usesLineFragmentOrigin])
    }

    private func draw(number: Int, right: CGFloat, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: right - size.width, y: y + 1), withAttributes: attributes)
    }

    /// The cell's text in its syntax colours, wrapped by character, its changed part tinted more strongly.
    private func attributed(_ cell: DiffCell, old: Bool, color: WhiskrKit.RGBColor?, strength: Double, background: WhiskrKit.RGBColor,
                            metrics: (advance: CGFloat, line: CGFloat, font: NSFont)) -> NSAttributedString {
        if let cached = model?.textCache[index], let text = old ? cached.old : cached.new { return text }
        let style = EditorStyle.shared
        style.refresh()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.defaultTabInterval = metrics.advance * 4
        paragraph.tabStops = []
        paragraph.minimumLineHeight = metrics.line
        paragraph.maximumLineHeight = metrics.line
        let text = NSMutableAttributedString(string: cell.text, attributes: [.font: metrics.font, .foregroundColor: style.textColor, .paragraphStyle: paragraph])
        let tokens = model.flatMap { model in model.tokens[index].map { old ? $0.old : $0.new } } ?? []
        let length = (cell.text as NSString).length
        for token in tokens where token.kind != .plain && token.range.upperBound <= length {
            text.addAttribute(.foregroundColor, value: style.color(token.kind), range: NSRange(location: token.range.lowerBound, length: token.range.count))
        }
        if let changed = cell.changed, let color, changed.upperBound <= length {
            text.addAttribute(.backgroundColor, value: Palette.nsColor(background.mixed(with: color, strength * 2.4)),
                              range: NSRange(location: changed.lowerBound, length: changed.count))
        }
        var entry = model?.textCache[index] ?? (nil, nil)
        if old { entry.old = text } else { entry.new = text }
        model?.textCache[index] = entry
        return text
    }
}

/// The diff's header: the file, which changes these are, how many lines, the layout, and next/previous.
private struct DiffHeader: View {
    let model: DiffModel
    let workbench: Workbench
    @Bindable private var preferences = EditorPreferences.shared

    init(model: DiffModel, workbench: Workbench) {
        self.model = model
        self.workbench = workbench
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .accessibilityHidden(true)
            Text(model.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Text(kind)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
                .lineLimit(1)
            if model.added + model.removed > 0 {
                Text(verbatim: "+\(model.added)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color(nsColor: EditorStyle.shared.color(.string)))
                Text(verbatim: "−\(model.removed)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color(nsColor: EditorStyle.shared.color(.property)))
            }
            Spacer(minLength: 12)
            HeaderButton(symbol: "chevron.up", help: String(localized: "Previous Change")) { model.onStep?(-1) }
            HeaderButton(symbol: "chevron.down", help: String(localized: "Next Change")) { model.onStep?(1) }
            HeaderButton(symbol: "doc.text", help: String(localized: "Open File")) { workbench.open(file: model.path, mode: .keep) }
            Picker(String(localized: "Layout"), selection: $preferences.diffLayout) {
                Image(systemName: "rectangle.split.2x1").help(String(localized: "Side by Side")).tag(EditorPreferences.DiffLayout.sideBySide)
                Image(systemName: "rectangle.grid.1x2").help(String(localized: "Inline")).tag(EditorPreferences.DiffLayout.inline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(String(localized: "Side by side or inline"))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Colors.terminalBackground))
        .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
    }

    private var kind: String {
        if model.isNewFile { return String(localized: "New file", comment: "Diff header: an untracked file") }
        if model.isConflicted { return String(localized: "In conflict, against your side", comment: "Diff header: a file with merge conflicts, compared with your branch's version") }
        return model.staged ? String(localized: "Staged changes", comment: "Diff header") : String(localized: "Changes", comment: "Diff header: unstaged changes")
    }
}

/// When there is nothing to compare.
private struct DiffEmpty: View {
    let model: DiffModel
    let workbench: Workbench

    private var symbol: String {
        model.isConflicted ? "exclamationmark.triangle" : model.isBinary ? "doc.badge.ellipsis" : "checkmark.circle"
    }

    private var message: String {
        // Staged, a file in conflict has nothing yet: it is staged once it is resolved.
        if model.isConflicted { return String(localized: "This file is in conflict. Resolve it in the file, then stage it.", comment: "Diff page: a conflicted file with nothing to compare yet") }
        return model.isBinary ? String(localized: "A binary file: there is no text to compare.") : String(localized: "No changes")
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.ink3)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
            if model.isConflicted {
                Button(String(localized: "Open File")) { workbench.open(file: model.path, mode: .keep) }
                    .controlSize(.small)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Colors.terminalBackground))
    }
}
