import AppKit
import SwiftTerm
import WhiskrKit

// What a person does to a terminal beyond typing: find (⌘F), go from command to command (⌘↑ ⌘↓) and
// select what one printed (⇧⌘↑ ⇧⌘↓), the right-click menu, and links (⌘ held over a path or a web
// link underlines it; ⌘-click opens it). Nothing here runs while output streams in or keys are typed:
// each piece is worked out when it is asked for.
extension TerminalSurface {
    // MARK: Find

    /// Edit › Find: the app's find bar (`TerminalFindBar`) over SwiftTerm's own search.
    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag) else { return }
        switch action {
        case .showFindInterface, .showReplaceInterface: showFind()
        case .nextMatch: stepFind(forward: true)
        case .previousMatch: stepFind(forward: false)
        case .setSearchString: useSelectionForFind()
        case .hideFindInterface: hideFind()
        default: break
        }
    }

    /// Shows the bar with the keyboard in it: with the selection, else the text last searched for anywhere.
    func showFind() {
        let bar = findBar ?? makeFindBar()
        let selected = getSelection().flatMap { $0.contains("\n") ? nil : $0 }
        if let initial = selected ?? (bar.isHidden || bar.text.isEmpty ? Self.findPasteboardText : nil), !initial.isEmpty {
            bar.text = initial
        }
        bar.isHidden = false
        bar.focus()
        if !bar.text.isEmpty { search(bar.text) }
    }

    /// Closes the bar and gives the keyboard back to the terminal; the match stays selected.
    func hideFind() {
        guard let bar = findBar, !bar.isHidden else { return }
        bar.isHidden = true
        window?.makeFirstResponder(self)
    }

    var isFindShown: Bool { findBar.map { !$0.isHidden } ?? false }

    private func makeFindBar() -> TerminalFindBar {
        let bar = TerminalFindBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Look.Space.xs),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Look.Space.m),
        ])
        bar.onSearch = { [weak self] text in self?.search(text) }
        bar.onStep = { [weak self] forward in self?.stepFind(forward: forward) }
        bar.onClose = { [weak self] in self?.hideFind() }
        findBar = bar
        return bar
    }

    /// As you type: the first match from where the terminal is, and how many there are.
    private func search(_ text: String) {
        guard !text.isEmpty else {
            clearSearch()
            findBar?.showCount(nil)
            return
        }
        Self.findPasteboardText = text
        _ = findNext(text)
        findBar?.showCount(searchMatchSummary(text))
    }

    /// ⌘G and ⇧⌘G, Return and ⇧Return in the bar: the next or previous match, with the bar open or not.
    func stepFind(forward: Bool) {
        let text = isFindShown ? findBar?.text ?? "" : Self.findPasteboardText ?? ""
        guard !text.isEmpty else { return NSSound.beep() }
        Self.findPasteboardText = text
        let found = forward ? findNext(text) : findPrevious(text)
        if isFindShown { findBar?.showCount(searchMatchSummary(text)) }
        if !found { NSSound.beep() }
    }

    /// ⌘E: the selection becomes what Find looks for, here and in every other app.
    private func useSelectionForFind() {
        guard let selected = getSelection(), !selected.isEmpty else { return }
        Self.findPasteboardText = selected
        if isFindShown {
            findBar?.text = selected
            search(selected)
        }
    }

    /// The text the Mac's find pasteboard holds: one search shared by every app.
    static var findPasteboardText: String? {
        get { NSPasteboard(name: .find).string(forType: .string) }
        set {
            guard let newValue, newValue != findPasteboardText else { return }
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setString(newValue, forType: .string)
        }
    }

    // MARK: Commands

    /// Go › Previous Command (⌘↑): the prompt before the top of the view scrolls to the top.
    @objc func jumpToPreviousCommand(_ sender: Any?) {
        guard let row = previousSemanticPromptRow() else { return NSSound.beep() }
        scrollTo(row: row)
    }

    /// Go › Next Command (⌘↓).
    @objc func jumpToNextCommand(_ sender: Any?) {
        guard let row = nextSemanticPromptRow() else { return NSSound.beep() }
        scrollTo(row: row)
    }

    /// ⇧⌘↑: selects what the command before printed (the one before the last selected this way).
    @objc func selectPreviousCommandOutput(_ sender: Any?) { selectCommandOutput(backward: true) }

    /// ⇧⌘↓: what the command after the last selected printed.
    @objc func selectNextCommandOutput(_ sender: Any?) { selectCommandOutput(backward: false) }

    private func selectCommandOutput(backward: Bool) {
        guard let reach else { return NSSound.beep() }
        // The cursor's row, counted as `terminalContentSnapshot` counts (from the first line ever kept).
        let cursor = terminalContentSnapshot(region: .viewport)?.cursorRow ?? 0
        let selected = selectedCommandPrompt
        let command: CommandMarks.Command? = reach.locked { terminal, selection in
            guard !terminal.isCurrentBufferAlternate else { return nil }
            // From the command selected last, while its selection is still there; else from the prompt.
            let reference = selection.active ? selected ?? cursor - terminal.buffer.totalLinesTrimmed : cursor - terminal.buffer.totalLinesTrimmed
            guard let command = CommandMarks.command(from: reference, backward: backward, count: Self.lineCount(terminal), row: { row in
                switch terminal.semanticRowKind(at: row) {
                case .initial: .prompt
                case .some: .promptContinued
                case nil: .other
                }
            }, isBlank: { row in
                terminal.bufferLine(atRow: row).map { $0.getTrimmedLength() == 0 } ?? true
            }) else { return nil }
            selection.setSelection(start: Position(col: 0, row: command.output.lowerBound),
                                   end: Position(col: terminal.cols, row: command.output.upperBound))
            return command
        }
        guard let command else {
            selectedCommandPrompt = nil
            return NSSound.beep()
        }
        selectedCommandPrompt = command.prompt
        // Its output's first row in view, with the prompt above it.
        if !(topRow..<topRow + terminalDimensions.rows).contains(command.output.lowerBound) {
            scrollTo(row: command.prompt)
        }
        needsDisplay = true
    }

    /// Rows in the scrollback and on screen.
    private static func lineCount(_ terminal: Terminal) -> Int {
        // SwiftTerm does not say how many lines it holds; they end where `bufferLine` stops answering.
        var low = terminal.buffer.yDisp + terminal.rows - 1, high = low + 1
        while terminal.bufferLine(atRow: high) != nil { high = high * 2 + 1 }
        while low + 1 < high {
            let middle = (low + high) / 2
            if terminal.bufferLine(atRow: middle) != nil { low = middle } else { high = middle }
        }
        return low + 1
    }

    // MARK: Cells under the pointer

    /// The cell at a point in the view: its column, and its row counted from the top of the scrollback.
    /// Called holding the terminal's lock, so the cell's size (which takes it too) is worked out before.
    func cell(at point: NSPoint, in terminal: Terminal, size: NSSize) -> Position {
        guard terminal.cols > 0, terminal.rows > 0, size.width > 0, size.height > 0 else { return Position(col: 0, row: 0) }
        let column = min(max(Int(point.x / size.width), 0), terminal.cols - 1)
        let row = min(max(Int((bounds.height - point.y) / size.height), 0), terminal.rows - 1)
        return Position(col: column, row: terminal.buffer.yDisp + row)
    }

    /// The line a cell is on, joined with the rows it wrapped onto (a long path printed across two rows is
    /// one path), and where each of its characters is drawn.
    func logicalLine(through row: Int, in terminal: Terminal) -> (text: String, cells: [Position]) {
        var first = row, last = row
        while first > 0, row - first < 8, terminal.bufferLine(atRow: first)?.isWrapped == true { first -= 1 }
        while last - row < 8, terminal.bufferLine(atRow: last + 1)?.isWrapped == true { last += 1 }
        var text = "", cells: [Position] = []
        for index in first...last {
            guard let line = terminal.bufferLine(atRow: index) else { continue }
            for column in 0..<min(line.count, terminal.cols) where line.getWidth(index: column) > 0 {
                let character = terminal.getText(for: line[column])
                let shown = character.isEmpty || character == "\u{0}" ? " " : character
                for each in shown {
                    text.append(each)
                    cells.append(Position(col: column, row: index))
                }
            }
        }
        return (text, cells)
    }

    /// The link (a path with its line, or a web link) printed under a point, and the cells it covers.
    func link(at point: NSPoint) -> (link: TerminalLink, cells: [Position])? {
        guard let reach else { return nil }
        let size = cellSize
        return reach.locked { terminal, _ in
            let cell = cell(at: point, in: terminal, size: size)
            let line = logicalLine(through: cell.row, in: terminal)
            guard let index = line.cells.firstIndex(where: { $0.row == cell.row && $0.col >= cell.col }) ?? line.cells.lastIndex(where: { $0.row == cell.row }),
                  let found = TerminalLink.link(in: line.text, at: index), linkResolves?(found) ?? true else { return nil }
            let covered = found.range.clamped(to: 0..<line.cells.count).map { line.cells[$0] }
            return (found, covered)
        }
    }

    // MARK: ⌘ and links

    /// ⌘ held over a link underlines it (`LinkUnderlineView`); `PaneCard` tells the view where the pointer
    /// is while it is over it.
    func pointerMoved(to point: NSPoint, command: Bool) {
        guard command, currentMouseMode == .off || NSEvent.modifierFlags.contains(.option), let found = link(at: point) else {
            linkUnderline?.isHidden = true
            return
        }
        let underline = linkUnderline ?? makeUnderline()
        underline.isHidden = false
        underline.show(cells: found.cells, cell: cellSize, top: topRow, height: bounds.height)
    }

    private func makeUnderline() -> LinkUnderlineView {
        let view = LinkUnderlineView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: findBar)
        linkUnderline = view
        return view
    }

    var cellSize: NSSize {
        let dimensions = terminalDimensions
        let grid = getOptimalFrameSize().size
        guard dimensions.cols > 0, dimensions.rows > 0 else { return .zero }
        return NSSize(width: grid.width / CGFloat(dimensions.cols), height: grid.height / CGFloat(dimensions.rows))
    }

    private var topRow: Int { reach?.locked { terminal, _ in terminal.buffer.yDisp } ?? 0 }

    /// ⌘-click on a link the app found opens it; anything else is SwiftTerm's (a program's own links, a
    /// selection, a click the program asked to hear).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), event.clickCount == 1, currentMouseMode == .off || event.modifierFlags.contains(.option),
           let found = link(at: point) {
            swallowsMouseUp = true
            linkUnderline?.isHidden = true
            onLink?(found.link, .open)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if swallowsMouseUp {
            swallowsMouseUp = false
            return
        }
        super.mouseUp(with: event)
    }

    // MARK: The right-click menu

    /// A right click goes to the program when it asked for clicks (a full-screen program's own menu), unless
    /// Option is held; otherwise it is the terminal's menu.
    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    /// As in Terminal: with no selection, the word under the pointer is selected first, so Copy copies it.
    override func menu(for event: NSEvent) -> NSMenu? {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let point = convert(event.locationInWindow, from: nil)
        let found = link(at: point)
        if !selectionActive, let reach {
            let size = cellSize
            reach.locked { terminal, selection in
                let cell = cell(at: point, in: terminal, size: size)
                guard let line = terminal.bufferLine(atRow: cell.row), cell.col < line.count,
                      !terminal.getText(for: line[cell.col]).trimmingCharacters(in: .whitespaces).isEmpty else { return }
                selection.selectWordOrExpression(at: cell, in: terminal.buffer)
            }
            needsDisplay = true
        }
        return TerminalMenu.make(link: found?.link) { [weak self] link, action in self?.onLink?(link, action) }
    }
}

/// What can be done with a link from the terminal: open it, show it in Files, copy its path.
enum TerminalLinkAction {
    case open, reveal, copy
}

/// The terminal's right-click menu: the link's own items first when there is one under the pointer, then
/// what a terminal does with text, then its pane (docs/DESIGN.md: short, by how often they are wanted).
enum TerminalMenu {
    static func make(link: TerminalLink?, act: @escaping (TerminalLink, TerminalLinkAction) -> Void) -> NSMenu {
        let menu = NSMenu()
        if let link {
            switch link.target {
            case .url:
                menu.addItem(closureMenuItem(title: String(localized: "Open Link", comment: "Terminal menu: opens a web link in the browser")) { act(link, .open) })
                menu.addItem(closureMenuItem(title: String(localized: "Copy Link", comment: "Terminal menu")) { act(link, .copy) })
            case .file:
                menu.addItem(closureMenuItem(title: String(localized: "Open", comment: "Terminal menu: opens the file under the pointer")) { act(link, .open) })
                menu.addItem(closureMenuItem(title: String(localized: "Reveal in Files")) { act(link, .reveal) })
                menu.addItem(closureMenuItem(title: String(localized: "Copy Path")) { act(link, .copy) })
            }
            menu.addItem(.separator())
        }
        menu.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:))))
        menu.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:))))
        menu.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:))))
        menu.addItem(.separator())
        let find = item(String(localized: "Find…"), #selector(NSResponder.performTextFinderAction(_:)))
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        menu.addItem(find)
        menu.addItem(item(String(localized: "Clear", comment: "Edit menu: clears the terminal's scrollback"), #selector(MainWindowController.clearScrollback(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Split Right"), #selector(MainWindowController.splitRight(_:))))
        menu.addItem(item(String(localized: "Split Down"), #selector(MainWindowController.splitDown(_:))))
        menu.addItem(item(String(localized: "Zoom Pane"), #selector(MainWindowController.toggleZoom(_:))))
        return menu
    }

    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }
}

/// The underline drawn under a link while ⌘ is held over it, in the accent: above the text, under the
/// find bar, never in the way of a click.
final class LinkUnderlineView: NSView {
    private var rects: [NSRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(cells: [Position], cell: NSSize, top: Int, height: CGFloat) {
        var runs: [Int: (first: Int, last: Int)] = [:]
        for position in cells {
            let run = runs[position.row] ?? (position.col, position.col)
            runs[position.row] = (min(run.first, position.col), max(run.last, position.col))
        }
        rects = runs.map { row, run in
            let y = height - CGFloat(row - top + 1) * cell.height
            return NSRect(x: CGFloat(run.first) * cell.width, y: y + 1, width: CGFloat(run.last - run.first + 1) * cell.width, height: 1)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Colors.accent.setFill()
        rects.forEach { $0.fill() }
    }
}

extension TerminalSurface {
    /// The terminal's own commands, and Find without a replace field; nil for anything else.
    func validateOwnItem(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(jumpToPreviousCommand(_:)), #selector(jumpToNextCommand(_:)),
             #selector(selectPreviousCommandOutput(_:)), #selector(selectNextCommandOutput(_:)):
            return reach != nil
        case #selector(performTextFinderAction(_:)):
            switch NSTextFinder.Action(rawValue: item.tag) {
            case .showFindInterface, .nextMatch, .previousMatch: return true
            case .setSearchString: return selectionActive
            case .hideFindInterface: return isFindShown
            default: return false
            }
        default:
            return nil
        }
    }
}
