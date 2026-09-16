import AppKit
import MeadowFile
import MeadowScene
import simd
import SwiftUI
import WhiskrMeadow

// Fences and colours in the editor (docs/DESIGN.md, "Edit Meadow"): with the fence armed, a press and drag lays a
// run along the way the pointer goes (a post each 2.5 units; ⌥ one straight length), its ghost drawn as it will stand
// with its rings or the dashed rings and the reason where it may not, its ends joining a nearby fence's ends; a click
// lays a short run; with the keys, Return sets each corner at the keyboard's cursor and Return again where the cursor
// still is finishes it. A chosen fence's bar straightens it, hangs a gate or takes it away; a made thing with a
// palette is coloured from the bar's popover, and the next one armed wears the colour last chosen for its kind.

extension EditModeController {
    /// Whether the thing armed is a fence, laid in runs.
    var laysFences: Bool { tray.armed == MeadowEditSession.fence }

    // MARK: The ghost

    /// The fence armed, as it would be laid now: the run being drawn (by a drag or the keys) to the pointer or the
    /// cursor, else a short run round the ghost's spot along its turn; joined to any fence end near its ends.
    func drawFencePending() {
        let session = library.session
        guard let spot = ghostSpot else {
            pending = nil
            fenceLaying = nil
            return updateMarks()
        }
        let end = SIMD2(Double(spot.x), Double(spot.y))
        let points: [SIMD2<Double>]
        if let draft = fenceDraft {
            points = draft.points(endingAt: end)
        } else if let keys = fenceKeys {
            points = simd_distance(keys[keys.count - 1], end) >= MeadowEditSession.shortestSpan ? keys + [end] : keys
        } else {
            points = MeadowEditSession.shortFence(at: end, turn: pendingTurn)
        }
        let laying = points.count >= 2 ? session.fenceLaying(points) : nil
        fenceLaying = laying
        pending = laying?.item
        ghostRefusal = laying.flatMap { session.fenceRefusal($0) }
        // The runs it joins are drawn as part of it while it is laid.
        if let laying, !laying.joined.isEmpty { meadow.scenery = session.scenery(laying: laying) } else if meadow.scenery != library.scenery, stroke == nil { meadow.scenery = library.scenery }
        updateMarks()
    }

    // MARK: A drag

    /// A press dragged with the fence armed: a run from where it was pressed.
    func beginFence(at start: SIMD2<Float>, straight: Bool) {
        fenceKeys = nil
        fenceDraft = MeadowFenceDraft(at: SIMD2(Double(start.x), Double(start.y)), straight: straight)
        drawPending()
    }

    /// The run carries on to `spot` (⌥ held or let go on the way switches straight and free).
    func continueFence(to spot: SIMD2<Float>, straight: Bool) {
        guard var draft = fenceDraft else { return }
        draft.straight = straight
        draft.extend(to: SIMD2(Double(spot.x), Double(spot.y)))
        fenceDraft = draft
        ghostSpot = spot
        drawPending()
        sayGhost(at: meadow.viewPoint(ofGround: spot) ?? pointerOrMiddle(), lasting: nil)
    }

    /// The drag let go: the run laid as one step ("Lay Fence"), and chosen; refused, nothing laid and why said.
    /// ⇧: the fence stays armed for the next.
    func finishFence(keepArmed: Bool) {
        defer {
            fenceDraft = nil
            fenceKeys = nil
        }
        layPendingFence(keepArmed: keepArmed)
    }

    /// Esc while a run is drawn: nothing laid, the fence still armed.
    func cancelFence() {
        guard fenceDraft != nil || fenceKeys != nil else { return }
        fenceDraft = nil
        fenceKeys = nil
        meadow.scenery = library.scenery
        drawPending()
    }

    /// Lays the run the ghost shows, when it may be laid.
    @discardableResult
    func layPendingFence(keepArmed: Bool) -> Bool {
        guard let laying = fenceLaying, pending == laying.item else { return false }
        if let refusal = library.session.fenceRefusal(laying) {
            let text = MeadowWords.refusal(refusal)
            showReason(text, at: pointerOrMiddle(), lasting: 2.5)
            announce(text)
            meadow.scenery = library.scenery
            return false
        }
        let name = laying.joined.isEmpty ? MeadowWords.layFence : MeadowWords.joinFence
        switch library.edit(name, { $0.layFence(laying) }) {
        case .success(let change):
            meadow.scenery = library.scenery
            updateAccessibility()
            pending = nil
            if keepArmed {
                choose([])
                drawPending()
            } else {
                tray.armed = nil
                ghostRefusal = nil
                choose(change.added.map(\.id))
                updateTools()
            }
            announce(name)
            return true
        case .failure(let refused):
            meadow.scenery = library.scenery
            let text = MeadowWords.refusal(refused.refusal)
            showReason(text, at: pointerOrMiddle(), lasting: 2.5)
            announce(text)
            return false
        }
    }

    // MARK: The keys

    /// Return with the fence armed: the first sets the run's start at the keyboard's cursor, each next a corner
    /// where the cursor has gone, and one where the cursor still is (or where the last corner is) lays it; Return
    /// at once on a fresh start lays the short run there.
    func fenceReturn() {
        let spot = cursor ?? ghostSpot ?? viewMiddle() ?? .zero
        cursor = spot
        ghostSpot = spot
        let at = SIMD2(Double(spot.x), Double(spot.y))
        guard var keys = fenceKeys else {
            fenceKeys = [at]
            drawPending()
            return announce(MeadowWords.fenceStarted)
        }
        if simd_distance(keys[keys.count - 1], at) < MeadowEditSession.shortestSpan {
            if keys.count == 1 { fenceKeys = nil }
            drawPending()
            layPendingFence(keepArmed: false)
            fenceKeys = nil
            return
        }
        keys.append(at)
        fenceKeys = keys
        drawPending()
        announce(MeadowWords.fenceCorner(keys.count))
    }

    // MARK: A chosen fence

    /// The chosen fence, when one alone is chosen.
    private var chosenFence: Int? {
        guard selection.count == 1, let id = selection.first, library.session.fenceRun(id) != nil else { return nil }
        return id
    }

    func straightenFence() {
        guard let id = chosenFence else { return }
        perform(MeadowWords.straighten) { $0.straighten(id) }
    }

    func toggleFenceGate() {
        guard let id = chosenFence else { return }
        let name = (library.session.fenceRun(id)?.gate ?? 0) > 0 ? MeadowWords.removeGate : MeadowWords.addGate
        perform(name) { $0.toggleGate(id) }
    }

    // MARK: Colours

    /// The chosen things in `name` (those whose palette has it), one step; and the next of their kind armed wears it.
    func recolourSelection(_ name: String) {
        let session = library.session
        let assets = Set(selection.compactMap { session.item($0)?.asset }.filter { session.palette(of: $0).contains(name) })
        guard !assets.isEmpty else { return }
        for asset in assets { colours[asset] = name }
        rememberTray()
        perform(MeadowWords.colour(Array(assets).sorted(), name)) { $0.recolour(Set(self.selection), to: name) }
        announce(MeadowWords.colourName(name))
    }

    /// The colour the next `asset` armed wears: the one last chosen for its kind, else its own.
    func colourToPlace(_ asset: String) -> String? {
        guard let name = colours[asset], library.session.palette(of: asset).dropFirst().contains(name) else { return nil }
        return name
    }

    /// The selection's bar's part for fences and colours.
    func updateGardenBar() {
        let session = library.session
        if let id = chosenFence {
            barModel.fence = true
            barModel.bends = session.canStraighten(id)
            barModel.hasGate = (session.fenceRun(id)?.gate ?? 0) > 0
            barModel.gateFits = session.canToggleGate(id)
        } else {
            barModel.fence = false
        }
        // A palette, when every chosen thing is of one kind that has one.
        let kinds = Set(selection.compactMap { session.isParcel($0) ? nil : session.item($0)?.asset })
        let palette = kinds.count == 1 && selection.allSatisfy { !session.isParcel($0) } ? kinds.first.map { MeadowScenery.palette(of: $0) } ?? [] : []
        let swatches = palette.map { SelectionBarModel.Swatch(name: $0.name, color: Color(.sRGB, red: Double($0.color.red), green: Double($0.color.green), blue: Double($0.color.blue)),
                                                              label: MeadowWords.colourName($0.name)) }
        if barModel.swatches != swatches { barModel.swatches = swatches }
        let worn = Set(selection.compactMap(session.colour(of:)))
        barModel.wearing = worn.count == 1 ? worn.first : nil
        if swatches.isEmpty { barModel.paletteOpen = false }
    }
}
