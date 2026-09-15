import AppKit
import SwiftUI
import WhiskrKit

/// The command palette (Go › Command Palette…, ⇧⌘P) and Go to (⌘P), as one overlay (docs/DESIGN.md;
/// as herdr has them): a field and a list below it, opening out of the top bar's search field as the
/// command centres of VS Code and Cursor do. Go to finds any workspace, tab, Claude or helper by name,
/// folder, branch or state ("needs you", "finished", "working", "idle"); the palette finds those and every
/// menu command, with its key. ↑ ↓ move, Return opens, Esc closes and the keyboard goes back where it was.
///
/// It comes in with a quick fade and grow from the field and goes out the same way, reversed
/// (`OverlayMotion`); the keyboard is in its field from the first frame, and back where it was the moment
/// it is put away. The list growing or shrinking moves the card's foot rather than jumping
/// (`PaletteView`).
@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    enum Mode { case commands, goTo }

    private let workbench: Workbench
    private weak var parent: NSWindow?
    private var panel: PalettePanel?
    private var model: PaletteModel?
    private weak var returnFocus: NSResponder?

    init(workbench: Workbench, window: NSWindow) {
        self.workbench = workbench
        self.parent = window
    }

    var isShown: Bool { panel != nil }

    /// Shows the overlay in `mode` (or switches it, or closes it when it is already showing that mode).
    func toggle(_ mode: Mode, query: String = "") {
        if let model, panel != nil {
            if model.mode == mode { return close() }
            model.mode = mode
            model.refresh()
            return
        }
        show(mode, query: query)
    }

    func show(_ mode: Mode, query: String = "") {
        guard let parent else { return }
        returnFocus = parent.firstResponder
        // The workspace's file list, ready by the time a letter is typed.
        if mode == .goTo, let repository = workbench.selectedRepository { Task { _ = await repository.pathIndex() } }
        let model = PaletteModel(workbench: workbench, mode: mode, menu: NSApp.mainMenu, window: parent.windowController)
        model.query = query
        model.onChoose = { [weak self] action in self?.perform(action) }
        model.onClose = { [weak self] in self?.close() }
        model.refresh()
        self.model = model
        let (panel, host) = kept ?? makePanel(model)
        kept = (panel, host)
        host.rootView = PaletteView(model: model)
        panel.card = { [weak model] in model.map(PaletteView.cardFrame) ?? .zero }
        panel.isLeaving = false
        panel.ignoresMouseEvents = false
        Self.place(panel, over: parent, margin: PaletteView.margin)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKey()
        // The field has the keyboard now, before the first frame: a key typed straight after ⌘P is the
        // query's first letter (a kept panel's view has appeared already, so its `onAppear` is not enough).
        host.view.layoutSubtreeIfNeeded()
        if let field = Self.field(in: host.view), !(panel.firstResponder is NSTextView) { panel.makeFirstResponder(field) }
        self.panel = panel
        if parent.isVisible && !DebugPlaces.isBackground { panel.orderFront(nil) }
        if let layer = host.view.layer { OverlayMotion.appear(layer) }
    }

    /// The overlay's panel and its SwiftUI host, made once and kept between showings: making them on every
    /// ⌘P held the main thread 20 to 30 ms before Go to's first frame.
    private var kept: (panel: PalettePanel, host: NSHostingController<PaletteView>)?

    /// The panel keeps one size, room for the longest list; the card inside it draws its own shadow and
    /// takes the list's height as it changes, so neither the window nor its shadow is resized as you type.
    private func makePanel(_ model: PaletteModel) -> (PalettePanel, NSHostingController<PaletteView>) {
        let panel = PalettePanel(contentRect: NSRect(origin: .zero, size: PaletteView.panelSize),
                                 styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        let host = NSHostingController(rootView: PaletteView(model: model))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(PaletteView.panelSize)
        host.view.wantsLayer = true
        return (panel, host)
    }

    /// The first text field in `view` (SwiftUI's field is AppKit's underneath).
    private static func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews { if let found = field(in: subview) { return found } }
        return nil
    }

    /// Hung from the top bar's search field, as VS Code's and Cursor's command centres open: the card's top
    /// on the field's, centred on it, so the field seems to open into the list. `margin` is the room the
    /// panel keeps round its card for the shadow. (The worktree panel opens in the same place.)
    static func place(_ panel: NSPanel, over window: NSWindow, margin: CGFloat) {
        let frame = window.frame
        let bar = (window.contentViewController as? FrameController)?.topBar
        let anchor = bar.flatMap { bar -> NSRect? in
            guard bar.window === window else { return nil }
            return window.convertToScreen(bar.convert(bar.bounds, to: nil))
        }
        let size = panel.frame.size
        let middle = anchor?.midX ?? frame.midX
        let top = (anchor?.maxY ?? frame.maxY) - GoToField.inset + margin
        let x = min(max(middle - size.width / 2, frame.minX + Look.Space.m - margin), frame.maxX - Look.Space.m + margin - size.width)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    }

    /// Put away: the keyboard back where it was at once, the picture going out the way it came in. While
    /// it fades it takes no click and no key, and a new one can open over it.
    func close() {
        guard let panel else { return }
        self.panel = nil
        model = nil
        panel.isLeaving = true
        panel.ignoresMouseEvents = true
        if let parent, parent.isVisible {
            parent.makeKey()
            if let returnFocus { parent.makeFirstResponder(returnFocus) }
        }
        let parent = parent
        let gone = { @MainActor [weak self, weak parent] in
            // Opened again while it faded: it stays.
            guard self?.panel !== panel else { return }
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        guard panel.isVisible, let layer = panel.contentView?.layer else { return gone() }
        OverlayMotion.disappear(layer, done: gone)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere closes it, as Spotlight does (not while a debug snapshot holds it open).
        guard !DebugPlaces.isBackground else { return }
        close()
    }

    private func perform(_ action: PaletteModel.Action) {
        close()
        switch action {
        case .command(let item, let target):
            guard let menuAction = item.action else { return }
            NSApp.sendAction(menuAction, to: target, from: item)
        case .workspace(let id):
            if let workspace = workbench.workspaces.first(where: { $0.id == id }) { workbench.select(workspace: workspace) }
        case .tab(let id):
            if let tab = workbench.workspaces.lazy.flatMap(\.tabs).first(where: { $0.id == id }) { workbench.select(tab: tab) }
        case .pane(let id, let agent):
            workbench.selectPane(id, agent: agent)
        case .file(let path, let line, let column):
            workbench.open(file: path, mode: .keep, line: line, column: column)
        case .line(let line, let column):
            // ":42": the file shown in the tab, at that line.
            guard let id = workbench.focusedPageID, case .file(let path) = workbench.pages[id] else { return AlertCenter.beep() }
            workbench.open(file: path, mode: .keep, line: line, column: column)
        }
    }

    /// Debug: what the overlay looks like now, for a snapshot.
    var panelForSnapshot: NSWindow? { panel }
}

/// Debug runs keep every window behind the user's: the overlay is then laid out but never ordered front.
enum DebugPlaces {
    static var isBackground: Bool {
        #if DEBUG
        DebugScenario.keepsInBackground
        #else
        false
        #endif
    }
}

/// A panel that takes the keyboard although it has no title bar.
final class PalettePanel: NSPanel {
    /// Where the card is in the panel's content (the rest of the panel is the shadow's room, and clear).
    var card: () -> NSRect = { .zero }
    /// Put away and fading out: it never takes the keyboard back.
    var isLeaving = false

    override var canBecomeKey: Bool { !isLeaving }
    override func cancelOperation(_ sender: Any?) {
        (delegate as? PaletteController)?.close()
    }

    /// A click in the clear room round the card is a click outside it: it puts the overlay away, as one on
    /// the window behind does.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let content = contentView,
           !card().contains(Self.fromTop(content.convert(event.locationInWindow, from: nil), in: content)) {
            return (delegate as? PaletteController)?.close() ?? ()
        }
        super.sendEvent(event)
    }

    /// A point in `view`, measured from its top.
    private static func fromTop(_ point: NSPoint, in view: NSView) -> NSPoint {
        view.isFlipped ? point : NSPoint(x: point.x, y: view.bounds.height - point.y)
    }
}

/// What the overlay lists and what choosing a row does.
@MainActor @Observable
final class PaletteModel {
    enum Action {
        /// A menu item, and what carries it out (its own target, or the main window's controller).
        case command(NSMenuItem, AnyObject?)
        case workspace(UUID)
        case tab(UUID)
        case pane(UUID, agent: String?)
        case file(String, line: Int? = nil, column: Int? = nil)
        /// ":42" in Go to: a line of the file shown.
        case line(Int, column: Int?)
    }

    struct Row: Identifiable {
        let id: String
        let entry: PaletteEntry
        let offsets: [Int]
        let key: String?
        let action: Action
    }

    struct Section: Identifiable {
        let id: String
        let title: String?
        let rows: [Row]
    }

    var mode: PaletteController.Mode
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            movedByHand = false
            refresh()
        }
    }
    /// The highlight was moved with the arrows or the pointer: results arriving later leave it there.
    @ObservationIgnored private var movedByHand = false
    /// Files matching the query, found off the main thread (Go to only).
    private var fileRows: [Row] = []
    @ObservationIgnored private var fileSearch: Task<Void, Never>?
    private(set) var sections: [Section] = []
    var highlighted: String?
    @ObservationIgnored var onChoose: (Action) -> Void = { _ in }
    @ObservationIgnored var onClose: () -> Void = {}

    @ObservationIgnored private let workbench: Workbench
    @ObservationIgnored private var entries: [PaletteEntry] = []
    @ObservationIgnored private var actions: [String: Action] = [:]
    @ObservationIgnored private var keys: [String: String] = [:]

    @ObservationIgnored private weak var window: NSWindowController?

    init(workbench: Workbench, mode: PaletteController.Mode, menu: NSMenu?, window: NSWindowController?) {
        self.workbench = workbench
        self.mode = mode
        self.window = window
        collectPlaces()
        if let menu { collectCommands(menu, path: []) }
    }

    var rows: [Row] { sections.flatMap(\.rows) }

    /// The list's height under the field: every row and section title, up to twelve rows (then it
    /// scrolls); "Nothing matches." when empty.
    var listHeight: CGFloat {
        guard !rows.isEmpty else { return PaletteView.emptyHeight }
        let titles = sections.filter { $0.title != nil }.count
        return min(CGFloat(rows.count) * PaletteView.rowHeight + CGFloat(titles) * PaletteView.titleHeight + 12, PaletteView.listMost)
    }

    /// What is typed, read for its prefix (`GoToQuery`): ">" lists the commands (deleting it comes back),
    /// ":42" goes to a line of the file shown, "name:42" opens a file at a line. The palette itself takes
    /// a leading ">" as typed out of habit.
    private var parsed: GoToQuery {
        guard mode == .goTo else {
            let text = query.trimmingCharacters(in: .whitespaces)
            return .commands(text.hasPrefix(">") ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text)
        }
        return GoToQuery(query)
    }

    /// The list being searched: commands after ">", else the overlay's own.
    var listMode: PaletteController.Mode {
        if case .commands = parsed { return .commands }
        return mode
    }

    /// The words searched for, without a prefix or a line.
    private var searchText: String {
        switch parsed {
        case .search(let text), .commands(let text), .fileAtLine(let text, _, _): text
        case .line: ""
        }
    }

    var placeholder: String {
        listMode == .goTo
            ? String(localized: "Go to a file, workspace, tab or Claude…", comment: "Go to's field, before anything is typed")
            : String(localized: "Type a command or a place…", comment: "The command palette's field, before anything is typed")
    }

    func refresh() {
        let now = Date()
        let mode = listMode
        let query = searchText
        if case .line(let line, let column) = parsed {
            sections = [Section(id: "line", title: nil, rows: [lineRow(line, column: column)])]
            highlighted = rows.first?.id
            return
        }
        let usable = entries.filter { mode == .commands || $0.kind.isPlace }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = PaletteRanking.sections(usable, recent: workbench.visitedTabs.dropFirst().map { "tab:\($0)" }, usage: workbench.paletteUsage, now: now)
            var list: [Section] = []
            func add(_ id: String, _ title: String, _ entries: [PaletteEntry]) {
                if !entries.isEmpty { list.append(Section(id: id, title: title, rows: entries.map { row($0, []) })) }
            }
            add("waiting", String(localized: "Waiting", comment: "Palette section: requests and finished turns"), parts.waiting)
            add("pinned", String(localized: "Pinned", comment: "Palette section: pinned Claudes"), parts.pinned)
            add("recent", String(localized: "Recent", comment: "Palette section: tabs visited lately"), parts.recent)
            if mode == .goTo {
                let shown = Set(list.flatMap(\.rows).map(\.id))
                let recentFiles = recentFileRows()
                if !recentFiles.isEmpty { list.append(Section(id: "recent-files", title: String(localized: "Recent Files", comment: "Palette section: files opened lately"), rows: recentFiles)) }
                add("workspaces", String(localized: "Workspaces", comment: "Palette section"), usable.filter { $0.kind == .workspace && !shown.contains($0.id) })
            } else {
                // Until some have been used, the everyday ones.
                let everyday = Self.everyday.compactMap { name in usable.first { $0.id.hasPrefix("command:\(name):") } }
                let commands = parts.commands.isEmpty ? everyday : parts.commands
                add("commands", String(localized: "Commands", comment: "Palette section: menu commands"), commands)
            }
            sections = list
        } else {
            let ranked = PaletteRanking.rank(usable, query: query, usage: workbench.paletteUsage, now: now)
            sections = [Section(id: "results", title: nil, rows: ranked.prefix(40).map { row($0.entry, $0.offsets) })]
            if mode == .goTo {
                // Places a name matches closely come first; then the files.
                let strong = Array(sections[0].rows.prefix(ranked.firstIndex { $0.offsets.isEmpty } ?? ranked.count).prefix(6))
                let rest = Array(sections[0].rows.dropFirst(strong.count))
                sections = [Section(id: "results", title: nil, rows: strong)]
                if !fileRows.isEmpty { sections.append(Section(id: "files", title: String(localized: "Files", comment: "Palette section"), rows: fileRows)) }
                if !rest.isEmpty { sections.append(Section(id: "more", title: strong.isEmpty && fileRows.isEmpty ? nil : String(localized: "More", comment: "Palette section: other places"), rows: rest)) }
                sections.removeAll { $0.rows.isEmpty }
                searchFiles()
            }
        }
        if !movedByHand || !rows.contains(where: { $0.id == highlighted }) { highlighted = rows.first?.id }
    }

    /// Looks for files matching the query in the selected workspace, off the main thread; the list is
    /// shown again when they are found (unless the query has moved on).
    private func searchFiles() {
        guard let repository = workbench.selectedRepository else { return }
        let query = searchText, typed = self.query
        var line: Int?, column: Int?
        if case .fileAtLine(_, let at, let col) = parsed { (line, column) = (at, col) }
        fileSearch?.cancel()
        fileSearch = Task { [weak self] in
            let index = await repository.pathIndex()
            let matches = await Task.detached(priority: .userInitiated) { index.search(query, limit: 30) }.value
            guard let self, !Task.isCancelled, self.query == typed else { return }
            let rows = matches.map { match in
                self.fileRow(path: repository.root.appendingPathComponent(match.path).path, relative: match.path, offsets: match.nameOffsets,
                             line: line, column: column)
            }
            guard rows.map(\.id) != self.fileRows.map(\.id) else { return }
            self.fileRows = rows
            self.refresh()
        }
    }

    private func fileRow(path: String, relative: String, offsets: [Int], line: Int? = nil, column: Int? = nil) -> Row {
        let name = (relative as NSString).lastPathComponent
        let folder = (relative as NSString).deletingLastPathComponent
        let at = line.map { String(localized: "line \($0)", comment: "Go to: a file opens at this line") }
        let entry = PaletteEntry(id: "file:\(path)", kind: .file, title: name, detail: [folder, at].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        let action = Action.file(path, line: line, column: column)
        actions[entry.id] = action
        return Row(id: entry.id, entry: entry, offsets: offsets, key: nil, action: action)
    }

    /// ":42": the one row, saying which file it goes to (or that no file is shown).
    private func lineRow(_ line: Int, column: Int?) -> Row {
        let file: String? = workbench.focusedPageID.flatMap { id in
            if case .file(let path) = workbench.pages[id] { return (path as NSString).lastPathComponent }
            return nil
        }
        let title = column.map { String(localized: "Go to Line \(line), Column \($0)", comment: "Go to: \":42:3\"") }
            ?? String(localized: "Go to Line \(line)", comment: "Go to: \":42\" in the file shown")
        let detail = file ?? String(localized: "No file is shown: type a file's name before the colon", comment: "Go to: \":42\" with no file in the tab")
        let entry = PaletteEntry(id: "line", kind: .command, title: title, detail: detail)
        return Row(id: entry.id, entry: entry, offsets: [], key: nil, action: .line(line, column: column))
    }

    /// Files opened lately in this workspace, for Go to before anything is typed.
    private func recentFileRows() -> [Row] {
        guard let repository = workbench.selectedRepository else { return [] }
        return workbench.files.recentFiles.prefix(20).compactMap { path in
            guard let relative = repository.relativePath(of: URL(fileURLWithPath: path)), !relative.isEmpty else { return nil }
            return fileRow(path: path, relative: relative, offsets: [])
        }.prefix(5).map { $0 }
    }

    private func row(_ entry: PaletteEntry, _ offsets: [Int]) -> Row {
        Row(id: entry.id, entry: entry, offsets: offsets, key: keys[entry.id], action: actions[entry.id] ?? .workspace(UUID()))
    }

    func move(_ step: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        movedByHand = true
        let index = rows.firstIndex { $0.id == highlighted } ?? -1
        highlighted = rows[min(max(index + step, 0), rows.count - 1)].id
    }

    /// The pointer rests on a row.
    func highlight(_ id: String) {
        movedByHand = true
        highlighted = id
    }

    func choose(_ id: String? = nil) {
        guard let id = id ?? highlighted, let row = rows.first(where: { $0.id == id }) else { return }
        workbench.paletteUsage.record(id, now: Date())
        AppPlaces.defaults.set(workbench.paletteUsage.data, forKey: "paletteUsage")
        onChoose(row.action)
    }

    // MARK: Gathering

    private func collectPlaces() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for workspace in workbench.workspaces {
            let detail = [workspace.displayPath, workspace.branch.map { "⑂ \($0)" }].compactMap { $0 }.joined(separator: " · ")
            add(PaletteEntry(id: "workspace:\(workspace.id)", kind: .workspace, title: workspace.name, detail: detail,
                             pinned: workbench.isPinned(workspace)), .workspace(workspace.id))
            for tab in workspace.tabs {
                // A tab whose Claude stopped on an error shows "×", as the tab bar does.
                if tab.tree.panes.contains(where: { workbench.panes[$0].flatMap(workbench.session(of:))?.failed == true }) { failed.insert("tab:\(tab.id)") }
                add(PaletteEntry(id: "tab:\(tab.id)", kind: .tab, title: workbench.title(of: tab),
                                 detail: "\(workspace.name) · \(Places.abbreviate(workbench.panes[tab.focusedPane]?.currentFolder ?? workspace.folder, home: home))",
                                 status: workbench.status(of: tab), tab: "tab:\(tab.id)"), .tab(tab.id))
            }
        }
        for row in workbench.agentRows {
            let pinned = workbench.pinnedPanes.contains(row.id)
            if workbench.panes[row.id].flatMap(workbench.session(of:))?.failed == true { failed.insert("claude:\(row.id)") }
            add(PaletteEntry(id: "claude:\(row.id)", kind: .claude, title: row.name, detail: "\(row.workspaceName) · \(row.line)",
                             keywords: Self.stateWords(row.status), status: row.status, pinned: pinned, since: row.since,
                             tab: workbench.workspace(of: row.id).map { "tab:\($0.1.id)" }), .pane(row.id, agent: nil))
            for helper in row.helpers {
                add(PaletteEntry(id: "helper:\(row.id)/\(helper.id)", kind: .helper, title: helper.kind,
                                 detail: String(localized: "Helper · \(row.workspaceName) · \(helper.line)", comment: "Go to: a helper's detail"),
                                 keywords: [String(localized: "helper")], status: helper.status), .pane(row.id, agent: helper.id))
            }
        }
    }

    /// The commands offered before any has been used.
    static let everyday = ["newWorkspace:", "newTab:", "openFolder:", "splitRight:", "goToNextThing:", "showSettings:"]

    /// Claudes whose turn stopped on an error (shown with "×", not "!").
    @ObservationIgnored private(set) var failed: Set<String> = []

    /// The words a state is found by, in the app's own vocabulary (§1) and herdr's.
    static func stateWords(_ status: AgentStatus) -> [String] {
        switch status {
        case .blocked: [String(localized: "needs you", comment: "Go to: search word for a request"), String(localized: "request"), String(localized: "blocked")]
        case .done: [String(localized: "finished"), String(localized: "done")]
        case .working: [String(localized: "working")]
        case .idle: [String(localized: "idle")]
        case .unknown: [String(localized: "starting")]
        }
    }

    private func collectCommands(_ menu: NSMenu, path: [String]) {
        menu.update()
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                // Open Recent and the Services menu are lists of their own, not commands.
                guard submenu !== NSApp.servicesMenu, submenu !== MainMenu.openRecent else { continue }
                collectCommands(submenu, path: path + [item.title])
                continue
            }
            guard let action = item.action, !item.title.isEmpty,
                  action != #selector(MainWindowController.showCommandPalette(_:)), action != #selector(MainWindowController.goTo(_:)) else { continue }
            // Who carries it out: its own target, whoever the responder chain finds, or the main window's
            // controller (asked directly, so the commands are right whichever window has the keyboard).
            let target: AnyObject? = item.target ?? NSApp.target(forAction: action, to: nil, from: item) as AnyObject?
                ?? (window?.responds(to: action) == true ? window : nil)
            guard let target else { continue }
            let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? item.isEnabled
            guard enabled else { continue }
            let id = "command:\(NSStringFromSelector(action)):\(item.tag)"
            guard actions[id] == nil else { continue }
            add(PaletteEntry(id: id, kind: .command, title: item.title, detail: path.joined(separator: " › ")), .command(item, target))
            keys[id] = Self.keyText(item)
        }
    }

    private func add(_ entry: PaletteEntry, _ action: Action) {
        entries.append(entry)
        actions[entry.id] = action
    }

    /// A menu item's key as the menu shows it: "⇧⌘D".
    static func keyText(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let key: String = switch item.keyEquivalent {
        case "\r": "↩"
        case "\t": "⇥"
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "←"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "→"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "↑"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "↓"
        default: item.keyEquivalent.uppercased()
        }
        return text + key
    }
}

/// The overlay itself: a card with a field, then the rows in sections; solid, in the app's surface colour,
/// with the shadow of what floats. The panel is the size of the longest list; the card takes the list's
/// height. When the list grows or shrinks (a letter typed, ">" for the commands), the rows change at once
/// and only the card's edge moves to its new place, at `Look.Motion.standard`: the list is laid out once,
/// not on every frame.
struct PaletteView: View {
    @Bindable var model: PaletteModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 34
    static let titleHeight: CGFloat = 27
    static let fieldHeight: CGFloat = 52
    static let emptyHeight: CGFloat = 64
    /// Twelve rows; more scroll.
    static let listMost: CGFloat = rowHeight * 12
    /// Room round the card, inside the panel, for its shadow.
    static let margin: CGFloat = 24
    static let panelSize = NSSize(width: width + 2 * margin, height: fieldHeight + 1 + listMost + 2 * margin)

    /// The card's place in the panel, measured from its top left.
    static func cardFrame(_ model: PaletteModel) -> NSRect {
        NSRect(x: margin, y: margin, width: width, height: fieldHeight + 1 + model.listHeight)
    }

    var body: some View {
        let height = Self.fieldHeight + 1 + model.listHeight
        let shape = RoundedRectangle(cornerRadius: Look.Radius.card + 2)
        // The edge moves; the rows inside are where they end from the first frame (revealed or covered).
        let edge = reduceMotion ? nil : Look.Motion.animation(Look.Motion.standard)
        ZStack(alignment: .top) {
            shape.fill(Color.surface)
                .overlay(shape.strokeBorder(Color.line))
                .frame(height: height)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                .animation(edge, value: height)
            content
                .frame(height: height, alignment: .top)
                .mask(alignment: .top) { shape.frame(height: height).animation(edge, value: height) }
        }
        .frame(width: Self.width, height: Self.fieldHeight + 1 + Self.listMost, alignment: .top)
        .padding(Self.margin)
        .onAppear { fieldFocused = true }
        // Each showing is a card of its own (the panel is kept): it opens at its height, not easing from
        // the last one's, and its field takes the keyboard as it appears.
        .id(ObjectIdentifier(model))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.mode == .goTo ? String(localized: "Go to") : String(localized: "Command Palette"))
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.listMode == .goTo ? "arrow.right.circle" : "command")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.ink3)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(Look.Motion.animation(Look.Motion.quick), value: model.listMode == .goTo)
                TextField(model.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($fieldFocused)
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onSubmit { model.choose() }
                    .onExitCommand { model.onClose() }
                    .accessibilityLabel(model.placeholder)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.fieldHeight)
            Color.line.frame(height: 1)
            if model.rows.isEmpty {
                Text(String(localized: "Nothing matches.", comment: "Palette: no results"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink3)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.emptyHeight)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.sections) { section in
                                if let title = section.title {
                                    Text(title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.ink3)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 8)
                                        .padding(.bottom, 4)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                ForEach(section.rows) { row in
                                    PaletteRowView(row: row, failed: model.failed.contains(row.id), highlighted: row.id == model.highlighted)
                                        .id(row.id)
                                        .onTapGesture { model.choose(row.id) }
                                        .onHover { if $0 { model.highlight(row.id) } }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(height: model.listHeight)
                    .onChange(of: model.highlighted) { _, id in if let id { reader.scrollTo(id) } }
                }
            }
        }
        .frame(width: Self.width)
    }
}

/// One row: what it is (its state mark, or an icon), its name with the typed letters in bold, where it
/// is, and its key or state on the right.
private struct PaletteRowView: View {
    let row: PaletteModel.Row
    let failed: Bool
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            title
                .font(.system(size: 13))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .layoutPriority(1)
            if !row.entry.detail.isEmpty {
                Text(row.entry.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if row.entry.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color.ink3).rotationEffect(.degrees(30))
            }
            if let key = row.key {
                Text(key).font(.system(size: 12)).foregroundStyle(Color.ink3)
            } else if let status = row.entry.status, row.entry.kind != .command, status == .blocked || status == .done || status == .working {
                Text(failed ? String(localized: "Error") : status.label).font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Color.accentColor.opacity(0.16) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        if let status = row.entry.status, status == .blocked || status == .done, row.entry.kind == .claude || row.entry.kind == .tab {
            StateMark(status: status, failed: failed)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.ink2)
        } else {
            FileIconView(name: (row.entry.title as NSString).lastPathComponent, size: 13)
                .foregroundStyle(Color.ink2)
        }
    }

    /// The symbol of what the row is; a file shows its own icon instead.
    private var symbol: String? {
        switch row.entry.kind {
        case .file: nil
        case .workspace: "square.on.square"
        case .tab: "rectangle.topthird.inset.filled"
        case .claude: "pawprint"
        case .helper: "pawprint.fill"
        case .command: "command"
        }
    }

    private var title: Text {
        var text = AttributedString(row.entry.title)
        let bold = Set(row.offsets)
        for (index, position) in text.characters.indices.enumerated() where bold.contains(index) {
            text[position..<text.characters.index(after: position)].font = .system(size: 13, weight: .bold)
        }
        return Text(text)
    }
}
