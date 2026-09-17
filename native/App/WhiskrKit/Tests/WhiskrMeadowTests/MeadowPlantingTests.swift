import Foundation
import MeadowFile
import MeadowScene
import Testing
import simd
@testable import WhiskrMeadow

// New things in a meadow: a thing placed from the tray drawn as it would grow, the caps said kindly before
// anything is refused, the Brush's clumps (never an even sprinkle, never overlapping, one step a stroke) and the
// Eraser's sweeps (never a tree, never what a newer Whiskr wrote).

/// The same numbers every run.
private struct Steady: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func item(_ id: String, _ x: Double, _ z: Double, seed: UInt32? = nil) -> MeadowEntry {
    .item(MeadowFile.MeadowItem(asset: id, placement: .at(MeadowPoint(x, z)), seed: seed))
}

@Suite struct PlacingAThing {
    @Test("a new living thing has its own size, lean, shape and (a tree) seed, within its kind's; a stone its own size; the log none")
    func fresh() throws {
        let session = MeadowEditSession(MeadowDocument(entries: []))
        var random = Steady(1)
        let oaks = (0..<20).compactMap { _ in session.fresh("tree.oak", at: SIMD2(30, 0), turn: 0.5, using: &random) }
        #expect(oaks.count == 20 && Set(oaks.compactMap(\.seed)).count == 20, "no two oaks alike")
        for oak in oaks {
            let size = try #require(oak.size)
            #expect(size.allSatisfy { (0.8 * 0.88 - 1e-9...1.2 * 1.12 + 1e-9).contains($0) && (0.8...1.2).contains($0) })
            #expect((oak.tilt ?? [0, 0]).allSatisfy { abs($0) <= 0.05 })
            #expect(oak.turn == 0.5 && oak.at == MeadowPoint(30, 0))
        }
        let daisies = (0..<40).compactMap { _ in session.fresh("flower.daisy", at: .zero, turn: 0, using: &random) }
        #expect(Set(daisies.map(\.variant)) == [0, 1], "both of its shapes")
        let stone = try #require(session.fresh("stone.mossy", at: .zero, turn: 0, using: &random))
        #expect(stone.size.map { $0.allSatisfy { (0.69...1.36).contains($0) } } == true && stone.seed == nil)
        let log = try #require(session.fresh("wood.fallenLog", at: SIMD2(-40, 0), turn: 1, using: &random))
        #expect(log.size == nil && log.tilt == nil && log.seed == nil)
        // Stage 7's: a pine from a seed of its own within a tree's sizes; a boulder found at a size of its own; a
        // stump, a log pile and made things as they are (never scaled, leant or seeded).
        let pine = try #require(session.fresh("tree.pine", at: .zero, turn: 0, using: &random))
        #expect(pine.seed != nil && pine.size.map { $0.allSatisfy { (0.73...1.3).contains($0) } } != false && pine.tilt != nil)
        let boulder = try #require(session.fresh("stone.boulder", at: .zero, turn: 0, using: &random))
        #expect(boulder.size.map { $0.allSatisfy { (0.75...1.3).contains($0) } } == true && boulder.seed == nil)
        let fern = try #require(session.fresh("plant.fern", at: .zero, turn: 0, using: &random))
        #expect(fern.size != nil && fern.variant == 0)
        for id in ["wood.stump", "wood.logPile", "work.cushion", "cat.box", "cat.scratchingPost", "cat.yarn", "cat.bed", "cat.bowl", "work.lampPost"] {
            let made = try #require(session.fresh(id, at: .zero, turn: 0.5, using: &random), "\(id)")
            #expect(made.size == nil && made.tilt == nil && made.seed == nil && made.variant == 0 && made.turn == 0.5, "\(id)")
        }
        #expect(session.fresh("water.pond", at: .zero, turn: 0, using: &random) == nil, "a newer Whiskr's thing")
        #expect(session.fresh("garden.fence", at: .zero, turn: 0, using: &random) == nil, "a run, not placed at a spot")
    }

    @Test("placed exactly where it is let go, one step undone and done again; refused where it may not stand, with nothing changed")
    func place() throws {
        var session = MeadowEditSession(MeadowDocument(entries: [item("tree.oak", 50, 10, seed: 7), item("flower.daisy", 30, 0)]))
        var random = Steady(2)
        let before = session.document
        let poppy = try #require(session.fresh("flower.poppy", at: SIMD2(30.5, 0.2), turn: 1, using: &random))
        #expect(session.placingRefusal(poppy, field: session.placingField) == .tooClose(to: "flower.daisy"))
        #expect(session.place(poppy) == .failure(MeadowEditRefused(.tooClose(to: "flower.daisy"))))
        #expect(session.document == before)
        let birch = try #require(session.fresh("tree.birch", at: SIMD2(0, 50), turn: 0, using: &random))
        #expect(session.placingRefusal(birch, field: session.placingField) == .keptForWorkspaces)
        let away = try #require(session.fresh("flower.poppy", at: SIMD2(36, -6), turn: 1, using: &random))
        #expect(session.placingRefusal(away, field: session.placingField) == nil)
        let change = try session.place(away).get()
        #expect(change.added.count == 1 && change.added[0].id == 3 && session.item(3) == away && session.scenery.things.count == 3)
        #expect(session.scenery == MeadowEditSession(session.document).scenery, "what is drawn is what a fresh look at the document draws")
        session.apply(change.inverse)
        #expect(session.document == before)
        session.apply(change)
        #expect(session.item(3) == away)
    }

    @Test("at a cap the meadow says so before anything is placed: 48 trees, and 5,000 things in all")
    func caps() throws {
        var random = Steady(3)
        let trees = (0..<48).map { k in item("tree.young", cos(Double(k) * 0.13) * 140, sin(Double(k) * 0.13) * 140, seed: UInt32(k)) }
        var session = MeadowEditSession(MeadowDocument(entries: trees))
        let oak = try #require(session.fresh("tree.oak", at: SIMD2(-60, -60), turn: 0, using: &random))
        #expect(session.placingRefusal(oak, field: session.placingField) == .full(.trees, limit: 48))
        #expect(session.place(oak) == .failure(MeadowEditRefused(.full(.trees, limit: 48))))
        let daisy = try #require(session.fresh("flower.daisy", at: SIMD2(-60, -60), turn: 0, using: &random))
        #expect(session.placingRefusal(daisy, field: session.placingField) == nil, "a flower is still welcome")

        let many = (0..<MeadowFormat.maxItems).map { k in item("flower.daisy", Double(k % 70) * 2 - 70, Double(k / 70) * 2 - 72) }
        session = MeadowEditSession(MeadowDocument(entries: many))
        let one = try #require(session.fresh("flower.poppy", at: SIMD2(100, 100), turn: 0, using: &random))
        #expect(session.placingRefusal(one, field: session.placingField) == .full(nil, limit: 5_000))
    }
}

@Suite struct Brushing {
    /// Each pair of plants a dab laid keeps its grass between (as anything moved must).
    func apart(_ items: [MeadowFile.MeadowItem], _ session: MeadowEditSession) -> Bool {
        let things = items.compactMap(session.thing)
        var field = SceneryRules.Field(session.scenery)
        for thing in things {
            if field.refusal(for: thing) != nil { return false }
            field.add(thing)
        }
        return true
    }

    @Test("a dab lays a clump of one kind round the spot, thicker toward its middle, each plant its own, none overlapping anything")
    func clump() throws {
        let session = MeadowEditSession(MeadowDocument(entries: [item("stone.stone", 20, 20)]))
        var random = Steady(4)
        var field = session.placingField
        let brush = MeadowBrush(MeadowBrush.wildflowers, radius: 6, density: .natural)
        let (items, full) = session.dab(brush, at: SIMD2(20, 20), field: &field, adding: 0, using: &random)
        #expect(full == nil && items.count >= 5 && items.count <= 18, "\(items.count)")
        #expect(Set(items.map(\.asset)).count == 1, "one kind a clump")
        #expect(items.allSatisfy { hypot($0.at.x - 20, $0.at.z - 20) <= 6 + 1e-6 })
        #expect(apart(items, session))
        #expect(Set(items.map(\.turn)).count == items.count && Set(items.compactMap(\.size)).count == items.count, "no two alike")
        // Many dabs: nearer the middle more often than an even sprinkle would put there (half inside 1/√2 of
        // the radius).
        let empty = MeadowEditSession(MeadowDocument(entries: []))
        var distances: [Double] = []
        for k in 0..<40 {
            let spot = SIMD2(Double(k % 8) * 30 - 100, Double(k / 8) * 30 - 60)
            var fresh = empty.placingField
            distances += empty.dab(MeadowBrush([MeadowBrush.Kind("flower.daisy")], radius: 8, density: .sparse), at: spot, field: &fresh, adding: 0,
                                   using: &random).items.map { hypot($0.at.x - spot.x, $0.at.z - spot.y) }
        }
        let inner = distances.filter { $0 < 8 / 2.squareRoot() }.count
        #expect(Double(inner) / Double(distances.count) > 0.56, "even would be half: \(inner) of \(distances.count)")
    }

    @Test("the brush's kinds, sizes and densities: dense lays more than sparse; the wildflowers are the meadow's own four")
    func settings() {
        #expect(MeadowBrush.wildflowers.map(\.asset) == ["flower.daisy", "flower.buttercup", "flower.lupin", "flower.poppy"])
        #expect(MeadowBrush([], radius: 40).radius == 12 && MeadowBrush([], radius: 0).radius == 2)
        let session = MeadowEditSession(MeadowDocument(entries: []))
        func laid(_ density: MeadowBrush.Density) -> Int {
            var random = Steady(5)
            var total = 0
            for k in 0..<12 {
                var field = session.placingField
                total += session.dab(MeadowBrush([MeadowBrush.Kind("flower.poppy")], radius: 5, density: density), at: SIMD2(Double(k) * 20 - 110, 40),
                                     field: &field, adding: 0, using: &random).items.count
            }
            return total
        }
        #expect(laid(.sparse) < laid(.natural) && laid(.natural) < laid(.dense))
        let catalog = MeadowCatalog.current
        #expect(catalog.assets.filter(MeadowBrush.paints).map(\.id).allSatisfy { $0.hasPrefix("flower.") || $0.hasPrefix("plant.") || $0.hasPrefix("fungus.") })
        #expect(!MeadowBrush.paints(catalog.asset("stone.stone")!) && !MeadowBrush.paints(catalog.asset("tree.young")!))
    }

    @Test("a stroke is one step: its dabs added after the rest, taken back together and done again exactly")
    func stroke() throws {
        let start = MeadowEditSession(MeadowDocument(entries: [item("tree.oak", 60, 0, seed: 3), item("stone.mossy", 10, 10)]))
        var working = start
        var random = Steady(6)
        var field = working.placingField
        var added: [MeadowChange.Placed] = []
        for k in 0..<6 {
            let dab = working.dab(MeadowBrush(MeadowBrush.wildflowers), at: SIMD2(Double(k) * 2.5, 30), field: &field, adding: added.count, using: &random)
            added += working.append(dab.items).added
        }
        let stroke = MeadowChange(added: added)
        #expect(stroke.added.map(\.position) == Array(2..<(2 + added.count)))
        var session = start
        session.apply(stroke)
        #expect(session.document == working.document && session.scenery == working.scenery && session.scenery == MeadowEditSession(session.document).scenery)
        session.apply(stroke.inverse)
        #expect(session.document == start.document && session.scenery == start.scenery)
    }

    @Test("at 5,000 things the brush stops and says why")
    func full() {
        let many = (0..<(MeadowFormat.maxItems - 3)).map { k in item("flower.daisy", Double(k % 70) * 2 - 70, Double(k / 70) * 2 - 72) }
        let session = MeadowEditSession(MeadowDocument(entries: many))
        var random = Steady(7)
        var field = session.placingField
        let dab = session.dab(MeadowBrush([MeadowBrush.Kind("flower.poppy")], radius: 8, density: .dense), at: SIMD2(120, 0), field: &field, adding: 0, using: &random)
        #expect(dab.items.count == 3 && dab.full == .full(nil, limit: 5_000))
    }
}

@Suite struct Erasing {
    @Test("a sweep takes the plants, mushrooms and stones within it (of one kind, if asked), never a tree, a young tree, the log or a made thing")
    func sweep() throws {
        let session = MeadowEditSession(MeadowDocument(entries: [
            item("tree.young", 0, 0, seed: 1), item("flower.daisy", 1, 1), item("flower.poppy", -1, 2), item("stone.stone", 2, -2),
            item("wood.fallenLog", 3, 0), item("fungus.flyAgaric", 9, 9), item("cat.box", 0, 1),
            .parcel(MeadowParcel(fields: ["id": .string("garden.pond"), "at": .array([.number(0), .number(0)])])),
        ]))
        #expect(Set(session.swept(at: .zero, radius: 4, kind: nil)) == [2, 3, 4])
        #expect(session.swept(at: .zero, radius: 4, kind: "flower.poppy") == [3])
        #expect(session.swept(at: .zero, radius: 4, kind: "tree.young").isEmpty, "only a click takes a tree")
        var erased = session
        let change = erased.delete(Set(session.swept(at: .zero, radius: 20, kind: nil)))
        #expect(change.removed.count == 4 && erased.document.entries.count == 4 && erased.document.parcels.count == 1)
        erased.apply(change.inverse)
        #expect(erased.document == session.document)
    }
}
