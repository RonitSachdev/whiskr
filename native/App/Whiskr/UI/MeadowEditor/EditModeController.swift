import AppKit
import MeadowFile
import MeadowScene
import simd
import SwiftUI
import WhiskrKit
import WhiskrMeadow

/// What the top bar shows while the meadow is edited: the meadow's name (a menu), Undo, Redo and Done.
@MainActor @Observable
final class EditBar {
    var name = ""
    var canUndo = false
    var canRedo = false
    /// "Undo Move Oak", "Redo Move Oak": the buttons' tooltips and VoiceOver labels.
    var undoTitle = ""
    var redoTitle = ""
    @ObservationIgnored var undo: () -> Void = {}
    @ObservationIgnored var redo: () -> Void = {}
    @ObservationIgnored var done: () -> Void = {}
    @ObservationIgnored var menu: () -> NSMenu = { NSMenu() }
}

/// Editing the meadow (docs/DESIGN.md, "Edit Meadow"; the design's §4–6): the terminals slide away and the
/// meadow fills the window between the bars, the view lifts to look down on the picnic ground, and the
/// scenery is the Select tool's: click, ⇧-click, a marquee on empty ground, ⌘-click for all of a kind
/// nearby; drag to move (⌥-drag to copy), each thing's ground ringed and a dashed ring with the reason by
/// the pointer where it cannot stand; arrows nudge, R turns, [ ] size living things, ⌘D duplicates, ⌫
/// deletes, ⌘C ⌘X ⌘V copy, cut and paste; ⌘Z and ⇧⌘Z undo and redo each gesture. Everything is saved as it
/// changes (`MeadowLibrary`). Done (⌘↩), Esc once nothing is under way or chosen, or View › Edit Meadow again
/// brings everything back exactly as it was. Cats, terminals and alerts carry on throughout.
@MainActor
final class EditModeController: NSObject {
    private weak var windowController: MainWindowController?
    private let navigator: NavigatorController
    private let library = MeadowLibrary.shared
    private var meadow: MeadowView { navigator.meadow }
    private(set) var isEditing = false
    /// The top bar's part while editing.
    let bar = EditBar()

    /// What is chosen, by id (`MeadowEditSession`), in the order it was chosen.
    private(set) var selection: [Int] = []
    /// The scenery's thing under the pointer (by its index in the scenery shown).
    private var hovered: Int?
    /// The keyboard's cursor on the ground (x, z): shown once the arrows move it with nothing chosen.
    private(set) var cursor: SIMD2<Float>?
    /// `[` and `]` with nothing chosen: things nearest the cursor first, and which has the keyboard's
    /// attention (ringed faintly and read out; Return chooses it).
    private var stepping: (order: [Int], at: Int)?
    private(set) var focused: Int?
    private var gesture: Gesture?
    private var spring: Spring?

    /// The selection's bar, the compass, the marquee, and the note with the reason a thing cannot go.
    let barModel = SelectionBarModel()
    private(set) lazy var selectionBar = SelectionBarHost(rootView: SelectionBar(model: barModel))
    let compass = CompassView(frame: NSRect(x: 0, y: 0, width: CompassView.size, height: CompassView.size))
    let marquee = MarqueeView()
    private let reason = HoverNote()
    private var reasonTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// The keyboard as it was before editing, given back when it ends.
    private weak var keyboardBefore: NSResponder?

    private enum Gesture {
        /// Pressed and not yet dragged: on a thing (by id) or on the grass, where; a thing to let go of
        /// if the press is a ⇧-click on something chosen.
        case pressed(thing: Int?, at: NSPoint, flags: NSEvent.ModifierFlags, unchoose: Int?)
        case moving(Move)
        /// A rectangle from `from`, choosing what is inside it, added to `base`.
        case marquee(from: NSPoint, base: [Int])
    }

    /// A drag of the chosen things (or of copies of them, with ⌥).
    private struct Move {
        var ids: Set<Int>
        /// The ground under the press.
        var start: SIMD2<Float>
        var offset = SIMD2<Float>.zero
        var copying: Bool
        var check: MeadowEditSession.MoveCheck?
        var field: SceneryRules.Field?
        /// Why each thing (by id) may not stand where it is now.
        var refused: [Int: MeadowEditRefusal] = [:]
        /// Where the copies are in the scenery shown, while copying.
        var copies: [Int] = []
    }

    /// Things springing back to where they came from, or copies back into what they were copied from.
    private struct Spring {
        var ids: Set<Int>
        var copying: Bool
        var offset: SIMD2<Float>
        var velocity = SIMD2<Float>.zero
        var link: CADisplayLink?
        var last: CFTimeInterval
    }

    init(window: MainWindowController, navigator: NavigatorController) {
        windowController = window
        self.navigator = navigator
        super.init()
        bar.undo = { [weak self] in self?.undo() }
        bar.redo = { [weak self] in self?.redo() }
        bar.done = { [weak self] in self?.leave() }
        bar.menu = { [weak self] in self?.nameMenu() ?? NSMenu() }
        barModel.act = { [weak self] action in self?.barAction(action) }
        compass.onFaceNorth = { [weak self] in self?.meadow.faceNorth() }
        compass.onFrame = { [weak self] in self?.meadow.frameEditView() }
        compass.onTwist = { [weak self] radians in self?.meadow.twistView(by: radians) }
        marquee.isHidden = true
        library.onStep = { [weak self] change in self?.stepped(change) }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(center.addObserver(forName: name, object: library.undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBar() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEditing else { return }
                self.updateMarks()
                self.compass.needsDisplay = true
            }
        })
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Entering and leaving

    /// View › Edit Meadow, the grass's menu, Settings › Meadow, Go to: the meadow fills the window between
    /// the bars, the view lifts, the top bar shows the meadow's name, Undo, Redo and Done.
    func enter() {
        guard !isEditing, let windowController, let window = windowController.window else { return }
        isEditing = true
        keyboardBefore = window.firstResponder
        #if DEBUG
        debugKeyboardAtEntry = keyboardBefore
        #endif
        navigator.editingWillBegin()
        meadow.takesKeyboardFocus = true
        windowController.setMeadowEditing(true)
        meadow.beginEditing()
        meadow.onEditPointer = { [weak self] pointer in self?.pointer(pointer) }
        meadow.onEditMenu = { [weak self] thing, point in self?.contextMenu(thing, at: point) }
        meadow.onEditViewChanged = { [weak self] in self?.followView() }
        let container = navigator.view
        for overlay in [marquee, compass, selectionBar, reason] as [NSView] where overlay.superview !== container { container.addSubview(overlay) }
        marquee.frame = container.bounds
        marquee.autoresizingMask = [.width, .height]
        selectionBar.isHidden = true
        compass.isHidden = false
        compass.layer?.removeAllAnimations()
        if let layer = compass.layer ?? { compass.wantsLayer = true; return compass.layer }() { OverlayMotion.appear(layer, anchor: .center) }
        library.refreshFiles()
        selection = []
        cursor = nil
        stepping = nil
        updateBar()
        updateMarks()
        updateAccessibility()
        followView()
        announce(String(localized: "Editing the meadow. Click a thing to choose it; drag to move it. Press Command-Return when done.",
                        comment: "VoiceOver: entering the meadow's editor"))
    }

    /// Done, Esc, View › Edit Meadow again, or a command that needs the terminals: everything back as it
    /// was (the layout, the view, the keyboard). Every change is saved already; it is written now.
    func leave() {
        guard isEditing, let windowController else { return }
        if case .moving = gesture { cancelMove() }
        finishSpring()
        gesture = nil
        marquee.rect = nil
        hideReason()
        library.save()
        isEditing = false
        selection = []
        hovered = nil
        cursor = nil
        meadow.editMarks = MeadowEditMarks()
        meadow.scenery = library.scenery
        meadow.endEditing()
        meadow.onEditPointer = nil
        meadow.onEditMenu = nil
        meadow.onEditViewChanged = nil
        for overlay in [marquee, compass, selectionBar, reason] as [NSView] { overlay.removeFromSuperview() }
        meadow.takesKeyboardFocus = false
        windowController.setMeadowEditing(false, keyboard: keyboardBefore)
        keyboardBefore = nil
        navigator.editingDidEnd()
    }

    func toggle() { isEditing ? leave() : enter() }

    // MARK: The pointer

    private func pointer(_ p: MeadowEditPointer) {
        switch p.phase {
        case .moved:
            hover(p.thing)
        case .exited:
            hover(nil)
        case .down:
            down(p)
        case .dragged:
            dragged(p)
        case .up:
            up(p)
        }
    }

    private func hover(_ thing: Int?) {
        guard hovered != thing else { return }
        hovered = thing
        updateMarks()
    }

    private func down(_ p: MeadowEditPointer) {
        finishSpring()
        hideReason()
        let id = p.thing.flatMap(library.session.id(ofThing:))
        let shift = p.modifiers.contains(.shift)
        if p.modifiers.contains(.command), let id {
            // ⌘-click: everything of its kind nearby.
            let like = library.session.ids(like: id, within: Self.nearby)
            choose(shift ? selection + like.filter { !selection.contains($0) } : like)
            gesture = nil
            return
        }
        var unchoose: Int?
        if let id {
            if shift {
                if selection.contains(id) { unchoose = id } else { choose(selection + [id]) }
            } else if !selection.contains(id) {
                choose([id])
            }
        } else if !shift {
            choose([])
        }
        cursor = nil
        gesture = .pressed(thing: id, at: p.location, flags: p.modifiers, unchoose: unchoose)
        updateMarks()
    }

    /// How far round a thing ⌘-click and Select All Like This reach, in units: a clump and its neighbours.
    static let nearby: Double = 30

    private func dragged(_ p: MeadowEditPointer) {
        switch gesture {
        case .pressed(let thing, let at, let flags, _):
            guard hypot(p.location.x - at.x, p.location.y - at.y) >= 4 else { return }
            if thing != nil, !selection.isEmpty, let start = meadow.groundPoint(at: at) {
                let ids = Set(selection)
                let copying = flags.contains(.option) || p.modifiers.contains(.option)
                var move = Move(ids: ids, start: start, copying: copying)
                if copying { move.field = SceneryRules.Field(library.scenery) } else { move.check = library.session.moveCheck(ids) }
                gesture = .moving(move)
                hideSelectionBar()
                NSCursor.closedHand.set()
                dragged(p)
            } else {
                gesture = .marquee(from: at, base: flags.contains(.shift) ? selection : [])
                hideSelectionBar()
                dragged(p)
            }
        case .moving(var move):
            guard let ground = meadow.groundPoint(at: p.location) else { return }
            move.offset = ground - move.start
            preview(&move)
            gesture = .moving(move)
            if let first = selection.lazy.compactMap({ move.refused[$0] }).first ?? move.refused.values.first {
                showReason(MeadowWords.refusal(first), at: p.location, lasting: nil)
            } else {
                hideReason()
            }
            updateMarks()
        case .marquee(let from, let base):
            let rect = NSRect(x: min(from.x, p.location.x), y: min(from.y, p.location.y), width: abs(p.location.x - from.x), height: abs(p.location.y - from.y))
            marquee.rect = rect
            let inside = meadow.sceneryThings(in: rect).compactMap(library.session.id(ofThing:))
            selection = base + inside.filter { !base.contains($0) }
            updateMarks()
        case nil:
            break
        }
    }

    /// The meadow drawn with the drag's things where they are now, and each judged.
    private func preview(_ move: inout Move) {
        let session = library.session
        if move.copying {
            let (scenery, copies) = session.scenery(copying: move.ids, by: move.offset)
            move.copies = copies
            meadow.scenery = scenery
            move.refused = move.field.map { session.copyRefusals(move.ids, by: move.offset, field: $0) } ?? [:]
        } else {
            meadow.scenery = session.scenery(moving: move.ids, by: move.offset)
            move.refused = move.check.map { session.refusals($0, by: move.offset) } ?? [:]
        }
    }

    private func up(_ p: MeadowEditPointer) {
        defer {
            if !isSpringing { NSCursor.arrow.set() }
            updateMarks()
            updateSelectionBar(appearing: true)
        }
        switch gesture {
        case .pressed(_, _, _, let unchoose):
            gesture = nil
            if let unchoose { choose(selection.filter { $0 != unchoose }) }
        case .moving(let move):
            gesture = nil
            let names = selection.compactMap { library.session.item($0)?.asset }
            if simd_length(move.offset) < 1e-4 {
                meadow.scenery = library.scenery
            } else if move.refused.isEmpty {
                let offset = SIMD2(Double(move.offset.x), Double(move.offset.y))
                let result = move.copying
                    ? library.edit(MeadowWords.duplicate(names)) { $0.duplicate(move.ids, movedBy: offset) }
                    : library.edit(MeadowWords.move(names)) { $0.move(move.ids, by: offset) }
                switch result {
                case .success(let change):
                    if move.copying { choose(change.added.map(\.id)) }
                    meadow.scenery = library.scenery
                    announce(move.copying ? MeadowWords.duplicate(names) : MeadowWords.move(names))
                case .failure(let refused):
                    springBack(move, saying: MeadowWords.refusal(refused.refusal), at: p.location)
                }
            } else {
                let first = selection.lazy.compactMap { move.refused[$0] }.first ?? move.refused.values.first
                springBack(move, saying: first.map(MeadowWords.refusal), at: p.location)
            }
        case .marquee:
            gesture = nil
            marquee.rect = nil
            announceSelection()
        case nil:
            break
        }
    }

    // MARK: Springing back

    private var isSpringing: Bool { spring != nil }

    /// A drag, or things springing back, draw the meadow as they are now rather than as it is saved.
    var showsPreview: Bool {
        if case .moving = gesture { return true }
        return spring != nil
    }

    /// Let go where they cannot stand (or Esc mid-drag): the things spring back to where they came from,
    /// copies back into what they were copied from, on a spring settled within a quarter second; the reason
    /// stays by the pointer a moment. With Reduce Motion they are back at once.
    private func springBack(_ move: Move, saying text: String?, at point: NSPoint?) {
        if let text {
            showReason(text, at: point ?? NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY), lasting: 2.5)
            announce(text)
        }
        guard Look.Motion.moves else {
            meadow.scenery = library.scenery
            return
        }
        var spring = Spring(ids: move.ids, copying: move.copying, offset: move.offset, last: CACurrentMediaTime())
        let link = meadow.displayLink(target: self, selector: #selector(springTick(_:)))
        link.add(to: .main, forMode: .common)
        spring.link = link
        self.spring = spring
    }

    @objc private func springTick(_ link: CADisplayLink) {
        guard var spring else { return link.invalidate() }
        let now = CACurrentMediaTime()
        let dt = Float(min(now - spring.last, 1.0 / 30))
        spring.last = now
        // Critically damped, as the held tab's spring (`TabDragging`): in two half steps, steady at any rate.
        let omega: Float = 26
        for _ in 0..<2 {
            let acceleration = -omega * omega * spring.offset - 2 * omega * spring.velocity
            spring.velocity += acceleration * dt / 2
            spring.offset += spring.velocity * dt / 2
        }
        if simd_length(spring.offset) < 0.01, simd_length(spring.velocity) < 0.05 {
            self.spring = spring
            return finishSpring()
        }
        self.spring = spring
        let session = library.session
        meadow.scenery = spring.copying ? session.scenery(copying: spring.ids, by: spring.offset).scenery : session.scenery(moving: spring.ids, by: spring.offset)
    }

    private func finishSpring() {
        guard let spring else { return }
        spring.link?.invalidate()
        self.spring = nil
        meadow.scenery = library.scenery
        updateMarks()
    }

    /// Esc during a drag: back where they came from, nothing changed.
    private func cancelMove() {
        guard case .moving(let move) = gesture else { return }
        gesture = nil
        springBack(move, saying: nil, at: nil)
        updateMarks()
        updateSelectionBar(appearing: true)
    }

    // MARK: Keys

    /// Keys while the meadow has the keyboard and is edited (`KeyTable`'s `.meadowEditor`).
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.contains(.command), !flags.contains(.control) else { return false }
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 53: escape(); return true
        case 51, 117: deleteSelection(); return true
        case 36, 76: chooseNearestCursor(); return true
        case 123, 124, 125, 126: arrow(event.keyCode, far: shift); return true
        case 48:
            // Tab: on to the selection's bar (Full Keyboard Access), when it shows.
            if !selectionBar.isHidden, selectionBar.superview != nil {
                meadow.window?.selectKeyView(following: meadow)
                if let window = meadow.window, !(window.firstResponder is NSView && (window.firstResponder as? NSView)?.isDescendant(of: selectionBar) == true) {
                    window.makeFirstResponder(selectionBar)
                }
            }
            return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": return true
        case "r":
            let degrees: Double = flags.contains(.option) ? 1 : 15
            turnSelection(by: (shift ? 1 : -1) * degrees * .pi / 180)
            return true
        case "[":
            if selection.isEmpty { step(-1) } else { resizeSelection(by: 1 / Self.sizeStep) }
            return true
        case "]":
            if selection.isEmpty { step(1) } else { resizeSelection(by: Self.sizeStep) }
            return true
        case ",": meadow.turnView(by: .pi / 4); return true
        case ".": meadow.turnView(by: -.pi / 4); return true
        case "0": meadow.frameEditView(); return true
        default: return false
        }
    }

    /// Keys with ⌘ the editor takes before the menus: ⌘D duplicates (no terminal is in view to split), ⌘↩ is Done.
    func keyEquivalent(_ event: NSEvent) -> Bool {
        guard isEditing, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "d":
            duplicateSelection()
            return true
        case "\r":
            leave()
            return true
        default:
            return false
        }
    }

    /// One size step of `[` and `]`, and of the bar's − and +.
    static let sizeStep = 1.06

    /// Esc steps back: the drag or marquee under way, then the choice, then editing itself.
    func escape() {
        switch gesture {
        case .moving:
            cancelMove()
        case .marquee(_, let base):
            gesture = nil
            marquee.rect = nil
            choose(base)
            updateSelectionBar(appearing: true)
        case .pressed, nil:
            gesture = nil
            if !selection.isEmpty || cursor != nil || focused != nil {
                choose([])
                cursor = nil
                updateMarks()
            } else {
                leave()
            }
        }
    }

    private func arrow(_ code: UInt16, far: Bool) {
        let axes = meadow.groundAxes
        let direction: SIMD2<Float> = switch code {
        case 123: -axes.right
        case 124: axes.right
        case 126: axes.forward
        default: -axes.forward
        }
        if selection.isEmpty {
            // The keyboard's cursor, from the view's middle.
            let from = cursor ?? viewMiddle() ?? .zero
            cursor = from + direction * (far ? 2 : 0.5)
            stepping = nil
            focused = nil
            updateMarks()
            return
        }
        let names = selection.compactMap { library.session.item($0)?.asset }
        let step = direction * (far ? 1 : 0.25)
        perform(MeadowWords.move(names)) { $0.move(Set(self.selection), by: SIMD2(Double(step.x), Double(step.y))) }
    }

    /// The spot on the ground in the view's middle.
    private func viewMiddle() -> SIMD2<Float>? {
        meadow.groundPoint(at: NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY))
    }

    /// Return with nothing armed: the thing `[` `]` went to, else the one nearest the keyboard's cursor (or
    /// the view's middle), is chosen.
    private func chooseNearestCursor() {
        if let focused {
            choose([focused])
            return announceSelection()
        }
        guard let spot = cursor ?? viewMiddle(), let nearest = library.session.idsByDistance(from: SIMD2(Double(spot.x), Double(spot.y))).first else { return }
        choose([nearest])
        announceSelection()
    }

    /// `[` and `]` with nothing chosen: the thing before or after, nearest the cursor first.
    private func step(_ by: Int) {
        let spot = cursor ?? viewMiddle() ?? .zero
        var state = stepping ?? (library.session.idsByDistance(from: SIMD2(Double(spot.x), Double(spot.y))), -1)
        guard !state.order.isEmpty else { return }
        state.at = (state.at + by + state.order.count) % state.order.count
        stepping = state
        let id = state.order[state.at]
        focused = id
        updateMarks()
        if let item = library.session.item(id) {
            announce(String(localized: "\(MeadowWords.name(item.asset)), \(MeadowWords.whereIs(item.at))", comment: "VoiceOver: a chosen thing and where it is"))
        }
    }

    // MARK: Edits

    /// Makes an edit as one step; refused, the reason is shown by the selection and said.
    @discardableResult
    private func perform(_ name: String, _ make: (inout MeadowEditSession) -> Result<MeadowChange, MeadowEditRefused>) -> Bool {
        finishSpring()
        switch library.edit(name, make) {
        case .success(let change):
            if !change.added.isEmpty, change.removed.isEmpty, change.edited.isEmpty { choose(change.added.map(\.id)) }
            meadow.scenery = library.scenery
            if !change.added.isEmpty || !change.removed.isEmpty { updateAccessibility() }
            updateMarks()
            updateSelectionBar(appearing: false)
            announce(name)
            return true
        case .failure(let refused):
            let text = MeadowWords.refusal(refused.refusal)
            let rect = meadow.screenRect(ofScenery: selection.compactMap(library.session.thingIndex(of:)))
            showReason(text, at: rect.map { NSPoint(x: $0.midX, y: $0.maxY) } ?? NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY), lasting: 2.5)
            announce(text)
            return false
        }
    }

    func turnSelection(by radians: Double) {
        guard !selection.isEmpty else { return }
        let names = selection.compactMap { library.session.item($0)?.asset }
        perform(MeadowWords.turn(names)) { $0.turn(Set(self.selection), by: radians) }
    }

    func resizeSelection(by factor: Double) {
        guard !selection.isEmpty else { return }
        let names = selection.compactMap { library.session.item($0)?.asset }
        perform(MeadowWords.resize(names)) { $0.resize(Set(self.selection), by: factor) }
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let names = selection.compactMap { library.session.item($0)?.asset }
        // Two units toward the view's lower right: beside, where you look.
        let axes = meadow.groundAxes
        let toward = axes.right - axes.forward
        perform(MeadowWords.duplicate(names)) { $0.duplicate(Set(self.selection), toward: SIMD2(Double(toward.x), Double(toward.y))) }
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let names = selection.compactMap { library.session.item($0)?.asset }
        let ids = Set(selection)
        perform(MeadowWords.delete(names)) { .success($0.delete(ids)) }
        choose([])
    }

    func shuffleSelection() {
        guard !selection.isEmpty else { return }
        let names = selection.compactMap { library.session.item($0)?.asset }
        var random = SystemRandomNumberGenerator()
        perform(MeadowWords.shuffle(names)) { $0.shuffle(Set(self.selection), using: &random) }
    }

    func selectAll() {
        choose(library.session.drawnIDs)
        announceSelection()
    }

    /// Everything of the kind of the first chosen thing, nearby.
    func selectAllLike() {
        guard let first = selection.first else { return }
        choose(library.session.ids(like: first, within: Self.nearby))
        announceSelection()
    }

    // MARK: Copy and paste

    static let pasteboardType = NSPasteboard.PasteboardType(MeadowEditSession.pasteboardType)

    func copySelection() {
        guard !selection.isEmpty, let data = library.session.copied(Set(selection), writtenBy: MeadowLibrary.writtenBy) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: Self.pasteboardType)
    }

    func cutSelection() {
        guard !selection.isEmpty else { return }
        copySelection()
        let names = selection.compactMap { library.session.item($0)?.asset }
        let ids = Set(selection)
        perform(MeadowWords.cut(names)) { .success($0.delete(ids)) }
        choose([])
    }

    var canPaste: Bool { NSPasteboard.general.availableType(from: [Self.pasteboardType]) != nil }

    /// Pastes what was copied (from this meadow or another) at the pointer, or the keyboard's cursor, or the
    /// view's middle, at the nearest spot round there where each thing may stand.
    func paste(at point: NSPoint? = nil) {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType), let items = MeadowEditSession.pasted(data) else { return }
        let pointer = point ?? meadow.window.map { meadow.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let spot = pointer.flatMap { meadow.bounds.contains($0) ? meadow.groundPoint(at: $0) : nil } ?? cursor ?? viewMiddle() ?? .zero
        perform(MeadowWords.paste(items.map(\.asset))) { $0.add(items, around: SIMD2(Double(spot.x), Double(spot.y))) }
    }

    // MARK: Undo

    func undo() {
        guard library.undoManager.canUndo else { return }
        let name = library.undoManager.undoMenuItemTitle
        finishSpring()
        library.undoManager.undo()
        announce(name)
    }

    func redo() {
        guard library.undoManager.canRedo else { return }
        let name = library.undoManager.redoMenuItemTitle
        finishSpring()
        library.undoManager.redo()
        announce(name)
    }

    /// A step undone or done again (here or from Settings): its things chosen, everything drawn anew.
    private func stepped(_ change: MeadowChange) {
        let session = library.session
        if isEditing {
            choose(change.touched.filter { session.thingIndex(of: $0) != nil })
            meadow.scenery = library.scenery
            updateMarks()
            updateAccessibility()
        }
        updateBar()
    }

    // MARK: Choosing

    private func choose(_ ids: [Int]) {
        var seen = Set<Int>()
        selection = ids.filter { seen.insert($0).inserted }
        stepping = nil
        focused = nil
        updateMarks()
        updateSelectionBar(appearing: true)
    }

    // MARK: Menus

    /// The meadow's name in the top bar: the meadows to show (the Default and yours), and Revert to Default.
    private func nameMenu() -> NSMenu {
        library.refreshFiles()
        let menu = NSMenu()
        let use = NSMenu(title: String(localized: "Use Another Meadow", comment: "Meadow editor: the name menu's list of meadows"))
        for file in [nil] + library.files.map(Optional.some) {
            let item = closureMenuItem(title: library.displayName(file)) { [weak self] in
                guard let self else { return }
                self.library.use(file, name: String(localized: "Use “\(self.library.displayName(file))”", comment: "Meadow editor: a step's name (choosing a meadow)"))
                self.choose([])
                self.meadow.scenery = self.library.scenery
                self.updateBar()
            }
            item.state = file == library.active ? .on : .off
            use.addItem(item)
        }
        let useItem = NSMenuItem(title: use.title, action: nil, keyEquivalent: "")
        useItem.submenu = use
        menu.addItem(useItem)
        menu.addItem(.separator())
        let revert = closureMenuItem(title: String(localized: "Revert to Default")) { [weak self] in
            guard let self else { return }
            self.library.revertToDefault()
            self.choose([])
            self.meadow.scenery = self.library.scenery
            self.updateBar()
        }
        revert.isEnabled = library.active != nil
        if library.active == nil { revert.action = nil }
        menu.addItem(revert)
        return menu
    }

    /// Right-click while editing: on a thing (chosen first, unless it is already), its commands; on the grass,
    /// Paste, Select All and Done.
    private func contextMenu(_ thing: Int?, at point: NSPoint) -> NSMenu? {
        finishSpring()
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
            let item = closureMenuItem(title: title, action: run)
            if !enabled { item.action = nil }
            menu.addItem(item)
        }
        if let thing, let id = library.session.id(ofThing: thing) {
            if !selection.contains(id) { choose([id]) }
            add(String(localized: "Duplicate", comment: "Meadow editor: the chosen things' menu")) { [weak self] in self?.duplicateSelection() }
            add(String(localized: "Delete", comment: "Meadow editor: the chosen things' menu")) { [weak self] in self?.deleteSelection() }
            if selection.allSatisfy(library.session.grows) {
                add(String(localized: "Shuffle", comment: "Selection bar: draws a living thing's size, lean and shape again")) { [weak self] in self?.shuffleSelection() }
            }
            menu.addItem(.separator())
            add(String(localized: "Select All Like This", comment: "Meadow editor: chooses everything of the kind nearby")) { [weak self] in self?.selectAllLike() }
            add(String(localized: "Copy")) { [weak self] in self?.copySelection() }
        }
        add(String(localized: "Paste"), enabled: canPaste) { [weak self] in self?.paste(at: point) }
        if thing == nil {
            add(String(localized: "Select All")) { [weak self] in self?.selectAll() }
            menu.addItem(.separator())
            add(String(localized: "Done", comment: "Meadow editor: leaves editing")) { [weak self] in self?.leave() }
        }
        return menu
    }

    private func barAction(_ action: SelectionBarModel.Action) {
        switch action {
        case .turnLeft: turnSelection(by: 15 * .pi / 180)
        case .turnRight: turnSelection(by: -15 * .pi / 180)
        case .smaller: resizeSelection(by: 1 / Self.sizeStep)
        case .larger: resizeSelection(by: Self.sizeStep)
        case .shuffle: shuffleSelection()
        case .duplicate: duplicateSelection()
        case .delete: deleteSelection()
        case .more:
            let menu = NSMenu()
            menu.addItem(closureMenuItem(title: String(localized: "Select All Like This", comment: "Meadow editor: chooses everything of the kind nearby")) { [weak self] in self?.selectAllLike() })
            menu.addItem(closureMenuItem(title: String(localized: "Copy")) { [weak self] in self?.copySelection() })
            let paste = closureMenuItem(title: String(localized: "Paste")) { [weak self] in self?.paste() }
            if !canPaste { paste.action = nil }
            menu.addItem(paste)
            menu.popUp(positioning: nil, at: selectionBar.moreAnchor, in: selectionBar)
        }
    }

    // MARK: What is drawn over the meadow

    private func updateMarks() {
        guard isEditing else { return }
        let session = library.session
        var marks = MeadowEditMarks(highContrast: Look.increasesContrast)
        if case .moving(let move) = gesture {
            if move.copying {
                marks.selected = move.copies
                marks.refused = copiedRefused(move)
            } else {
                marks.selected = selection.compactMap(session.thingIndex(of:))
                marks.refused = move.refused.keys.compactMap(session.thingIndex(of:))
            }
        } else {
            marks.selected = selection.compactMap(session.thingIndex(of:))
            if let focused, let index = session.thingIndex(of: focused) {
                marks.hovered = index
            } else if gesture == nil, !isSpringing, let hovered, hovered < session.scenery.things.count {
                marks.hovered = hovered
            }
        }
        marks.cursor = selection.isEmpty ? cursor : nil
        meadow.editMarks = marks
        updateBarModel()
    }

    /// While copying: where the refused copies are in the scenery shown (copies follow the rest, in order).
    private func copiedRefused(_ move: Move) -> [Int] {
        let copied = library.session.shown.filter(move.ids.contains)
        return zip(copied, move.copies).compactMap { id, index in move.refused[id] != nil ? index : nil }
    }

    private func updateBarModel() {
        barModel.count = selection.count
        barModel.grows = !selection.isEmpty && selection.allSatisfy(library.session.grows)
    }

    /// Each frame while editing: the selection's bar over what is chosen, the compass's needle.
    private func followView() {
        compass.bearing = meadow.viewBearing
        let container = navigator.view.bounds
        let place = NSPoint(x: container.maxX - CompassView.size - Look.Space.l, y: container.maxY - CompassView.size - Look.Space.l)
        if compass.frame.origin != place { compass.setFrameOrigin(place) }
        placeSelectionBar()
    }

    private var selectionBarShown = false

    /// Shows (fading in, growing from 98 %) or places the selection's bar over the chosen things.
    private func updateSelectionBar(appearing: Bool) {
        let wanted = isEditing && !selection.isEmpty && gesture == nil && !isSpringing
        if wanted != selectionBarShown {
            selectionBarShown = wanted
            selectionBar.isHidden = !wanted
            if wanted, appearing, let layer = selectionBar.layer ?? { selectionBar.wantsLayer = true; return selectionBar.layer }() {
                placeSelectionBar()
                OverlayMotion.appear(layer, anchor: .center)
            }
        }
        placeSelectionBar()
    }

    private func hideSelectionBar() {
        selectionBarShown = false
        selectionBar.isHidden = true
    }

    /// 12 pt above the chosen things' box on screen, or below it when there is no room above; inside the
    /// meadow, clear of the compass. Hidden while they are out of view.
    private func placeSelectionBar() {
        guard selectionBarShown else { return }
        let indices = selection.compactMap(library.session.thingIndex(of:))
        guard let rect = meadow.screenRect(ofScenery: indices), rect.maxY > 0, rect.minY < meadow.bounds.height else {
            selectionBar.isHidden = true
            return
        }
        selectionBar.isHidden = false
        let size = selectionBar.fittingSize, margin = SelectionBar.margin
        let bounds = meadow.bounds
        var y = rect.maxY + Look.Space.l - margin
        if y + size.height - margin > bounds.maxY - Look.Space.m { y = rect.minY - Look.Space.l - size.height + margin }
        y = min(max(y, bounds.minY + Look.Space.m - margin), bounds.maxY - size.height + margin - Look.Space.m)
        var x = rect.midX - size.width / 2
        x = min(max(x, bounds.minX + Look.Space.m - margin), bounds.maxX - size.width + margin - Look.Space.m)
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if selectionBar.frame != frame { selectionBar.frame = frame }
    }

    /// The reason by the pointer, as shown now.
    private var reasonText: String?

    private func showReason(_ text: String, at point: NSPoint, lasting: TimeInterval?) {
        reasonText = text
        reason.show(title: "⃠ " + text, detail: nil, at: point, within: navigator.view.bounds)
        reasonTimer?.invalidate()
        reasonTimer = lasting.map { seconds in
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hideReason() } }
        }
    }

    private func hideReason() {
        reasonTimer?.invalidate()
        reasonTimer = nil
        reasonText = nil
        reason.hide()
    }

    /// The top bar's part: the meadow's name, and Undo and Redo with the steps they would take.
    func updateBar() {
        let undo = library.undoManager
        bar.name = library.activeName
        bar.canUndo = undo.canUndo
        bar.canRedo = undo.canRedo
        bar.undoTitle = undo.undoMenuItemTitle
        bar.redoTitle = undo.redoMenuItemTitle
    }

    // MARK: VoiceOver

    private func announce(_ text: String) {
        NSAccessibility.post(element: meadow, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func announceSelection() {
        let session = library.session
        guard let first = selection.first, let item = session.item(first) else { return }
        if selection.count == 1 {
            announce(String(localized: "\(MeadowWords.name(item.asset)), \(MeadowWords.whereIs(item.at))", comment: "VoiceOver: a chosen thing and where it is"))
        } else {
            announce(String(localized: "\(selection.count) things chosen", comment: "VoiceOver: how many things are chosen"))
        }
    }

    /// The meadow as VoiceOver reads it while editing: each tree and the log on its own, the plants and stones
    /// as clumps of one kind ("Daisies, 9"), so it never holds thousands of elements. Press chooses.
    private func updateAccessibility() {
        let session = library.session
        var elements: [NSAccessibilityElement] = []
        var placed = Set<Int>()
        for id in session.drawnIDs where !placed.contains(id) {
            guard let item = session.item(id) else { continue }
            let big = SceneryRules.isBig(item.asset)
            var members = [id]
            if !big {
                // A clump: the same kind within four units of any of it, gathered outward.
                var frontier = [item.at]
                while let at = frontier.popLast() {
                    for other in session.drawnIDs where !placed.contains(other) && !members.contains(other) {
                        guard let o = session.item(other), o.asset == item.asset, hypot(o.at.x - at.x, o.at.z - at.z) < 4 else { continue }
                        members.append(other)
                        frontier.append(o.at)
                    }
                }
            }
            placed.formUnion(members)
            let label = members.count == 1 ? "\(MeadowWords.name(item.asset)), \(MeadowWords.whereIs(item.at))" : MeadowWords.clump(item.asset, count: members.count)
            let element = SceneryAccessibilityElement(meadow: meadow, frame: { [weak self] in
                guard let self, let window = self.meadow.window,
                      let rect = self.meadow.screenRect(ofScenery: members.compactMap(self.library.session.thingIndex(of:))) else { return nil }
                return window.convertToScreen(self.meadow.convert(rect, to: nil))
            }, press: { [weak self] in
                self?.choose(members)
                self?.announceSelection()
            })
            element.setAccessibilityLabel(label)
            elements.append(element)
        }
        meadow.setAccessibilityChildren(elements)
        meadow.setAccessibilityLabel(String(localized: "Meadow, being edited", comment: "VoiceOver: the meadow while it is edited"))
    }

    // MARK: Debug builds: what the editor flow looks at

    #if DEBUG
    /// What had the keyboard as editing began (the editor gives it back there).
    private(set) weak var debugKeyboardAtEntry: NSResponder?
    var debugSelection: [Int] { selection }
    var debugGestureUnderWay: Bool { gesture != nil || spring != nil }
    var debugReason: String? { reason.isHidden ? nil : reasonText }
    var debugSelectionBarShown: Bool { selectionBarShown && !selectionBar.isHidden && selectionBar.superview != nil }
    func debugChoose(_ ids: [Int]) { choose(ids) }
    #endif
}

/// A thing of the meadow, or a clump of them, as VoiceOver sees it while editing: its words, where it is
/// drawn, and Press, which chooses it.
nonisolated final class SceneryAccessibilityElement: NSAccessibilityElement {
    /// Where it is drawn, on the screen (nil: not drawn).
    private let frame: @MainActor @Sendable () -> NSRect?
    private let press: @MainActor @Sendable () -> Void

    init(meadow: MeadowView, frame: @escaping @MainActor @Sendable () -> NSRect?, press: @escaping @MainActor @Sendable () -> Void) {
        self.frame = frame
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
