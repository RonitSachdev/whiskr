import AppKit
import MeadowFile
import MeadowScene
import simd
import WhiskrKit
import WhiskrMeadow

// The tray and its tools (docs/DESIGN.md, "Edit Meadow"): placing a thing chosen in the tray (a click, a drag
// out of the tray, or the keys), the Brush that plants clumps of flowers and the Eraser that takes things
// away. Each placing, each stroke and each sweep is one step of the history.

/// A Brush stroke or an Eraser sweep under way: the meadow as the stroke leaves it (drawn, not yet a step),
/// what it has added or taken away, and where it last dabbed.
struct Stroke {
    var erasing: Bool
    /// The Brush's: the meadow with the plants laid so far. The Eraser's: the meadow as it was.
    var working: MeadowEditSession
    /// The Eraser's picture of the meadow meanwhile: what it has taken shrunk to nothing, so only those are
    /// drawn again (`Meadow.show` places changed things alone), however full the meadow.
    var preview = MeadowScenery()
    /// Where each plant may stand, the stroke's own included.
    var field: SceneryRules.Field
    var added: [MeadowChange.Placed] = []
    var removed = Set<Int>()
    var last: SIMD2<Double>
    /// The kinds it adds (the Brush), or the one it takes (the Eraser; nil for any small thing).
    var brush: MeadowBrush?
    var kind: String?
    /// The meadow's caps reached on the way, said once.
    var full: MeadowEditRefusal?
}

extension EditModeController {
    // MARK: The tray

    /// The tray's request, as the editor carries it out.
    func trayAction(_ action: EditorTray.Action) {
        switch action {
        case .tool(let tool): use(tool)
        case .category(let category):
            if tray.tool != .select { use(.select) }
            tray.category = category
            tray.filter = ""
            announce(MeadowWords.categoryName(category))
        case .choose(let id): choose(item: id)
        case .placeNow(let id): placeNow(id)
        case .drag(let id, let point, let ended): dragFromTray(id, at: point, ended: ended)
        case .radius(let radius): setRadius(radius)
        case .density(let density):
            tray.density = density
            rememberTray()
        case .collapse: toggleTray()
        case .filterReturn:
            if let first = tray.shelf.first {
                choose(item: first.id)
                tray.filter = ""
                giveMeadowTheKeyboard()
            }
        case .keyboardBack: giveMeadowTheKeyboard()
        }
    }

    /// V, B, E, the tray's buttons, View › Editor Tools: the tool, with what it holds put down first.
    func use(_ tool: EditorTray.Tool) {
        finishStroke()
        if tool != .select { disarm() }
        guard tray.tool != tool else { return updateTools() }
        tray.tool = tool
        tray.filter = ""
        if tool != .select { choose([]) }
        announce(String(localized: "\(EditorTrayView.describe(tool).name) tool", comment: "VoiceOver: the meadow editor's tool chosen"))
        rememberTray()
        updateTools()
    }

    /// A tile chosen: the Select tool's thing armed (clicked again, put back), the Brush's or the Eraser's kind.
    func choose(item id: String) {
        switch tray.tool {
        case .select:
            if let reason = tray.full[id] {
                announce(reason)
                return showReason(reason, at: trayPoint(), lasting: 2.5)
            }
            if tray.armed == id { return disarm() }
            arm(id)
        case .brush:
            tray.brushKind = id
            rememberTray()
        case .erase:
            tray.eraseKind = id
            rememberTray()
        }
        tray.highlighted = id
        updateTools()
    }

    /// Arms a thing: its ghost waits where the pointer (or the keyboard's cursor) is, drawn as it will be placed.
    func arm(_ id: String) {
        choose([])
        tray.armed = id
        pendingTurn = Double.random(in: 0..<(2 * .pi), using: &random)
        pending = nil
        if ghostSpot == nil { ghostSpot = cursor ?? viewMiddle() }
        drawPending()
        announce(String(localized: "\(MeadowWords.name(id)) ready to place. Click where it should stand; press Return to place it at the cursor.",
                        comment: "VoiceOver: a thing armed in the meadow editor's tray"))
    }

    /// Nothing armed any more: the ghost goes.
    func disarm() {
        guard tray.armed != nil || pending != nil else { return }
        tray.armed = nil
        pending = nil
        ghostRefusal = nil
        hideReason()
        updateTools()
    }

    /// The tray's hint, the tools' marks and the bar after a change of tool or of what is armed.
    func updateTools() {
        tray.hint = MeadowWords.hint(tray.tool, armed: tray.armed != nil)
        if tray.tool == .select { brushSpot = nil }
        updateMarks()
    }

    /// Double-click on a tile: armed and placed at once at the keyboard's cursor, or the view's middle, at the
    /// nearest spot round there where it may stand.
    func placeNow(_ id: String) {
        guard tray.tool == .select else { return choose(item: id) }
        if let reason = tray.full[id] {
            announce(reason)
            return showReason(reason, at: trayPoint(), lasting: 2.5)
        }
        if tray.armed != id { arm(id) }
        let spot = cursor ?? viewMiddle() ?? .zero
        ghostSpot = spot
        drawPending()
        placePending(searching: true, keepArmed: false)
    }

    // MARK: Placing

    /// The armed thing as it will be placed, at `ghostSpot`: drawn once for each placing (a fresh size, lean,
    /// shape and seed), then only moved and turned.
    func drawPending() {
        guard let id = tray.armed, let spot = ghostSpot else {
            pending = nil
            return updateMarks()
        }
        let at = SIMD2(Double(spot.x), Double(spot.y))
        if var item = pending, item.asset == id {
            item.placement = .at(MeadowPoint(MeadowJSON.quantized(at.x), MeadowJSON.quantized(at.y)))
            item.turn = MeadowEditSession.normalTurn(pendingTurn)
            pending = item
        } else {
            pending = library.session.fresh(id, at: at, turn: pendingTurn, using: &random)
        }
        if placingField == nil { placingField = library.session.placingField }
        ghostRefusal = pending.flatMap { library.session.placingRefusal($0, field: placingField!) }
        updateMarks()
    }

    /// Places the armed thing where its ghost is (`searching`: or the nearest spot round it where it may
    /// stand), as one step, and chooses it; `keepArmed` (⇧): a fresh one waits for the next place.
    @discardableResult
    func placePending(searching: Bool, keepArmed: Bool) -> Bool {
        guard let item = pending else { return false }
        let name = MeadowWords.place([item.asset])
        let result = library.edit(name) { session in
            searching ? session.add([item], around: SIMD2(item.at.x, item.at.z)) : session.place(item)
        }
        switch result {
        case .success(let change):
            let placed = change.added.map(\.id)
            meadow.scenery = library.scenery
            settle(placed)
            updateAccessibility()
            pending = nil
            if keepArmed {
                pendingTurn = item.turn
                choose([])
                drawPending()
            } else {
                tray.armed = nil
                ghostRefusal = nil
                choose(placed)
                updateTools()
            }
            announce(name)
            return true
        case .failure(let refused):
            let text = MeadowWords.refusal(refused.refusal)
            showReason(text, at: pointerOrMiddle(), lasting: 2.5)
            announce(text)
            return false
        }
    }

    /// Turns the armed thing's ghost (R, ⇧R, ⌥-scroll).
    func turnPending(by radians: Double) {
        pendingTurn = MeadowEditSession.normalTurn(pendingTurn + radians)
        drawPending()
    }

    /// The ground under the pointer, while it is over the meadow; else the keyboard's cursor, else the middle.
    func pointerOrMiddle() -> NSPoint {
        if let window = meadow.window {
            let p = meadow.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if meadow.bounds.contains(p) { return p }
        }
        if let spot = ghostSpot ?? cursor, let p = meadow.viewPoint(ofGround: spot) { return p }
        return NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY)
    }

    /// Just above the tray's middle (a refusal said for a tile).
    func trayPoint() -> NSPoint {
        let frame = trayHost.frame.insetBy(dx: EditorTrayView.margin, dy: EditorTrayView.margin)
        return navigator.view.convert(NSPoint(x: frame.midX, y: frame.maxY + Look.Space.xl), to: meadow)
    }

    /// A tile pressed and dragged out of the tray: armed, its ghost following the pointer over the meadow;
    /// let go over the meadow, placed there (where it may stand); let go back over the tray, put back.
    func dragFromTray(_ id: String, at windowPoint: NSPoint, ended: Bool) {
        guard tray.tool == .select else { return }
        if tray.full[id] != nil {
            if ended { choose(item: id) }
            return
        }
        if tray.armed != id { arm(id) }
        let p = meadow.convert(windowPoint, from: nil)
        let overTray = trayHost.frame.insetBy(dx: EditorTrayView.margin, dy: EditorTrayView.margin).contains(navigator.view.convert(windowPoint, from: nil))
        let ground = meadow.bounds.contains(p) && !overTray ? meadow.groundPoint(at: p) : nil
        tray.dragging = ended ? nil : id
        if let ground {
            ghostSpot = ground
            drawPending()
            if let refusal = ghostRefusal, !ended { showReason(MeadowWords.refusal(refusal), at: p, lasting: nil) } else if !ended { hideReason() }
        } else {
            hideReason()
        }
        guard ended else { return }
        if ground != nil, ghostRefusal == nil {
            placePending(searching: false, keepArmed: false)
        } else if ground != nil, let refusal = ghostRefusal {
            let text = MeadowWords.refusal(refusal)
            showReason(text, at: p, lasting: 2.5)
            announce(text)
        } else {
            disarm()
        }
    }

    // MARK: A placed thing settles

    /// What was placed settles into the meadow: from 92 % of its size to its own, over 160 ms, easing out (with
    /// Reduce Motion it is simply there). Only the picture: the meadow holds it at its own size already.
    func settle(_ ids: [Int]) {
        settling?.link?.invalidate()
        settling = nil
        guard Look.Motion.moves, !ids.isEmpty else { return }
        let link = meadow.displayLink(target: self, selector: #selector(settleTick(_:)))
        link.add(to: .main, forMode: .common)
        settling = Settling(ids: ids, started: CACurrentMediaTime(), link: link)
        settleTick(link)
    }

    @objc func settleTick(_ link: CADisplayLink) {
        guard let settling else { return link.invalidate() }
        let t = Float(min((CACurrentMediaTime() - settling.started) / Look.Motion.standard, 1))
        guard t < 1, !showsPreview else {
            self.settling = nil
            link.invalidate()
            if !showsPreview { meadow.scenery = library.scenery }
            return
        }
        let eased = 1 - (1 - t) * (1 - t)
        var scenery = library.scenery
        for id in settling.ids {
            guard let i = library.session.thingIndex(of: id) else { continue }
            scenery.things[i].size *= 0.92 + 0.08 * eased
        }
        meadow.scenery = scenery
    }

    // MARK: The Brush and the Eraser

    /// What the Brush paints now: its wildflower mix, or one kind.
    var brush: MeadowBrush {
        let kinds = tray.brushKind == EditorTray.wildflowers ? MeadowBrush.wildflowers : [MeadowBrush.Kind(tray.brushKind)]
        return MeadowBrush(kinds, radius: tray.brushRadius, density: tray.density)
    }

    /// The circle's radius now, for the tool in hand.
    var radius: Double { tray.tool == .erase ? tray.eraseRadius : tray.brushRadius }

    func setRadius(_ radius: Double) {
        if tray.tool == .erase {
            tray.eraseRadius = min(max(radius, EditorTray.eraseRadii.lowerBound), EditorTray.eraseRadii.upperBound)
        } else {
            tray.brushRadius = min(max(radius, MeadowBrush.radii.lowerBound), MeadowBrush.radii.upperBound)
        }
        rememberTray()
        updateMarks()
    }

    /// `[` and `]` with the Brush or the Eraser: the circle a unit smaller or larger.
    func stepRadius(_ by: Double) {
        setRadius((radius + by).rounded())
        announce(String(localized: "Size \(Int(radius.rounded()))", comment: "VoiceOver: the Brush's or the Eraser's size, in units"))
    }

    /// A stroke begins at `spot` (pressed on the grass with the Brush, ⌥-pressed for clearing what it paints, or
    /// with the Eraser): the meadow from now on drawn as the stroke leaves it.
    func beginStroke(at spot: SIMD2<Float>, erasing: Bool) {
        finishStroke()
        let session = library.session
        let at = SIMD2(Double(spot.x), Double(spot.y))
        var stroke = Stroke(erasing: erasing, working: session, field: erasing ? SceneryRules.Field(MeadowScenery()) : session.placingField, last: at)
        stroke.preview = session.scenery
        if erasing {
            switch tray.tool {
            case .brush: stroke.kind = tray.brushKind == EditorTray.wildflowers ? nil : tray.brushKind
                stroke.brush = brush
            default: stroke.kind = tray.eraseKind == EditorTray.anyKind ? nil : tray.eraseKind
            }
        } else {
            stroke.brush = brush
        }
        self.stroke = stroke
        dab(at: at)
    }

    /// The stroke carries on to `spot`: a dab each half radius along the way.
    func continueStroke(to spot: SIMD2<Float>) {
        guard let stroke else { return }
        let at = SIMD2(Double(spot.x), Double(spot.y))
        let gap = max(radius / 2, 0.5)
        var from = stroke.last
        while simd_distance(from, at) >= gap {
            from += simd_normalize(at - from) * gap
            dab(at: from)
        }
    }

    /// One dab: plants added (the Brush), or the small things within the circle taken (the Eraser, or ⌥ with
    /// the Brush: only what it paints).
    private func dab(at spot: SIMD2<Double>) {
        guard var stroke else { return }
        stroke.last = spot
        if stroke.erasing {
            var ids = stroke.working.swept(at: spot, radius: radius, kind: stroke.kind).filter { !stroke.removed.contains($0) }
            if let brush = stroke.brush, stroke.kind == nil {
                // ⌥ with the wildflower mix: only the mix's flowers.
                let kinds = Set(brush.kinds.map(\.asset))
                ids = ids.filter { stroke.working.item($0).map { kinds.contains($0.asset) } ?? false }
            }
            stroke.removed.formUnion(ids)
            for id in ids {
                if let i = stroke.working.thingIndex(of: id) { stroke.preview.things[i].size = Self.swept }
            }
            self.stroke = stroke
            if !ids.isEmpty { meadow.scenery = stroke.preview }
            return
        } else if let brush = stroke.brush {
            let dab = stroke.working.dab(brush, at: spot, field: &stroke.field, adding: 0, using: &random)
            stroke.added += stroke.working.append(dab.items).added
            if let full = dab.full, stroke.full == nil {
                stroke.full = full
                let text = MeadowWords.refusal(full)
                showReason(text, at: meadow.viewPoint(ofGround: SIMD2(Float(spot.x), Float(spot.y))) ?? pointerOrMiddle(), lasting: 3)
                announce(text)
            }
        }
        self.stroke = stroke
        meadow.scenery = stroke.working.scenery
    }

    /// The size a swept thing is drawn at until the sweep is let go: nothing to see.
    static let swept = SIMD3<Float>(repeating: 1e-4)

    /// The stroke let go: what it added or took away is one step ("Brush Daisies", "Erase 12 Things").
    func finishStroke() {
        guard let stroke else { return }
        self.stroke = nil
        let session = library.session
        if stroke.erasing {
            let names = session.drawnIDs.filter(stroke.removed.contains).compactMap { session.item($0)?.asset }
            if !stroke.removed.isEmpty {
                let name = MeadowWords.erase(names)
                library.edit(name) { .success($0.delete(stroke.removed)) }
                announce(name)
            }
        } else if !stroke.added.isEmpty {
            let name = MeadowWords.brush(tray.brushKind)
            library.edit(name) { session in
                session.apply(MeadowChange(added: stroke.added))
                return .success(MeadowChange(added: stroke.added))
            }
            announce(String(localized: "\(name), \(stroke.added.count) planted", comment: "VoiceOver: a Brush stroke done, and how many plants it planted"))
        }
        meadow.scenery = library.scenery
        updateAccessibility()
        updateMarks()
    }

    /// Esc during a stroke: nothing of it is kept.
    func cancelStroke() {
        guard stroke != nil else { return }
        stroke = nil
        meadow.scenery = library.scenery
        updateMarks()
    }

    /// A click with the Eraser: the thing under the pointer taken away (of the chosen kind only, when one is
    /// chosen), a tree as well as a flower. One step.
    func erase(_ id: Int) {
        guard let item = library.session.item(id) else { return }
        if tray.eraseKind != EditorTray.anyKind, item.asset != tray.eraseKind {
            let text = MeadowWords.onlyErasing(tray.eraseKind)
            showReason(text, at: pointerOrMiddle(), lasting: 2)
            return announce(text)
        }
        let name = MeadowWords.erase([item.asset])
        library.edit(name) { .success($0.delete([id])) }
        meadow.scenery = library.scenery
        hovered = nil
        updateAccessibility()
        updateMarks()
        announce(name)
    }

    /// Return with the Brush or the Eraser: one dab at the keyboard's cursor, as its own step.
    func dabAtCursor() {
        let spot = cursor ?? viewMiddle() ?? .zero
        cursor = spot
        beginStroke(at: spot, erasing: tray.tool == .erase)
        finishStroke()
    }

    // MARK: How full the meadow is

    /// The tray's word on how full the meadow is (past 80 % of a cap) and the kinds it holds as many of as it can.
    func updateFullness() {
        let session = library.session
        let counts = session.document.counts(session.catalog)
        let things = session.document.entries.count
        let trees = counts[.trees, default: 0], tall = counts[.tall, default: 0]
        var full: [String: String] = [:]
        for item in EditorTray.things {
            guard let probe = session.fresh(item.id, at: .zero, turn: 0, using: &random), let refusal = session.capacity(for: [probe]) else { continue }
            full[item.id] = MeadowWords.refusal(refusal)
        }
        if tray.full != full { tray.full = full }
        // The fullest cap past 80 %.
        let shares: [(Double, String)] = [
            (Double(things) / Double(MeadowFormat.maxItems), MeadowWords.fullness(things, of: MeadowFormat.maxItems, nil)),
            (Double(trees) / Double(MeadowCatalog.Cap.trees.limit), MeadowWords.fullness(trees, of: MeadowCatalog.Cap.trees.limit, .trees)),
            (Double(tall) / Double(MeadowCatalog.Cap.tall.limit), MeadowWords.fullness(tall, of: MeadowCatalog.Cap.tall.limit, .tall)),
        ]
        let fullest = shares.filter { $0.0 >= 0.8 }.max { $0.0 < $1.0 }?.1
        if tray.fullness != fullest { tray.fullness = fullest }
        if let armed = tray.armed, full[armed] != nil { disarm() }
    }

    // MARK: Keeping the tray's choices

    private static let trayKey = "meadowEditorTray"

    /// The tray as it was left: folded or not, the tool's sizes, the Brush's density and kinds.
    func restoreTray() {
        guard let saved = AppPlaces.defaults.dictionary(forKey: Self.trayKey) else { return }
        tray.collapsed = saved["collapsed"] as? Bool ?? false
        if let radius = saved["brushRadius"] as? Double { tray.brushRadius = min(max(radius, MeadowBrush.radii.lowerBound), MeadowBrush.radii.upperBound) }
        if let radius = saved["eraseRadius"] as? Double { tray.eraseRadius = min(max(radius, EditorTray.eraseRadii.lowerBound), EditorTray.eraseRadii.upperBound) }
        if let density = (saved["density"] as? String).flatMap(MeadowBrush.Density.init(rawValue:)) { tray.density = density }
        let brushes = Set(EditorTray.brushes.map(\.id)), erasers = Set(EditorTray.erasers.map(\.id))
        if let kind = saved["brushKind"] as? String, brushes.contains(kind) { tray.brushKind = kind }
        if let kind = saved["eraseKind"] as? String, erasers.contains(kind) { tray.eraseKind = kind }
    }

    func rememberTray() {
        AppPlaces.defaults.set(["collapsed": tray.collapsed, "brushRadius": tray.brushRadius, "eraseRadius": tray.eraseRadius,
                                "density": tray.density.rawValue, "brushKind": tray.brushKind, "eraseKind": tray.eraseKind] as [String: Any], forKey: Self.trayKey)
    }

    /// View › Hide Editor Tray (⌥⌘T) and the tray's fold: only its top row, or all of it. Remembered.
    func toggleTray() {
        tray.collapsed.toggle()
        rememberTray()
        layoutTray(animated: true)
        announce(tray.collapsed ? String(localized: "Tray folded", comment: "VoiceOver: the meadow editor's tray folded to its top row")
                                : String(localized: "Tray unfolded", comment: "VoiceOver: the meadow editor's tray shows its shelf"))
    }

    // MARK: The tray's place and pictures

    /// The tray along the meadow's bottom edge, as wide as the meadow leaves room for (at most what its shelf
    /// needs), and the view framing the picnic ground above it.
    func layoutTray(animated: Bool = false) {
        let container = navigator.view.bounds
        tray.narrow = container.width < 760
        let margin = EditorTrayView.margin
        let width = min(container.width - 2 * Look.Space.xl, Self.trayWidest) + 2 * margin
        let height = tray.cardHeight + 2 * margin
        let frame = NSRect(x: (container.midX - width / 2).rounded(), y: Look.Space.xl - margin, width: width.rounded(), height: height)
        if trayHost.frame != frame { trayHost.frame = frame }
        trayKeys.frame = NSRect(x: frame.minX + margin, y: frame.minY + margin, width: 1, height: 1)
        meadow.editingCover = frame.maxY - margin + Look.Space.m
    }

    /// The widest the tray grows: room for a shelf of a dozen things and the top row.
    static let trayWidest: CGFloat = 1040

    /// Each tile's picture, drawn by the scene (`MeadowView.portrait`) over the tile's colour in the theme, at the
    /// screen's scale; kept, so a picture is drawn once for each theme and scale.
    func updatePictures() {
        let scale = meadow.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int((EditorTray.tile * scale).rounded())
        // The tile's colour as the tray draws it, in its own appearance (a theme's colours follow light and dark).
        var behind = MeadowColor(hex: 0xffffff)
        trayHost.effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = Colors.terminalBackground.usingColorSpace(.sRGB) ?? .white
            behind = MeadowColor(red: Float(background.redComponent), green: Float(background.greenComponent), blue: Float(background.blueComponent))
        }
        var pictures: [String: CGImage] = [:]
        let items = EditorTray.things + EditorTray.brushes.filter { $0.id == EditorTray.wildflowers }
        for item in items where !item.pictured.isEmpty {
            let key = EditorTray.pictureKey(item, pixels: pixels, background: behind)
            if let made = pictureCache[key] ?? meadow.portrait(of: item.pictured, pixels: pixels, background: behind) {
                pictureCache[key] = made
                pictures[item.id] = made
            }
        }
        if tray.pictures.keys.sorted() != pictures.keys.sorted() || tray.pictures.values.map(ObjectIdentifier.init) != pictures.values.map(ObjectIdentifier.init) {
            tray.pictures = pictures
        }
    }

    /// The keyboard to the shelf (Tab from the meadow): ← → go from thing to thing, Return chooses.
    func giveTrayTheKeyboard() {
        guard let window = meadow.window, trayHost.superview != nil else { return }
        if tray.collapsed { toggleTray() }
        window.makeFirstResponder(trayKeys)
    }

    /// The keyboard back in the meadow (Esc or Tab from the shelf or the filter field, a thing chosen there).
    func giveMeadowTheKeyboard() {
        meadow.window?.makeFirstResponder(meadow)
    }

    /// ⌘F: the tray's filter field, the Select tool's shelf unfolded.
    func findInTray() {
        if tray.tool != .select { use(.select) }
        if tray.collapsed { toggleTray() }
        tray.findRequests += 1
    }
}
