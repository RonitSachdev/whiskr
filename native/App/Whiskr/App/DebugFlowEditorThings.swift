#if DEBUG
import AppKit
import MeadowFile
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// The editor flow's part for the things Stage 7 brought (`DebugFlowEditor.swift`), every press, release, key and
/// wheel through the app's own event paths:
/// - one of each placed from its shelf by a click where it may stand (each one step, drawn as the file holds it),
///   the shelves of Stones & Wood, Workplace and Cat Things as the catalog orders them;
/// - the Eraser's sweep passing a cat's bed and a stump without taking them (only a click does);
/// - the filter finding things by other words and ids, hiragana against katakana;
/// - a long shelf scrolled by the wheel (never zooming the meadow behind it) and by the keys;
/// - pictures: the things from the editor's height and close up, by day and by night, and their shelves in
///   whiskr-light, whiskr-dark and graphite.
extension EditorFlow {
    /// Stage 7's things, in the catalog's order.
    static let newThings = ["tree.apple", "tree.pine", "flower.cornflower", "flower.foxglove", "plant.fern", "plant.clover", "stone.boulder", "wood.stump",
                            "wood.logPile", "work.cushion", "cat.box", "cat.scratchingPost", "cat.yarn", "cat.bed", "cat.bowl"]

    /// Free ground in view where the thing armed now (its ghost: its own size, turn and shape, as it will be placed)
    /// may stand. Judged as the editor judges the ghost (`placingRefusal`): a probe of another size passed spots the
    /// ghost itself was refused, as a boulder drawn 1.35 across where a 1.25 one fitted (a click then placed nothing).
    func freeSpot(for id: String, near spot: SIMD2<Float>) -> SIMD2<Float>? {
        guard let armed = editor.debugPending.item, armed.asset == id else { return nil }
        let session = library.session, field = session.placingField, card = trayCard.insetBy(dx: -30, dy: -30)
        for ring in stride(from: Float(0), through: 44, by: 2) {
            for k in 0..<(ring == 0 ? 1 : 20) {
                let a = Float(k) / 20 * 2 * .pi
                let p = spot + SIMD2(cos(a), sin(a)) * ring
                guard let view = meadow.viewPoint(ofGround: p), meadow.bounds.insetBy(dx: 90, dy: 90).contains(view), !card.contains(view) else { continue }
                // Free a little round it too: the click's point, read back from the view, lands within a hair of it.
                let free = [SIMD2<Float>.zero, SIMD2(0.3, 0), SIMD2(-0.3, 0), SIMD2(0, 0.3), SIMD2(0, -0.3)].allSatisfy { nudge in
                    var probe = armed
                    probe.placement = .at(MeadowPoint(MeadowJSON.quantized(Double(p.x + nudge.x)), MeadowJSON.quantized(Double(p.y + nudge.y))))
                    return session.placingRefusal(probe, field: field) == nil
                }
                if free { return p }
            }
        }
        return nil
    }

    func newThings() async {
        await enter()
        editor.debugChoose([])
        suite.shortcut("0")
        await PerfWait.sleep(1200)
        menu(["View", "Editor View", "Face North"])
        await PerfWait.sleep(1200)
        await still()

        // The shelves as the catalog orders them, with the categories that now hold something.
        check("the tray offers Stage 7's things on their shelves: Stones & Wood, Workplace and Cat Things",
              EditorTray.categories == [.trees, .flowers, .stonesAndWood, .ground, .garden, .workplace, .catThings]
                  && EditorTray.things.filter { $0.category == .catThings }.map(\.id) == ["cat.box", "cat.scratchingPost", "cat.yarn", "cat.bed", "cat.bowl"]
                  && EditorTray.things.filter { $0.category == .workplace }.map(\.id).first == "work.desk"
                  && Self.newThings.allSatisfy { id in EditorTray.things.contains { $0.id == id } },
              "\(EditorTray.categories)")
        check("the Brush paints the new plants; the Eraser's kinds are the small things only (no made thing, no wood, no boulder)",
              ["flower.cornflower", "flower.foxglove", "plant.fern", "plant.clover"].allSatisfy { id in EditorTray.brushes.contains { $0.id == id } }
                  && !EditorTray.erasers.contains { ["cat.bed", "wood.stump", "stone.boulder", "work.cushion"].contains($0.id) }
                  && EditorTray.erasers.contains { $0.id == "plant.clover" })

        // One of each, placed with a click where it may stand, round the middle of the view (trees off the picnic ground).
        guard let middle = meadow.groundPoint(at: NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY + 60)) else { return check("ground in view", false) }
        let before = count
        var placed: [(id: String, entry: Int)] = []
        for (k, id) in Self.newThings.enumerated() {
            let asset = MeadowCatalog.current.asset(id)!
            await pressTray("tray.category.\((EditorTray.shelf(of: id) ?? asset.category).rawValue)")
            await pressTray("tray.item.\(id)")
            // Beside the picnic ground, where nothing has to make way for a blanket.
            let near = SceneryRules.isBig(id) ? SIMD2<Float>(k == 0 ? -42 : 46, middle.y + 6) : SIMD2(29 + Float(k % 4) * 5, middle.y - 8 + Float(k / 4) * 5)
            guard tray.armed == id, let spot = freeSpot(for: id, near: near), let point = meadow.viewPoint(ofGround: spot) else {
                check("\(id): armed, with free ground in view to place it", false, "armed \(tray.armed ?? "nothing")")
                continue
            }
            await hoverMeadow(point)
            click(at: point)
            await PerfWait.sleep(250)
            let entry = library.session.drawnIDs.last ?? -1
            let item = library.session.item(entry)
            check("\(MeadowWords.name(id)): placed where clicked as one step, drawn as the file holds it",
                  item?.asset == id && undoName == MeadowWords.place([id]) && meadow.scenery == library.scenery && MeadowScenery.draws(id)
                      && item.map { hypot($0.at.x - Double(spot.x), $0.at.z - Double(spot.y)) < 0.8 } == true,
                  "\(item?.asset ?? "nothing") at \(String(describing: item?.at)), step “\(undoName)”")
            if item?.asset == id { placed.append((id, entry)) }
        }
        check("all fifteen placed, each its own step", placed.count == Self.newThings.count && count == before + placed.count, "\(placed.count) placed")
        // Made things are cat-sized and never scaled; living things vary; the cats' spots are where the things are.
        let items = placed.compactMap { library.session.item($0.entry) }
        check("made things and wood as they are made; plants and trees each their own size",
              items.filter { ["cat", "work", "wood"].contains($0.asset.split(separator: ".").first.map(String.init) ?? "") }.allSatisfy { $0.size == nil && $0.tilt == nil }
                  && items.filter { $0.asset.hasPrefix("flower.") || $0.asset.hasPrefix("tree.") }.allSatisfy { $0.size != nil || $0.tilt != nil })
        let spots = items.compactMap { item in library.session.thing(item)?.catSpot.map { (item, $0) } }
        check("each thing that invites a cat says where, at the thing", spots.count == 8
              && spots.allSatisfy { item, spot in hypot(Double(spot.at.x) - item.at.x, Double(spot.at.z) - item.at.z) < 2 }, "\(spots.count) spots")
        editor.debugChoose([])
        await PerfWait.sleep(300)
        await picture("things-placed")

        // The Eraser's sweep passes the bed and the stump and takes neither.
        if let bed = placed.first(where: { $0.id == "cat.bed" })?.entry, let at = library.session.item(bed)?.at,
           let from = meadow.viewPoint(ofGround: SIMD2(Float(at.x) - 4, Float(at.z))), let to = meadow.viewPoint(ofGround: SIMD2(Float(at.x) + 4, Float(at.z))) {
            suite.shortcut("e")
            let steps = count
            await dragPointer(from: from, to: to, steps: 30)
            check("the Eraser's sweep passes a cat's bed without taking it", library.session.item(bed) != nil)
            if count != steps { suite.shortcut("cmd+z") }
            suite.shortcut("esc")
        }

        // Close up, by day and by night.
        if let cats = placed.first(where: { $0.id == "cat.box" })?.entry, let at = library.session.item(cats)?.at,
           let point = meadow.viewPoint(ofGround: SIMD2(Float(at.x) + 4, Float(at.z) - 2)) {
            let distance = meadow.cameraView.distance
            meadow.simulateZoom(by: 0.3, at: point)
            await still()
            check("the view comes close to the things", meadow.cameraView.distance < distance * 0.5, "\(distance) → \(meadow.cameraView.distance)")
            await picture("things-close-day")
            let store = WorldStore.shared, time = store.settings.timeOfDay
            store.settings.timeOfDay = .night
            _ = await PerfWait.until(2000) { self.meadow.settings.timeOfDay == .night }
            await PerfWait.sleep(800)
            await picture("things-close-night")
            suite.shortcut("0")
            await PerfWait.sleep(1200)
            await still()
            await picture("things-night")
            store.settings.timeOfDay = time
            _ = await PerfWait.until(2000) { self.meadow.settings.timeOfDay != .night }
            await PerfWait.sleep(600)
        }

        await filtering()
        await shelfScrolling()
        await shelfPictures()

        for _ in placed { suite.shortcut("cmd+z") }
        check("⌘Z takes every one away again", count == before, "\(count - before) left")
        suite.shortcut("esc")
    }

    // MARK: The filter

    private func filtering() async {
        suite.shortcut("v")
        suite.shortcut("cmd+f")
        _ = await PerfWait.until(3000) { self.tray.filterHasKeyboard }
        for (query, wanted) in [("cat", ["cat.box", "cat.scratchingPost", "cat.yarn", "cat.bed", "cat.bowl"]), ("post", ["garden.fence", "work.signpost", "work.mailbox", "cat.scratchingPost", "work.lampPost"]),
                                ("firewood", ["wood.logPile"]), ("zabuton", ["work.cushion"]), ("conifer", ["tree.pine"]), ("TOADSTOOL", ["fungus.flyAgaric"])] {
            suite.typeKeys(query)
            _ = await PerfWait.until(2000) { self.tray.filter == query }
            check("the filter finds “\(query)” by other words and ids", Set(tray.shelf.map(\.id)) == Set(wanted), "“\(tray.filter)”: \(tray.shelf.map(\.id))")
            // Emptied as its × does; the field shows it before the next is typed.
            tray.filter = ""
            _ = await PerfWait.until(2000) { self.tray.filterField?.stringValue.isEmpty == true }
        }
        // Hiragana finds a name in katakana (Japanese names: "クローバー"), and the other way round.
        let clover = EditorTray.Item(id: "plant.clover", name: "クローバー", category: .flowers, pictured: ["plant.clover"])
        check("the filter takes hiragana for katakana and back", EditorTray.matches(clover, "くろーばー") && EditorTray.matches(clover, "クロ")
              && !EditorTray.matches(clover, "しだ"))
        suite.shortcut("esc")
        await PerfWait.sleep(150)
    }

    // MARK: A long shelf

    /// The shelf's scroll view in the tray.
    private var shelfScroller: NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView.map({ $0.frame.height < 200 }) == true { return scroll }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(editor.trayHost)
    }

    private func shelfScrolling() async {
        // A narrow window and a filter that finds most things: a shelf longer than the card.
        window.setContentSize(NSSize(width: 760, height: 640))
        await PerfWait.sleep(600)
        await still()
        suite.shortcut("cmd+f")
        _ = await PerfWait.until(3000) { self.tray.filterHasKeyboard }
        suite.typeKeys("e")
        _ = await PerfWait.until(3000) { self.shelfScroller?.documentView.map { $0.frame.width > 700 } == true }
        guard let scroller = shelfScroller, let document = scroller.documentView, document.frame.width > scroller.contentView.bounds.width + 40 else {
            suite.shortcut("esc")
            window.setContentSize(NSSize(width: 1440, height: 900))
            return check("a filtered shelf longer than the tray, to scroll", false, "\(String(describing: shelfScroller?.documentView?.frame)) in \(String(describing: shelfScroller?.contentView.bounds))")
        }
        let camera = meadow.cameraView
        // The wheel turned (a mouse's, up and down only) over a tile, delivered where the window sends it.
        let start = scroller.contentView.bounds.origin.x
        let card = trayCard, over = NSPoint(x: card.midX, y: card.minY + 50)
        let target = suite.hit(meadow, at: over)
        for _ in 0..<6 {
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -30, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: wheel) else { break }
            target?.scrollWheel(with: event)
            await PerfWait.sleep(30)
        }
        await PerfWait.sleep(300)
        let scrolled = scroller.contentView.bounds.origin.x
        check("a mouse's wheel over the shelf scrolls it along, and never zooms the meadow behind it",
              scrolled > start + 60 && abs(meadow.cameraView.distance - camera.distance) < 0.01, "shelf \(start) → \(scrolled), view \(camera.distance) → \(meadow.cameraView.distance)")
        await picture("tray-long-scrolled")
        // The keys, along the filtered shelf: Tab in the filter hands it the keyboard, → goes to the last tile, which
        // is brought into view. Each step waits for what it does, not for a time (a busy Mac's main thread runs late).
        let filtered = tray.shelf.map(\.id)
        suite.shortcut("tab")
        let onShelf = await PerfWait.until(3000) { self.tray.shelfHasKeyboard && self.window.firstResponder === self.editor.trayKeys } != nil
        check("Tab in the filter hands the shelf, still filtered, the keyboard", onShelf && tray.shelf.map(\.id) == filtered && tray.highlighted == filtered.first,
              "on shelf \(onShelf), filter “\(tray.filter)”, on \(tray.highlighted ?? "none")")
        for _ in 0..<(filtered.count - 1) { suite.shortcut("right") }
        let last = filtered.last
        func lastVisible() -> Bool {
            last.flatMap { tile($0) }.map { view in
                let rect = view.convert(view.bounds, to: scroller.contentView)
                return scroller.contentView.bounds.insetBy(dx: -2, dy: -40).contains(rect)
            } ?? false
        }
        _ = await PerfWait.until(3000) { self.tray.highlighted == last && lastVisible() }
        check("→ along the shelf brings each tile into view, to the last", tray.highlighted == last && lastVisible(), "on \(tray.highlighted ?? "none") of \(filtered.count)")
        await picture("tray-long-keys")
        suite.shortcut("esc")
        tray.filter = ""
        window.setContentSize(NSSize(width: 1440, height: 900))
        await PerfWait.sleep(600)
        await still()
    }

    // MARK: Pictures of the shelves

    private func shelfPictures() async {
        let store = ThemeStore.shared
        let before = (store.themeID, store.appearance)
        defer {
            store.themeID = before.0
            store.appearance = before.1
        }
        for (name, id, appearance) in [("whiskr-light", BuiltInThemes.defaultID, ThemeStore.Appearance.light), ("whiskr-dark", BuiltInThemes.defaultID, .dark),
                                       ("graphite", "graphite", .dark)] {
            store.themeID = id
            store.appearance = appearance
            await PerfWait.sleep(500)
            for category in [MeadowAsset.Category.trees, .flowers, .stonesAndWood, .garden, .workplace, .catThings] {
                await pressTray("tray.category.\(category.rawValue)")
                await PerfWait.sleep(300)
                let pictured = tray.shelf.allSatisfy { tray.pictures[$0.id].map(Self.hasSubject) == true }
                check("\(name): the \(MeadowWords.categoryName(category)) shelf, every tile pictured", pictured)
                await picture("shelf-\(category.rawValue)-\(name)")
            }
        }
        suite.shortcut("1")
    }
}
#endif
