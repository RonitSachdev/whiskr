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
    /// Revert Change and Stage Change, over the change under the pointer.
    private let actions: NSHostingView<ChangeActions>
    /// The change under the pointer: its rows, and what they held when the actions appeared. The diff
    /// follows the disk while Claude edits, so other rows may sit there by the time of a click; the actions
    /// act only on the change they were shown for.
    private var hoveredBlock: (rows: ClosedRange<Int>, content: [DiffRow])?

    init(pageID: UUID, path: String, staged: Bool, workbench: Workbench) {
        self.pageID = pageID
        self.path = path
        self.staged = staged
        self.workbench = workbench
        model = DiffModel(path: path, staged: staged, files: workbench.files)
        header = NSHostingView(rootView: DiffHeader(model: model, workbench: workbench, page: pageID))
        empty = NSHostingView(rootView: DiffEmpty(model: model, workbench: workbench))
        actions = NSHostingView(rootView: ChangeActions(staged: staged, perform: { _ in }))
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
        actions.sizingOptions = [.intrinsicContentSize]
        actions.isHidden = true
        addSubview(actions)
        actions.rootView = ChangeActions(staged: staged) { [weak self] action in self?.perform(action) }
        table.onPointer = { [weak self] point in self?.pointerMoved(point) }
        table.onClickRow = { [weak self] row in self?.clicked(row: row) ?? false }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
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
        _ = model.tokens
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
        // The table takes the new rows before their heights: told of heights first, it asked for rows the
        // model no longer had (a diff going from inline to side by side as its pane widened crashed).
        table.reloadData()
        measure(force: true)
        // Other rows under the pointer now: the actions go, and come back for them when the pointer moves.
        if !hoveredBlockIsCurrent { hideActions() }
    }

    private var hoveredBlockIsCurrent: Bool {
        guard let (block, content) = hoveredBlock else { return true }
        return block.upperBound < model.rows.count && Array(model.rows[block]) == content
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
            if row.kind == .hunk || row.kind == .gap { return metrics.line + 14 }
            let longest = max(row.old.map { DiffModel.width(of: $0.text) } ?? 0, row.new.map { DiffModel.width(of: $0.text) } ?? 0)
            let lines = max(1, (longest + perLine - 1) / perLine)
            return CGFloat(lines) * metrics.line + 4
        }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<min(heights.count, table.numberOfRows)))
    }

    /// Next or previous change: the row where the following change begins scrolls to the upper third.
    private func step(_ direction: Int) {
        let starts = DiffLayout.changeStarts(model.rows)
        guard !starts.isEmpty else { return AlertCenter.beep() }
        let visible = table.rows(in: scrollView.contentView.bounds)
        let top = visible.location + 2
        let target = direction > 0 ? starts.first { $0 > top } ?? starts.last! : starts.last { $0 < top - 1 } ?? starts.first!
        let rect = table.rect(ofRow: max(0, target - 1))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 24)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func step(next: Bool) { step(next ? 1 : -1) }

    // MARK: One change at a time

    /// A click on a folded stretch opens it.
    private func clicked(row: Int) -> Bool {
        guard model.rows.indices.contains(row), let gap = model.rows[row].gap else { return false }
        model.unfold(gap)
        return true
    }

    /// The pointer over a change shows its actions at the top right of its first row.
    private func pointerMoved(_ point: NSPoint?) {
        // Onto the actions themselves is still over the change.
        if point == nil, let window, actions.frame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { return }
        guard let point, model.actsOnChanges else { return hideActions() }
        let row = table.row(at: point)
        guard let block = DiffLayout.changeBlocks(model.rows).first(where: { $0.contains(row) }) else { return hideActions() }
        hoveredBlock = (block, Array(model.rows[block]))
        let first = table.convert(table.rect(ofRow: block.lowerBound), to: self)
        let size = actions.fittingSize
        actions.frame = NSRect(x: bounds.width - size.width - Look.Space.xl, y: first.maxY - size.height - 1, width: size.width, height: size.height)
        actions.isHidden = false
    }

    private func hideActions() {
        hoveredBlock = nil
        actions.isHidden = true
    }

    @objc private func scrolled() { hideActions() }

    private func perform(_ action: ChangeActions.Action) {
        guard let block = hoveredBlock?.rows else { return }
        guard hoveredBlockIsCurrent else {
            hideActions()
            return AlertCenter.beep()
        }
        switch action {
        case .revert: revertChange(rows: block)
        case .stage: stageChange(rows: block)
        }
        hideActions()
    }

    /// Stage Change (Unstage Change in a staged diff): this change alone into (or out of) the index.
    func stageChange(rows: ClosedRange<Int>) {
        guard let repository = workbench.files.repository(containing: URL(fileURLWithPath: path)),
              let patch = model.patch(for: rows, direction: staged ? .fromNew : .toOld) else { return AlertCenter.beep() }
        repository.apply(patch, cached: true, reverse: staged) { if !$0 { AlertCenter.beep() } }
    }

    /// Revert Change: the working file loses this change alone. Undoable (Edit › Undo Revert Change, or the
    /// note's Undo); never over unsaved edits to the file, which would be lost.
    func revertChange(rows: ClosedRange<Int>) {
        guard !staged, let repository = workbench.files.repository(containing: URL(fileURLWithPath: path)),
              let patch = model.patch(for: rows, direction: .fromNew) else { return AlertCenter.beep() }
        if workbench.files.documents[path]?.isEdited == true {
            model.note = .unsaved
            return
        }
        // Registered once git has applied it, whether or not this page is still open: the undo belongs to
        // the change, not to the page (a preview tab is replaced by the next file chosen in Changes).
        let step = RevertStep(patch: patch, repository: repository, path: path, workbench: workbench, model: model)
        repository.apply(patch, cached: false, reverse: true) { done in
            guard done else { return AlertCenter.beep() }
            step.model?.note = .reverted
            Self.registerUndo(of: step, out: true)
            // The note's Undo is this revert's, whatever else the window's Undo would take back first.
            step.model?.undo = { [weak undo = step.workbench.undoManager] in
                guard step.mayChangeFile else { return }
                undo?.removeAllActions(withTarget: step)
                Self.redo(step, out: false, registering: false)
            }
        }
    }

    /// One Revert Change, as the target of its Undo and Redo (so it can be taken off the window's undo
    /// stack on its own). It holds what the undo needs without the page, which may be gone by then; its
    /// handlers hold it (the undo manager does not hold its targets).
    private final class RevertStep {
        let patch: String
        let repository: Repository
        let path: String
        let workbench: Workbench
        /// The page's model while the page is open: its note says what happened.
        weak var model: DiffModel?
        init(patch: String, repository: Repository, path: String, workbench: Workbench, model: DiffModel) {
            self.patch = patch
            self.repository = repository
            self.path = path
            self.workbench = workbench
            self.model = model
        }

        /// Never over unsaved edits to the file, which reloading it would put in question.
        @MainActor var mayChangeFile: Bool {
            guard workbench.files.documents[path]?.isEdited == true else { return true }
            model?.note = .unsaved
            AlertCenter.beep()
            return false
        }
    }

    /// Registers what undoes `step`: with the change taken out of the file (`out`), putting it back; else
    /// taking it out again (Redo). Each registers its own inverse, so Undo and Redo alternate as often as
    /// asked.
    private static func registerUndo(of step: RevertStep, out: Bool) {
        guard let undo = step.workbench.undoManager else { return }
        undo.registerUndo(withTarget: step) { [weak undo] _ in
            MainActor.assumeIsolated {
                // `step`, not the handler's argument: held here, so the target outlives the page.
                guard step.mayChangeFile else {
                    // An Undo stays available for after saving; a refused Redo is dropped (its file is as before).
                    if undo?.isUndoing == true { DispatchQueue.main.async { registerUndo(of: step, out: out) } }
                    return
                }
                redo(step, out: !out)
            }
        }
        undo.setActionName(String(localized: "Revert Change"))
    }

    /// Takes the change out of the working file (`out`) or puts it back, and registers the inverse.
    private static func redo(_ step: RevertStep, out: Bool, registering: Bool = true) {
        step.repository.apply(step.patch, cached: false, reverse: out) { done in if !done { AlertCenter.beep() } }
        step.model?.note = out ? .reverted : nil
        if registering { registerUndo(of: step, out: out) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        heights.indices.contains(row) ? heights[row] : DiffRowView.metrics().line + 4
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: DiffRowView.identifier, owner: nil) as? DiffRowView ?? DiffRowView()
        view.identifier = DiffRowView.identifier
        view.configure(model: model, index: row)
        // VoiceOver reaches a change's Revert and Stage as the row's own actions.
        if model.actsOnChanges, let block = DiffLayout.changeBlocks(model.rows).first(where: { $0.contains(row) }) {
            var actions = [NSAccessibilityCustomAction(name: staged ? String(localized: "Unstage Change") : String(localized: "Stage Change")) { [weak self] in
                self?.stageChange(rows: block)
                return true
            }]
            if !staged {
                actions.insert(NSAccessibilityCustomAction(name: String(localized: "Revert Change")) { [weak self] in
                    self?.revertChange(rows: block)
                    return true
                }, at: 0)
            }
            view.setAccessibilityCustomActions(actions)
        } else if let gap = model.rows[row].gap {
            view.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: String(localized: "Show Lines", comment: "Accessibility: opens a folded stretch of a diff")) { [weak self] in
                self?.model.unfold(gap)
                return true
            }])
        } else {
            view.setAccessibilityCustomActions(nil)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// The table: takes the keyboard (arrows scroll; the window's commands still reach the page), says where
/// the pointer is over it, and a click on a folded stretch opens it.
private final class DiffTable: NSTableView {
    var onPointer: ((NSPoint?) -> Void)?
    var onClickRow: ((Int) -> Bool)?
    private var area: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) { onPointer?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onPointer?(nil) }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, onClickRow?(row) == true { return }
        super.mouseDown(with: event)
    }
}

/// Over a change, on hover: Revert Change and Stage Change (Unstage Change in a staged diff). Small,
/// in the surface colour, as the bars' buttons are.
private struct ChangeActions: View {
    enum Action { case revert, stage }
    let staged: Bool
    let perform: (Action) -> Void

    var body: some View {
        HStack(spacing: 2) {
            if !staged {
                button(String(localized: "Revert Change"), symbol: "arrow.uturn.backward") { perform(.revert) }
            }
            button(staged ? String(localized: "Unstage Change") : String(localized: "Stage Change"), symbol: staged ? "minus" : "plus") { perform(.stage) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Look.Radius.control).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Look.Radius.control).strokeBorder(Color.line))
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color.ink2)
                .padding(.horizontal, Look.Space.s)
                .frame(height: 20)
        }
        .buttonStyle(ChromeButtonStyle(radius: Look.Radius.small))
        .help(title)
    }
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
    /// A note in the header after acting on one change (`NoteClock` puts it away).
    enum Note: Equatable { case reverted, unsaved }
    var note: Note?
    /// Undoes the last Revert Change (the note's Undo).
    @ObservationIgnored var undo: (() -> Void)?
    /// Each row's drawn text, built once per theme and layout.
    @ObservationIgnored var textCache: [Int: (old: NSAttributedString?, new: NSAttributedString?)] = [:]
    @ObservationIgnored private(set) var diff: FileDiff?
    /// The new side's lines, for unfolding the unchanged stretches (nil until read, or for a binary file).
    @ObservationIgnored private var newText: [String]?
    /// The folded stretches you opened; kept as the diff follows the disk.
    @ObservationIgnored private var expanded: Set<DiffGap> = []
    @ObservationIgnored private weak var files: FilesCenter?
    @ObservationIgnored private var observer: Observing?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var colouring: Task<Void, Never>?

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
    var language: CodeLanguage { LanguageRegistry.shared.detect(fileName: name) }

    private var repository: Repository? { files?.repository(containing: URL(fileURLWithPath: path)) }

    func reload() {
        guard let repository, let relative = repository.relativePath(of: URL(fileURLWithPath: path)) else { return }
        let untracked = repository.status?.untracked.contains { $0.path == relative } ?? false
        let conflicted = repository.status?.entries.contains { $0.path == relative && $0.isConflicted } ?? false
        let path = path, staged = staged
        loading?.cancel()
        loading = Task { [weak self] in
            let text = untracked && !staged ? nil : await repository.diff(path: relative, staged: staged)
            // The new side: the index for staged changes, else the file on disk.
            let index = staged ? await repository.indexText(path: relative) : nil
            let (diff, newText): (FileDiff?, [String]?) = await Task.detached(priority: .userInitiated) {
                let disk = FileManager.default.contents(atPath: path).flatMap { data -> String? in
                    if case .text(let file) = TextFile.read(data) { return file.text }
                    return nil
                }
                let lines = (staged ? index : disk).map(DiffModel.lines)
                if let text { return (UnifiedDiff.parse(text).first, lines) }
                // A new file that is not text (a picture): binary, not "No changes".
                guard let disk else { return (FileManager.default.fileExists(atPath: path) ? FileDiff(oldPath: nil, newPath: relative, isBinary: true) : nil, nil) }
                return (UnifiedDiff.addedFile(path: relative, text: disk), lines)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isNewFile = untracked
            self.isConflicted = conflicted || diff?.isCombined == true
            self.newText = newText
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
        // The unchanged stretches between changes folded (`DiffLayout.folded`), unless opened.
        let rows = DiffLayout.folded(layout == .sideBySide ? DiffLayout.sideBySide(diff) : DiffLayout.inline(diff),
                                     diff: diff, newText: isConflicted ? nil : newText, expanded: expanded)
        self.rows = rows
        colour(rows)
    }

    /// Tokenizes the rows off the main thread, then colours them: each side in order, its state carried
    /// down the hunk, so strings and comments that span lines colour as they do in the editor. The rows
    /// show plain until then.
    private func colour(_ rows: [DiffRow]) {
        colouring?.cancel()
        let language = language
        colouring = Task { [weak self] in
            guard let tokenizer = await GrammarStore.shared.tokenizer(for: language) else {
                self?.tokens = [:]
                return
            }
            let tokens = await Task.detached(priority: .userInitiated) { Self.tokenize(rows, tokenizer) }.value
            guard let self, !Task.isCancelled else { return }
            self.textCache.removeAll()
            self.tokens = tokens
        }
    }

    nonisolated private static func tokenize(_ rows: [DiffRow], _ tokenizer: TextMateTokenizer) -> [Int: (old: [SyntaxToken], new: [SyntaxToken])] {
        var oldState: StateStack?, newState: StateStack?
        var tokens: [Int: (old: [SyntaxToken], new: [SyntaxToken])] = [:]
        for (index, row) in rows.enumerated() {
            if row.kind == .hunk || row.kind == .gap {
                oldState = nil
                newState = nil
                continue
            }
            var pair: (old: [SyntaxToken], new: [SyntaxToken]) = ([], [])
            // An unchanged line in the same state on both sides is tokenized once.
            let sameStart = oldState == newState
            if let old = row.old {
                let result = tokenizer.tokenize(old.text, state: oldState)
                pair.old = result.tokens
                oldState = result.end
            }
            if let new = row.new {
                if row.kind == .context, let old = row.old, old.text == new.text, sameStart {
                    pair.new = pair.old
                    newState = oldState
                } else {
                    let result = tokenizer.tokenize(new.text, state: newState)
                    pair.new = result.tokens
                    newState = result.end
                }
            }
            tokens[index] = pair
        }
        return tokens
    }

    /// Opens a folded stretch: its lines show in place.
    func unfold(_ gap: DiffGap) {
        expanded.insert(gap)
        textCache.removeAll()
        relayout(layout)
    }

    /// One change can be staged, unstaged or reverted on its own: a text file git already tracks, not in
    /// conflict, neither added, deleted nor renamed (`FileDiff.acceptsChangePatches`).
    var actsOnChanges: Bool { diff?.acceptsChangePatches == true && !isNewFile && !isConflicted }

    /// The patch of the change in `rows` (`DiffPatch`).
    func patch(for rows: ClosedRange<Int>, direction: DiffPatch.Direction) -> String? {
        guard let diff, rows.upperBound < self.rows.count else { return nil }
        let lines = DiffLayout.changedLines(self.rows[rows])
        return DiffPatch.patch(diff, old: lines.old, new: lines.new, direction: direction)
    }

    /// A text's lines as git counts them: no line breaks, none after a final one.
    nonisolated static func lines(_ text: String) -> [String] {
        var lines = UnifiedDiff.lineSlices(text).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        if lines.last == "" { lines.removeLast() }
        return lines
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
        case .gap: return String(localized: "\(row.gap?.count ?? 0) unchanged lines, folded", comment: "Accessibility: a folded stretch of a diff")
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

        if row.kind == .gap, let gap = row.gap {
            // "⋯ 120 unchanged lines": a quiet band; a click opens it.
            tint(foreground, 0.04).setFill()
            bounds.fill()
            let label = String(localized: "⋯  \(gap.count) unchanged lines", comment: "Diff: a folded stretch; a click shows it")
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(10, metrics.font.pointSize - 1)), .foregroundColor: faint]
            (label as NSString).draw(at: NSPoint(x: Self.gutter * (model.layout == .sideBySide ? 1 : 2) + 2, y: 7), withAttributes: attributes)
            return
        }
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
            if color != nil {
                Palette.nsColor(diffColor(removed ? .diffRemoved : .diffInserted)).setFill()
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
        if tintColor != nil {
            Palette.nsColor(diffColor(removedSide ? .diffRemoved : .diffInserted)).setFill()
            rect.fill()
        }
        let numbers: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: metrics.font.pointSize - 1, weight: .regular), .foregroundColor: faint]
        draw(number: cell.number, right: rect.minX + Self.gutter - 8, y: 2, attributes: numbers)
        let text = attributed(cell, old: removedSide, color: tintColor, strength: strength, background: background, metrics: metrics)
        text.draw(with: NSRect(x: rect.minX + Self.gutter, y: 2, width: rect.width - Self.gutter - 8, height: rect.height), options: [.usesLineFragmentOrigin])
    }

    /// The theme's tint for added and removed lines and their changed words (`EditorColorKey.diffInserted` …).
    private func diffColor(_ key: EditorColorKey) -> WhiskrKit.RGBColor {
        ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance)).editor[key]
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
        let dark = Palette.isDark(effectiveAppearance)
        for token in tokens where token.range.upperBound <= length {
            let look = style.look(token.scopes)
            guard !look.isPlain else { continue }
            let range = NSRange(location: token.range.lowerBound, length: token.range.count)
            if let color = look.color { text.addAttribute(.foregroundColor, value: color, range: range) }
            let fontStyle = look.fontStyle(dark: dark)
            if !fontStyle.intersection([.bold, .italic]).isEmpty { text.addAttribute(.font, value: style.font(metrics.font, fontStyle), range: range) }
            if fontStyle.contains(.underline) { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if fontStyle.contains(.strikethrough) { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        if let changed = cell.changed, color != nil, changed.upperBound <= length {
            text.addAttribute(.backgroundColor, value: Palette.nsColor(diffColor(old ? .diffRemovedText : .diffInsertedText)),
                              range: NSRange(location: changed.lowerBound, length: changed.count))
        }
        var entry = model?.textCache[index] ?? (nil, nil)
        if old { entry.old = text } else { entry.new = text }
        model?.textCache[index] = entry
        return text
    }
}

/// The diff's header: the file, which changes these are, how many lines, the layout, and next/previous;
/// in a split tab, Zoom Pane and Close Pane (`PaneHeaderTools`).
private struct DiffHeader: View {
    let model: DiffModel
    let workbench: Workbench
    let page: UUID
    @Bindable private var preferences = EditorPreferences.shared

    init(model: DiffModel, workbench: Workbench, page: UUID) {
        self.model = model
        self.workbench = workbench
        self.page = page
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
                Text(verbatim: "+\(model.added)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color(nsColor: EditorStyle.shared.color(scope: "markup.inserted")))
                Text(verbatim: "−\(model.removed)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color(nsColor: EditorStyle.shared.color(scope: "markup.deleted")))
            }
            Spacer(minLength: 12)
            if let note = model.note {
                ChangeNote(note: note, undo: { model.undo?() }, close: { model.note = nil })
            }
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
            PaneHeaderTools(workbench: workbench, id: page)
        }
        .padding(.leading, 12)
        .padding(.trailing, PaneHeaderPlace.inSplit(workbench, page) ? Look.Space.s : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paneHeaderFocus(workbench: workbench, id: page)
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

/// "Change reverted · Undo", or why a change could not be reverted; gone after it has been read
/// (`NoteClock`).
private struct ChangeNote: View {
    let note: DiffModel.Note
    let undo: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: Look.Space.s) {
            switch note {
            case .reverted:
                Text(String(localized: "Change reverted", comment: "Diff header note after Revert Change")).foregroundStyle(Color.ink2)
                Button(String(localized: "Undo"), action: undo).buttonStyle(.link)
            case .unsaved:
                Text(String(localized: "Save the file first: it has unsaved changes", comment: "Diff header note: Revert Change refused")).foregroundStyle(Color.ink2)
            }
        }
        .font(.system(size: 11))
        .noteClock(expired: close)
    }
}
