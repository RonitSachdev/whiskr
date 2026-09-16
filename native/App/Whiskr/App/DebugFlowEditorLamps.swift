#if DEBUG
import AppKit
import MeadowFile
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// The editor flow's part for the garden lamp (Stage 9, `DebugFlowEditor.swift`), through the app's own event paths:
/// - the lamp on the Workplace shelf, named, found by other words;
/// - at night its ghost lights the ground where it would stand, before it is placed, and follows the pointer;
/// - kept off the picnic ground, with the reason;
/// - placed with a click: lit at once, its pool where it stands; undone, its light goes with it;
/// - pictures: the ghost's pool at night, the placed lamps at night and by day.
extension EditorFlow {
    func lamps() async {
        await enter()
        editor.debugChoose([])
        suite.shortcut("0")
        await PerfWait.sleep(1200)
        await still()
        let id = "work.lampPost"
        check("the garden lamp is on the Workplace shelf, by name, and found by other words",
              EditorTray.things.contains { $0.id == id && $0.category == .workplace } && MeadowWords.name(id) == String(localized: "Garden lamp")
                  && EditorTray.things.first { $0.id == id }.map { EditorTray.matches($0, "street lamp") && EditorTray.matches($0, "lantern") } == true)

        let store = WorldStore.shared, time = store.settings.timeOfDay
        store.settings.timeOfDay = .night
        _ = await PerfWait.until(2000) { self.meadow.settings.timeOfDay == .night && self.meadow.sky.lampsLit }
        await PerfWait.sleep(600)

        guard let middle = meadow.groundPoint(at: NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY + 60)) else { return check("ground in view", false) }
        await pressTray("tray.category.workplace")
        await pressTray("tray.item.\(id)")
        check("the lamp's tile arms it", tray.armed == id, "armed \(tray.armed ?? "nothing")")

        // Over the picnic ground: refused, with the reason.
        if let picnic = meadow.viewPoint(ofGround: SIMD2(0, middle.y)), meadow.bounds.insetBy(dx: 60, dy: 60).contains(picnic) {
            await hoverMeadow(picnic)
            await PerfWait.sleep(200)
            check("a lamp is kept off the picnic ground, and says why", meadow.editMarks.ghostRefused, "ghost refused \(meadow.editMarks.ghostRefused)")
        }

        // Beside it: the ghost's light is on the ground before it is placed, and goes where the pointer goes.
        guard let first = freeSpot(for: id, near: SIMD2(30, middle.y)), let second = freeSpot(for: id, near: SIMD2(-34, middle.y + 10)),
              let a = meadow.viewPoint(ofGround: first), let b = meadow.viewPoint(ofGround: second) else {
            return check("free ground in view for two lamps", false)
        }
        await hoverMeadow(a)
        await PerfWait.sleep(300)
        let ghostLit = meadow.lamplight(at: first)
        await picture("lamps-ghost-night")
        await hoverMeadow(b)
        await PerfWait.sleep(300)
        check("at night the lamp's ghost lights the ground where it would stand, and its light follows the pointer",
              ghostLit > 0.9 && meadow.lamplight(at: first) < 0.01 && meadow.lamplight(at: second) > 0.9,
              String(format: "ghost at first %.2f, after moving %.2f there and %.2f at the second", ghostLit, meadow.lamplight(at: first), meadow.lamplight(at: second)))

        // Placed: lit at once (no warming up for a lamp just placed), its light staying.
        let before = count
        for point in [a, b] {
            if tray.armed != id { await pressTray("tray.item.\(id)") }
            await hoverMeadow(point)
            click(at: point)
            await PerfWait.sleep(300)
        }
        suite.shortcut("esc")
        await PerfWait.sleep(300)
        let placed = library.session.drawnIDs.suffix(2).compactMap { library.session.item($0) }
        check("two lamps placed, each a step, lit at once where they stand",
              count == before + 2 && placed.allSatisfy { $0.asset == id && $0.size == nil } && undoName == MeadowWords.place([id])
                  && meadow.sky.lamps.burning >= 2 && meadow.lamplight(at: first) > 0.9 && meadow.lamplight(at: second) > 0.9,
              "\(count - before) placed, \(meadow.sky.lamps), light \(meadow.lamplight(at: first)), \(meadow.lamplight(at: second))")
        await still()
        await picture("lamps-placed-night")
        suite.shortcut("cmd+z")
        await PerfWait.sleep(300)
        check("undone, the lamp's light goes with it", meadow.lamplight(at: second) < 0.01 && meadow.lamplight(at: first) > 0.9)
        suite.shortcut("shift+cmd+z")
        await PerfWait.sleep(300)
        check("redone, it is lit again", meadow.lamplight(at: second) > 0.9)

        store.settings.timeOfDay = .day
        _ = await PerfWait.until(2000) { self.meadow.settings.timeOfDay == .day }
        _ = await PerfWait.until(40000) { self.meadow.sky.lamps.burning + self.meadow.sky.lamps.changing == 0 }
        check("by day the lamps go out, and their light with them", meadow.sky.lamps.burning == 0 && meadow.lamplight(at: first) == 0,
              "\(meadow.sky.lamps)")
        await picture("lamps-placed-day")
        store.settings.timeOfDay = time
        await PerfWait.sleep(800)
        suite.shortcut("cmd+z")
        suite.shortcut("cmd+z")
        await PerfWait.sleep(300)
        check("⌘Z takes both lamps away again", count == before, "\(count - before) left")
    }

    /// Thirty-two garden lamps, round the full meadow's edge inside its trees, for its night at rest.
    static func fullMeadowLamps() -> [MeadowEntry] {
        (0..<MeadowCatalog.Cap.lamps.limit).map { k in
            let a = Double(k) / Double(MeadowCatalog.Cap.lamps.limit) * 2 * .pi + 0.08
            return .item(MeadowFile.MeadowItem(asset: "work.lampPost", placement: .at(MeadowPoint(MeadowJSON.quantized(cos(a) * 128), MeadowJSON.quantized(sin(a) * 128)))))
        }
    }

    /// The full meadow by night, its 32 lamps lit: what warming up costs, and what it costs once they burn steadily,
    /// at rest.
    func fullMeadowAtNight() async {
        let store = WorldStore.shared, time = store.settings.timeOfDay
        store.settings.timeOfDay = .night
        _ = await PerfWait.until(2000) { self.meadow.settings.timeOfDay == .night }
        let warming = meadow.sky.lamps
        await suite.idleStretch("editor: idle at night, 32 lamps warming up", limits: false)
        let burning = await PerfWait.until(90000) { self.meadow.sky.lamps.burning == MeadowCatalog.Cap.lamps.limit }
        check("at dusk the full meadow's 32 lamps come on one by one, and all burn steadily within a minute and a half",
              warming.all == MeadowCatalog.Cap.lamps.limit && warming.burning < warming.all && burning != nil, "\(warming), then \(meadow.sky.lamps)")
        let rested = await PerfWait.until(12000) { self.meadow.isResting }
        check("a full meadow with 32 lamps lit rests within 12 s", rested != nil, meadow.restBlockers)
        await suite.idleStretch("editor: idle at night, 32 lamps lit", limits: false)
        await picture("full-meadow-night")
        // The same night with the lamps switched off, to set their cost against.
        store.settings.lamps = false
        _ = await PerfWait.until(40000) { self.meadow.sky.lamps.burning + self.meadow.sky.lamps.changing == 0 }
        await suite.idleStretch("editor: idle at night, lamps switched off", limits: false)
        store.settings.lamps = true
        store.settings.timeOfDay = time
        await PerfWait.sleep(800)
    }
}
#endif
