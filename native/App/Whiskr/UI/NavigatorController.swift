import AppKit
import MeadowScene
import SwiftUI
import WhiskrKit
import WhiskrMeadow

/// The sidebar (docs/DESIGN.md): the meadow, one blanket per workspace in a column, or with
/// View › Show Workspaces as List the same workspaces as rows. It shows who needs you and takes you
/// there; it never takes the keyboard from a terminal, and nothing an agent does moves its camera.
/// What you choose on the right (a workspace, a tab, a pane, from anywhere: a click, a key, a menu, Go
/// to) the meadow follows: its blanket and cat glide comfortably into view and are ringed. A request out of
/// view shows as a capsule at that edge; a request whose terminal is not on screen is answered from a card
/// beside its cat. ⌥⌘0 puts the keyboard here: arrows, Return, Space, Esc.
final class NavigatorController: NSViewController {
    let meadow: MeadowView
    private let workbench: Workbench
    private let list: NSHostingView<WhileShown<NavigatorList>>
    private let note = HoverNote()
    private var observers: [Observing] = []
    private var zoneObserver: NSObjectProtocol?

    isolated deinit {
        if let zoneObserver { NotificationCenter.default.removeObserver(zoneObserver) }
    }
    private var scene: SceneSnapshot?
    private lazy var answerCard = AnswerCardController(workbench: workbench)
    /// The "↑ 1 needs you" capsules at the meadow's edges.
    private let edges = MeadowEdges()
    private var capsules: [NSHostingView<EdgeCapsule>] = []
    /// Your choices followed so far (`Workbench.choices`): a new one is yours to follow; anything else
    /// that changes the selection only moves the ring.
    private var choicesFollowed = 0
    /// The meadow's editor (View › Edit Meadow), which takes the meadow's keys and Edit menu while editing.
    weak var editor: EditModeController?
    private var editing: Bool { editor?.isEditing == true }

    private static let cameraKey = "meadowCamera"

    var kind: WindowLayout.Navigator = .meadow {
        didSet { if isViewLoaded { showKind() } }
    }

    init(workbench: Workbench) {
        self.workbench = workbench
        meadow = MeadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 800))
        list = NSHostingView(rootView: WhileShown(shown: false) { NavigatorList(workbench: workbench) })
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("NavigatorController is created in code")
    }

    override func loadView() {
        let container = DropView()
        container.onFolders = { [weak self] urls in urls.forEach { self?.workbench.open(folder: $0.path) } }
        container.onMeadows = { [weak self] urls in MeadowImport.shared.open(urls, over: self?.view.window) }
        container.onAppearance = { [weak self] in
            self?.applySettings()
            // The tray's pictures are drawn over the tile's colour, which follows the appearance.
            if self?.editing == true { self?.editor?.updatePictures() }
        }
        meadow.onKeyDown = { [weak self] event in self?.key(event) ?? false }
        meadow.onKeyEquivalent = { [weak self] event in self?.editor?.keyEquivalent(event) ?? false }
        meadow.onViewChanged = { [weak self] in self?.updateEdges() }
        meadow.setAccessibilityLabel(String(localized: "Workspaces", comment: "Accessibility label of the sidebar's meadow"))
        meadow.takesKeyboardFocus = false
        meadow.onSelect = { [weak self] item in self?.chose(item) }
        meadow.onHover = { [weak self] item in self?.hovered(item) }
        meadow.onContextMenu = { [weak self] item in self?.menu(for: item) }
        for part in [meadow, list] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(part)
        }
        // Each capsule in a view of its own size at its edge: one view over the whole meadow took every click
        // meant for a cat or a blanket there (and the keyboard with it).
        let reveal: @MainActor (UUID) -> Void = { [weak self] id in self?.meadow.reveal(.blanket(id.uuidString)) }
        let top = NSHostingView(rootView: EdgeCapsule(edges: edges, edge: .top, reveal: reveal))
        let bottom = NSHostingView(rootView: EdgeCapsule(edges: edges, edge: .bottom, reveal: reveal))
        for capsule in [top, bottom] {
            capsule.translatesAutoresizingMaskIntoConstraints = false
            capsule.sizingOptions = [.intrinsicContentSize]
            container.addSubview(capsule)
        }
        capsules = [top, bottom]
        container.addSubview(note)
        NSLayoutConstraint.activate([
            meadow.topAnchor.constraint(equalTo: container.topAnchor),
            meadow.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            meadow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            meadow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            list.topAnchor.constraint(equalTo: container.topAnchor),
            list.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            top.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            top.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            bottom.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        container.registerForDraggedTypes([.fileURL])
        view = container
        showKind()
        observers.append(Observing { [weak self] in
            guard let self else { return }
            self.sceneChanged(self.workbench.scene, choices: self.workbench.choices)
        })
        observers.append(Observing { [weak self] in self?.applySettings() })
        // The meadow shown (the Default or one of yours), as it changes.
        observers.append(Observing { [weak self] in
            let scenery = MeadowLibrary.shared.scenery
            // A drag under way draws its own picture of the meadow until it is let go.
            guard let self, self.editor?.showsPreview != true else { return }
            self.meadow.scenery = scenery
        })
        // Moving to another time zone moves the sun, when where you are is guessed from it.
        zoneObserver = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        // One terminal's program messaging another's (`paw`): their cats act it out.
        workbench.onPassed = { [weak self] message in self?.passed(message) }
    }

    private func showKind() {
        meadow.isHidden = kind != .meadow
        list.isHidden = kind != .list
        if list.rootView.shown != (kind == .list) { list.rootView.shown = kind == .list }
        if kind != .meadow { note.hide() }
    }

    // MARK: The model, into the meadow

    private func sceneChanged(_ snapshot: SceneSnapshot, choices: Int) {
        let chosen = choices != choicesFollowed
        choicesFollowed = choices
        // A choice of yours on the right (a workspace, a tab, Go to, ⌘J, a notification) leaves the meadow's
        // editor first: the view comes back where it was, then follows the choice.
        if chosen, editing { editor?.leave() }
        let changed = snapshot != scene
        guard changed || chosen else { return }
        scene = snapshot
        if changed { meadow.world = MeadowMapping.world(snapshot, accountColors: Colors.accountColors, machineName: String(localized: "This Mac")) }
        // What is shown is ringed: its cat, or its blanket. Your choice moves the camera to it; anything else
        // (a Claude starting beside it, a pane closing) only moves the ring (§6.5: no agent event moves the camera).
        let ring = MeadowMapping.selection(in: snapshot)
        if chosen {
            meadow.select(ring, origin: .user)
        } else if meadow.selection != ring {
            meadow.select(ring, origin: .event)
        }
        guard changed else { return }
        updateEdges()
        updateAccessibility(snapshot)
    }

    /// Workspaces with a request or an error whose blanket is out of view, by edge (not while editing: the
    /// view roams the whole meadow, and the status bar keeps counting who needs you).
    private func updateEdges() {
        guard let scene, kind == .meadow, !meadow.isHiddenOrHasHiddenAncestor, !editing else {
            edges.set(above: [], below: [])
            return
        }
        let waiting = Set(scene.spaces.filter { $0.status == .blocked }.map(\.id.uuidString))
        let out = meadow.blanketsOutOfView
        edges.set(above: out.above.filter(waiting.contains).compactMap(UUID.init(uuidString:)),
                  below: out.below.filter(waiting.contains).compactMap(UUID.init(uuidString:)))
    }

    private func applySettings() {
        let store = WorldStore.shared
        let variant = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(view.effectiveAppearance))
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let chrome = MeadowMapping.chrome(variant, focus: (Double(accent.redComponent), Double(accent.greenComponent), Double(accent.blueComponent)))
        #if DEBUG
        let stoppedAt = store.clockStoppedAt
        #else
        let stoppedAt: Date? = nil
        #endif
        let settings = MeadowMapping.settings(store.settings, weather: store.weather, chrome: chrome, timeZone: .autoupdatingCurrent, stoppedAt: stoppedAt)
        if meadow.settings != settings { meadow.settings = settings }
        if meadow.animatesAmbient != store.animatesMeadow { meadow.animatesAmbient = store.animatesMeadow }
    }

    // MARK: Choosing

    private func chose(_ item: MeadowItem?) {
        guard let item, let target = MeadowMapping.target(of: item) else {
            // Grass chooses nothing: a stray click never takes you out of your terminal (Home is ⇧⌘H).
            meadow.selection = scene.flatMap(MeadowMapping.selection(in:))
            return
        }
        switch target {
        case .blanket(let id): workbench.selectBlanket(id)
        case .pane(let id, nil) where !workbench.isVisible(id):
            // A request whose terminal is not on screen: answered from a card beside the cat (§7).
            if let request = workbench.openRequest(pane: id), let rect = meadow.screenRect(of: item) {
                answerCard.show(request, relativeTo: besideMeadow(rect), of: meadow)
            } else {
                workbench.selectPane(id, agent: nil)
            }
        case .pane(let id, let agent): workbench.selectPane(id, agent: agent)
        }
    }

    /// Opens the answer card for a pane's request, beside its cat (Debug, and the card's own tests).
    func showAnswerCard(pane id: UUID) {
        guard let request = workbench.openRequest(pane: id), let rect = meadow.screenRect(of: .cat(blanket: blanketID(of: id) ?? "", agent: id.uuidString)) else { return }
        answerCard.show(request, relativeTo: besideMeadow(rect), of: meadow)
    }

    /// The card opens over the terminals, never over the meadow (§7): it points from the meadow's edge,
    /// level with the cat.
    private func besideMeadow(_ cat: NSRect) -> NSRect {
        NSRect(x: cat.minX, y: cat.minY, width: max(1, meadow.bounds.maxX - cat.minX - 2), height: cat.height)
    }

    private func blanketID(of pane: UUID) -> String? {
        if let place = workbench.workspace(of: pane) { return place.0.id.uuidString }
        // A helper terminal with no tab sits on its boss's blanket.
        return workbench.panes[pane].flatMap { workbench.boss(of: $0) }.flatMap { workbench.workspaceOfBoss($0) }?.0.id.uuidString
    }

    /// A message, a note or a task passed from one terminal to another: the sender's cat takes it over
    /// (a helper trots to its boss to report), the receiver's turns to it.
    private func passed(_ message: PassedMessage) {
        guard let from = message.from, let fromBlanket = blanketID(of: from), let toBlanket = blanketID(of: message.to) else { return }
        meadow.passNote(from: .cat(blanket: fromBlanket, agent: MeadowMapping.catID(pane: from, agent: nil)),
                        to: .cat(blanket: toBlanket, agent: MeadowMapping.catID(pane: message.to, agent: nil)))
    }

    var answerCardWindow: NSWindow? { answerCard.cardWindow }

    /// A tab dropped on a blanket moves to that workspace (§3).
    /// The workspace whose blanket is under `point` (in the window), and the blanket's rect in the window,
    /// while the meadow is shown: where a dragged tab would move to (`TabDragging`).
    func blanket(at point: NSPoint) -> (Workspace, NSRect)? {
        guard kind == .meadow, !meadow.isHiddenOrHasHiddenAncestor, meadow.window != nil else { return nil }
        let local = meadow.convert(point, from: nil)
        guard meadow.bounds.contains(local) else { return nil }
        for workspace in workbench.workspaces {
            if let rect = meadow.screenRect(of: .blanket(workspace.id.uuidString)), rect.contains(local) {
                return (workspace, meadow.convert(rect, to: nil))
            }
        }
        return nil
    }

    // MARK: The keyboard in the meadow (§4.5)

    /// ⌥⌘0: the keyboard comes here, on the selected workspace.
    func takeKeyboard() {
        guard let window = view.window else { return }
        if kind == .list {
            window.makeFirstResponder(list)
            return
        }
        meadow.takesKeyboardFocus = true
        window.makeFirstResponder(meadow)
        // On the workspace shown, or from Home on the first.
        meadow.keyboardFocus = (workbench.selectedWorkspace ?? workbench.workspaces.first).map { .blanket($0.id.uuidString) }
        if let focus = meadow.keyboardFocus { meadow.reveal(focus) }
    }

    /// The keyboard has gone back to a terminal (Esc, Tab, Return, or a click there).
    func keyboardLeft() {
        guard meadow.takesKeyboardFocus else { return }
        meadow.takesKeyboardFocus = false
        meadow.keyboardFocus = nil
        note.hide()
    }

    /// Esc or Tab: back to the terminal, or to the Home page on Home.
    private func giveKeyboardBack() {
        keyboardLeft()
        if let pane = workbench.focusedPane { workbench.onFocusPane?(pane) } else if workbench.isHome { workbench.onFocusHome?() }
    }

    /// ↑ ↓ between workspaces, ← → through the focused workspace's cats, Return as a click, Space for
    /// its label, Esc or Tab back to the terminal (or Home); letters jump to the first workspace named so.
    private func key(_ event: NSEvent) -> Bool {
        if editing, let editor { return editor.key(event) }
        let order = workbench.workspaces.map { $0.id.uuidString }
        let focus = meadow.keyboardFocus ?? (workbench.selectedWorkspace ?? workbench.workspaces.first).map { .blanket($0.id.uuidString) }
        guard let focus, let at = order.firstIndex(of: focus.blanketID) else { return false }
        switch event.keyCode {
        case 126, 125: // ↑ ↓
            let next = order[min(max(at + (event.keyCode == 125 ? 1 : -1), 0), order.count - 1)]
            setKeyboardFocus(.blanket(next))
        case 123, 124: // ← →
            let items = [MeadowItem.blanket(focus.blanketID)] + cats(in: focus.blanketID)
            let index = items.firstIndex(of: focus) ?? 0
            setKeyboardFocus(items[(index + (event.keyCode == 124 ? 1 : -1) + items.count) % items.count])
        case 36, 76: // Return, Enter
            keyboardLeft()
            chose(focus)
        case 49: // Space
            hovered(focus, at: meadow.screenRect(of: focus).map { NSPoint(x: $0.midX, y: $0.maxY) })
        case 53, 48: // Esc, Tab
            giveKeyboardBack()
        default:
            guard let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1, typed.first?.isLetter == true,
                  let match = workbench.workspaces.first(where: { $0.name.lowercased().hasPrefix(typed) }) else { return false }
            setKeyboardFocus(.blanket(match.id.uuidString))
        }
        return true
    }

    private func setKeyboardFocus(_ item: MeadowItem) {
        meadow.keyboardFocus = item
        meadow.reveal(item)
        note.hide()
        NSAccessibility.post(element: meadow, notification: .focusedUIElementChanged)
    }

    /// The cats on a blanket, in order: each Claude, then its helpers.
    private func cats(in blanketID: String) -> [MeadowItem] {
        guard let id = UUID(uuidString: blanketID), let blanket = scene?.blanket(id) else { return [] }
        return blanket.panes.flatMap { pane -> [MeadowItem] in
            guard case .agent(_, _, _, let family) = pane.kind else { return [] }
            let agents = family.isEmpty ? [nil] : family.map { $0.parentID == nil ? nil : $0.id }
            return agents.map { .cat(blanket: blanketID, agent: MeadowMapping.catID(pane: pane.id, agent: $0)) }
        }
    }

    // MARK: VoiceOver (§12)

    /// One element per workspace, read as a sentence, with its frame in the meadow; Press selects it.
    private func updateAccessibility(_ snapshot: SceneSnapshot) {
        // While the meadow is edited VoiceOver reads its scenery (`EditModeController`).
        guard !editing else { return }
        let elements = snapshot.spaces.map { space -> MeadowAccessibilityElement in
            let element = MeadowAccessibilityElement(meadow: meadow, item: .blanket(space.id.uuidString)) { [weak self] in
                self?.workbench.selectBlanket(space.id)
            }
            element.setAccessibilityLabel(sentence(for: space))
            return element
        }
        meadow.setAccessibilityChildren(elements)
        meadow.setAccessibilityRole(.group)
    }

    /// "shop-web, branch fix-cart. Claude: needs you, wants to run npm test. 2 helpers working."
    private func sentence(for space: SceneSnapshot.Space) -> String {
        var parts = [space.name]
        if let branch = space.blankets.first?.branch { parts[0] += ", " + String(localized: "branch \(branch)", comment: "VoiceOver: a workspace's git branch") }
        for pane in space.blankets.flatMap(\.panes) {
            guard case .agent(let status, _, let failed, let family) = pane.kind else { continue }
            let state = failed ? String(localized: "Error") : status.label
            let line = family.first?.line ?? ""
            parts.append(line.isEmpty ? String(localized: "Claude: \(state)") : String(localized: "Claude: \(state), \(line)", comment: "VoiceOver: a Claude's state and what it is doing"))
            let helpers = max(0, family.count - 1)
            if helpers > 0 { parts.append(String(localized: "\(helpers) helpers working", comment: "Accessibility: helpers in a workspace")) }
        }
        // A workspace of plain terminals: what its kettle shows.
        for blanket in space.blankets {
            guard let kettle = MeadowMapping.kettle(of: blanket) else { continue }
            if kettle.running { parts.append(String(localized: "Command running", comment: "VoiceOver: a command runs in one of a workspace's plain terminals (the meadow's kettle is lit)")) }
            if kettle.failed { parts.append(String(localized: "Command failed", comment: "VoiceOver: a command failed in one of a workspace's plain terminals, not yet looked at (the meadow's kettle has its red flag)")) }
            if kettle.finished { parts.append(String(localized: "Command finished", comment: "VoiceOver: the last command in a workspace's plain terminals ended well")) }
        }
        return parts.joined(separator: ". ")
    }

    // MARK: Pointing

    private func hovered(_ item: MeadowItem?, at spot: NSPoint? = nil) {
        // A tab held over a blanket has its own label ("Move to …"); a name beside it would only crowd it.
        guard let item, !TabDragState.shared.isDragging, let scene, let hover = MeadowMapping.hover(item, in: scene), let window = view.window else {
            note.hide()
            return
        }
        let point = spot.map { view.convert($0, from: meadow) } ?? view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        note.show(title: hover.name, detail: words(for: hover, item: item), at: point, within: view.bounds)
    }

    /// The hover label, as a sentence (§2.3, §4.4).
    private func words(for hover: MeadowMapping.Hover, item: MeadowItem) -> String? {
        switch hover.kind {
        case .blanket:
            guard let target = MeadowMapping.target(of: item), case .blanket(let id) = target,
                  let workspace = workbench.workspaces.first(where: { $0.id == id }) else { return nil }
            let tabs = workspace.tabs.count
            return tabs == 1 ? workspace.displayPath : String(localized: "\(workspace.displayPath) · \(tabs) tabs", comment: "Hover label of a workspace: its folder and how many tabs")
        case .agent(let status, let line):
            let doing = line.flatMap { $0.isEmpty ? nil : $0 }
            switch status {
            case .blocked: return doing.map { String(localized: "Claude · \($0). Click to answer.", comment: "Hover label of a cat with a request") }
                ?? String(localized: "Claude needs you. Click to answer.")
            case .done: return String(localized: "Claude · Finished", comment: "Hover label of a cat whose turn finished")
            default: return doing.map { String(localized: "Claude · \($0)", comment: "Hover label of a working cat: what it is doing") } ?? String(localized: "Claude")
            }
        case .helper(let line):
            return line.isEmpty ? String(localized: "Helper") : String(localized: "Helper · \(line)", comment: "Hover label of a helper: what it is doing")
        case .lantern(.lit): return String(localized: "Running", comment: "A plain terminal with a command running in it")
        case .lantern(.dark): return String(localized: "Waiting for a command", comment: "A plain terminal whose shell waits at its prompt")
        case .lantern(.failed(let code)): return String(localized: "Exited with code \(code)")
        }
    }

    // MARK: Menus

    /// Right-click in the meadow (§4.4).
    private func menu(for item: MeadowItem?) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(closureMenuItem(title: title, action: action))
        }
        guard let item, let target = MeadowMapping.target(of: item) else {
            add(String(localized: "New Terminal")) { [weak self] in self?.workbench.newWorkspace() }
            add(String(localized: "Open Folder…")) { NSApp.sendAction(#selector(MainWindowController.openFolder(_:)), to: nil, from: nil) }
            menu.addItem(.separator())
            add(String(localized: "Edit Meadow…", comment: "The grass's menu: begins editing the meadow")) { [weak self] in self?.editor?.enter() }
            return menu
        }
        switch target {
        case .blanket(let id):
            guard let workspace = workbench.workspaces.first(where: { $0.id == id }) else { return nil }
            add(String(localized: "New Tab")) { [weak self] in
                self?.workbench.select(workspace: workspace)
                self?.workbench.newTab()
            }
            add(String(localized: "Rename Workspace…")) { [weak self] in
                self?.workbench.select(workspace: workspace)
                self?.workbench.renamingWorkspaceID = workspace.id
            }
            menu.addItem(.separator())
            WorktreeMenu.add(to: menu, workbench: workbench, workspace: workspace)
            add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.folder)]) }
            add(String(localized: "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.folder, forType: .string)
            }
            menu.addItem(.separator())
            add(String(localized: "Close Workspace")) { [weak self] in
                // That workspace closes; whichever is shown stays (Home, if it was this one).
                (self?.view.window?.windowController as? MainWindowController)?.requestClose(workspace: workspace)
            }
        case .pane(let id, let agent):
            guard let pane = workbench.panes[id] else { return nil }
            if agent == nil, pane.origin != nil {
                // A terminal a Claude started (`paw run`): look at it, give it a tab, or stop it.
                add(String(localized: "Show Terminal")) { [weak self] in self?.workbench.selectPane(id) }
                if workbench.isLooseHelper(pane) {
                    add(String(localized: "Keep as Tab")) { [weak self] in self?.workbench.keepAsTab(id) }
                }
                if let boss = workbench.boss(of: pane) {
                    add(String(localized: "Go to Boss")) { [weak self] in self?.workbench.focus(pane: boss.id) }
                }
                if pane.agentRunning, workbench.openRequest(pane: id) != nil {
                    add(String(localized: "Answer…")) { [weak self] in self?.showAnswerCard(pane: id) }
                }
                if let address = pane.address {
                    add(String(localized: "Copy Address")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }
                }
                menu.addItem(.separator())
                add(String(localized: "Stop", comment: "A helper terminal's menu: ends it")) { [weak self] in self?.workbench.stopHelper(id) }
            } else if agent == nil {
                add(String(localized: "Go to Pane")) { [weak self] in self?.workbench.focus(pane: id) }
                if pane.agentRunning {
                    if workbench.openRequest(pane: id) != nil {
                        add(String(localized: "Answer…")) { [weak self] in self?.showAnswerCard(pane: id) }
                    }
                    add(String(localized: "Interrupt")) { pane.interrupt() }
                    add(workbench.pinnedPanes.contains(id) ? String(localized: "Unpin Claude") : String(localized: "Pin Claude")) { [weak self] in
                        self?.workbench.togglePin(pane: id)
                    }
                    if workbench.canMarkUnread(pane: id) {
                        add(String(localized: "Mark as Unread")) { [weak self] in self?.workbench.markUnread(pane: id) }
                    }
                    if let id = pane.sessionID, let command = ClaudeResume.resumeCommand(sessionID: id, account: pane.sessionConfigDir.map { workbench.account(configDir: $0) }) {
                        add(String(localized: "Copy Resume Command")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                }
            } else {
                add(String(localized: "Show Story")) { [weak self] in self?.workbench.selectPane(id, agent: agent) }
                add(String(localized: "Go to Boss")) { [weak self] in self?.workbench.focus(pane: id) }
            }
        }
        return menu
    }

    // MARK: Editing the meadow

    /// The editor begins: nothing of the sidebar's own floats over the meadow meanwhile (the hover label,
    /// the edge capsules, the answer card).
    func editingWillBegin() {
        note.hide()
        answerCard.close(restoringFocus: false)
        edges.set(above: [], below: [])
        meadow.keyboardFocus = nil
    }

    /// The editor has ended: the sidebar's own VoiceOver elements and capsules back.
    func editingDidEnd() {
        if let scene { updateAccessibility(scene) }
        meadow.setAccessibilityLabel(String(localized: "Workspaces", comment: "Accessibility label of the sidebar's meadow"))
        updateEdges()
    }

    /// The Edit menu's commands reach the editor while it has the keyboard (the meadow, or its tray's shelf), and only then:
    /// elsewhere ⌘Z keeps bringing back what was closed, and ⌘C copies text.
    private nonisolated static let editorActions: Set<Selector> = [#selector(undo(_:)), #selector(redo(_:)), #selector(copy(_:)), #selector(cut(_:)),
                                                                   #selector(paste(_:)), #selector(selectAll(_:)), #selector(delete(_:))]

    /// AppKit asks on the main thread, as it walks the responder chain for a menu's action.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        if let selector, Self.editorActions.contains(selector) {
            return MainActor.assumeIsolated {
                let keyboard = view.window?.firstResponder
                return editing && (keyboard === meadow || keyboard === editor?.trayKeys)
            }
        }
        return super.responds(to: selector)
    }

    @objc func undo(_ sender: Any?) { editor?.undo() }
    @objc func redo(_ sender: Any?) { editor?.redo() }
    @objc func copy(_ sender: Any?) { editor?.copySelection() }
    @objc func cut(_ sender: Any?) { editor?.cutSelection() }
    @objc func paste(_ sender: Any?) { editor?.paste() }
    @objc override func selectAll(_ sender: Any?) { editor?.selectAll() }
    @objc func delete(_ sender: Any?) { editor?.deleteSelection() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let editor, editing else { return false }
        let undo = MeadowLibrary.shared.undoManager
        switch item.action {
        case #selector(self.undo(_:)):
            item.title = undo.undoMenuItemTitle
            return undo.canUndo
        case #selector(redo(_:)):
            item.title = undo.redoMenuItemTitle
            return undo.canRedo
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return !editor.selection.isEmpty
        case #selector(paste(_:)):
            return editor.canPaste
        case #selector(selectAll(_:)):
            return !MeadowLibrary.shared.session.drawnIDs.isEmpty
        default:
            return true
        }
    }

    // MARK: Saving and restoring

    func saveState() {
        let angle = meadow.cameraAngle
        AppPlaces.defaults.set([Double(angle.bearing), Double(angle.pitch)], forKey: Self.cameraKey)
    }

    /// After the workbench has brought back its workspaces: the camera at the angle it was left at.
    func restore() {
        _ = view
        scene = nil
        // A launch lands on Home, framing everything: nothing to follow yet.
        choicesFollowed = workbench.choices
        sceneChanged(workbench.scene, choices: workbench.choices)
        if let angle = AppPlaces.defaults.array(forKey: Self.cameraKey) as? [Double], angle.count == 2 {
            meadow.turn(toBearing: Float(angle[0]), pitch: Float(angle[1]))
        }
        meadow.frame(nil, besidePanelWidth: 0, animated: false)
    }
}

/// A menu item that runs a closure. The closure's holder is the item's target, kept alive by the item.
func closureMenuItem(title: String, action run: @escaping () -> Void) -> NSMenuItem {
    let holder = MenuAction(run)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
    item.target = holder
    item.representedObject = holder
    return item
}

final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// A view that opens folders dropped on it as workspaces, and imports meadow files dropped on it (each through
/// the import sheet).
final class DropView: NSView {
    var onFolders: (([URL]) -> Void)?
    var onMeadows: (([URL]) -> Void)?
    var onAppearance: (() -> Void)?

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func folders(_ info: NSDraggingInfo) -> [URL] {
        urls(info).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !MeadowLibraryActions.meadowFiles(urls(sender)).isEmpty { return .copy }
        return folders(sender).isEmpty ? [] : .link
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let meadows = MeadowLibraryActions.meadowFiles(urls(sender))
        if !meadows.isEmpty {
            onMeadows?(meadows)
            return true
        }
        let found = folders(sender)
        guard !found.isEmpty else { return false }
        onFolders?(found)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearance?()
    }
}

/// The name label shown while pointing at a blanket, cat or lantern: solid, in the theme's ink, beside
/// the pointer and never under it.
final class HoverNote: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private static let inset = NSEdgeInsets(top: 6, left: 10, bottom: 7, right: 11)
    private static let widest: CGFloat = 280

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        detail.font = .systemFont(ofSize: 11.5)
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("HoverNote is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(title text: String, detail words: String?, at point: NSPoint, within area: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Colors.text.cgColor
            layer?.shadowColor = NSColor.black.cgColor
        }
        title.textColor = Colors.surface
        detail.textColor = Colors.surface.withAlphaComponent(0.78)
        title.stringValue = text
        detail.stringValue = words ?? ""
        detail.isHidden = (words ?? "").isEmpty
        let inset = Self.inset
        let titleSize = title.fittingSize
        let detailSize = detail.isHidden ? .zero : detail.fittingSize
        let textWidth = min(max(titleSize.width, detailSize.width), Self.widest - inset.left - inset.right)
        let height = inset.top + titleSize.height + (detail.isHidden ? 0 : 1 + detailSize.height) + inset.bottom
        let width = textWidth + inset.left + inset.right
        detail.frame = NSRect(x: inset.left, y: inset.bottom, width: textWidth, height: detailSize.height)
        title.frame = NSRect(x: inset.left, y: height - inset.top - titleSize.height, width: textWidth, height: titleSize.height)
        var origin = NSPoint(x: point.x + 14, y: point.y + 14)
        if origin.x + width > area.maxX - 8 { origin.x = point.x - 14 - width }
        if origin.y + height > area.maxY - 8 { origin.y = point.y - 18 - height }
        origin.x = max(area.minX + 8, origin.x)
        origin.y = max(area.minY + 8, origin.y)
        frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}

/// The workspaces with a request out of the meadow's view, at each edge.
@MainActor @Observable
final class MeadowEdges {
    private(set) var above: [UUID] = []
    private(set) var below: [UUID] = []

    func set(above: [UUID], below: [UUID]) {
        if self.above != above { self.above = above }
        if self.below != below { self.below = below }
    }
}

/// "↑ 1 needs you" at the top edge, "↓ 2 need you" at the bottom (§4.1): vermillion text on the surface,
/// only while a blanket with a request is out of view; a click scrolls to the nearest. One for each edge,
/// each as large as itself, so the meadow around it keeps its clicks.
struct EdgeCapsule: View {
    enum Edge { case top, bottom }

    let edges: MeadowEdges
    let edge: Edge
    let reveal: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let waiting = edge == .top ? edges.above : edges.below
        ZStack {
            // The nearest: the lowest of those above, the highest of those below.
            if let nearest = edge == .top ? waiting.last : waiting.first {
                capsule(arrow: edge == .top ? "arrow.up" : "arrow.down", count: waiting.count) { reveal(nearest) }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: waiting.count)
    }

    private func capsule(arrow: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(String(localized: "\(count) need you", comment: "Meadow edge capsule: requests out of view"), systemImage: arrow)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StateMark.vermillion)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(Color.surface))
                .overlay(Capsule().strokeBorder(Color.line))
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                .frame(minHeight: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // A click scrolls the meadow and leaves the keyboard where it was (in the terminal); ⌘J is the key.
        .focusable(false)
        .help(String(localized: "Scroll to it"))
    }
}

/// A workspace in the meadow as VoiceOver sees it: its sentence, where its blanket is, and Press.
/// AppKit asks for these on the main thread.
nonisolated final class MeadowAccessibilityElement: NSAccessibilityElement {
    /// Where its blanket is drawn, on the screen (nil: not drawn), asked of the meadow, kept weakly.
    private let frame: @MainActor @Sendable () -> NSRect?
    private let press: @MainActor @Sendable () -> Void

    init(meadow: MeadowView, item: MeadowItem, press: @escaping @MainActor @Sendable () -> Void) {
        frame = { [weak meadow] in
            guard let meadow, let rect = meadow.screenRect(of: item), let window = meadow.window else { return nil }
            return window.convertToScreen(meadow.convert(rect, to: nil))
        }
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(meadow)
    }

    override func accessibilityFrame() -> NSRect {
        let frame = frame
        return MainActor.assumeIsolated { frame() ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        let press = press
        MainActor.assumeIsolated { press() }
        return true
    }
}
