import Foundation
import MeadowFile
import MeadowScene
import simd
import Testing
@testable import WhiskrMeadow

// Fence runs and colours in the meadow's editor: a run laid along a drag, its ends joining others', straightened,
// gated and ungated, moved and turned whole, each one step that undoes exactly; colours chosen from a palette and
// kept in `params`; and the released `v1-catalog1-garden` fixture, which the editor's own steps make byte for byte.

private func empty() -> MeadowEditSession { MeadowEditSession(MeadowDocument(name: "Garden")) }

private func lay(_ session: inout MeadowEditSession, _ points: [SIMD2<Double>]) throws -> MeadowChange {
    let laying = try #require(session.fenceLaying(points))
    return try session.layFence(laying).get()
}

private func run(_ session: MeadowEditSession, _ id: Int) -> [SIMD2<Double>] {
    session.fenceRun(id)?.points.map { SIMD2($0.x, $0.z) } ?? []
}

@Suite struct FenceDrafts {
    @Test("a drag lays a point each post's spacing along it, and its end; ⌥ lays one straight length")
    func drafts() {
        var draft = MeadowFenceDraft(at: SIMD2(30, 0))
        for x in stride(from: 30.0, through: 40.2, by: 0.3) { draft.extend(to: SIMD2(x, 0)) }
        #expect(draft.points.count == 5 && abs(draft.points[4].x - 40) < 1e-9)
        #expect(draft.points(endingAt: SIMD2(40.2, 0)).count == 5, "too short a last span is not laid")
        #expect(draft.points(endingAt: SIMD2(41.2, 0)).count == 6)
        var straight = MeadowFenceDraft(at: SIMD2(30, 0), straight: true)
        straight.extend(to: SIMD2(45, 4))
        #expect(straight.points(endingAt: SIMD2(45, 4)) == [SIMD2(30, 0), SIMD2(45, 4)])
    }

    @Test("a click's short run is two spans along its turn, round the spot")
    func short() {
        let points = MeadowEditSession.shortFence(at: SIMD2(40, 10), turn: 0)
        #expect(points == [SIMD2(37.5, 10), SIMD2(40, 10), SIMD2(42.5, 10)])
    }
}

@Suite struct FenceEditing {
    @Test("a run laid is one thing in the meadow, its points as drawn, one step that undoes")
    func lays() throws {
        var session = empty()
        let change = try lay(&session, [SIMD2(30, 0), SIMD2(32.5, 0), SIMD2(35, 0)])
        #expect(session.document.items.count == 1 && session.scenery.things.count == 1 && session.scenery.things[0].points.count == 3)
        #expect(MeadowCatalog.posts(along: session.document.items[0].placement.points) == MeadowScenery.fencePosts(along: session.scenery.things[0].points).count)
        session.apply(change.inverse)
        #expect(session.document.items.isEmpty)
    }

    @Test("a run's end within 0.8 of another's end joins it: one run, its corner one post, the other's gate kept in place")
    func joins() throws {
        var session = empty()
        _ = try lay(&session, [SIMD2(30, 0), SIMD2(32.5, 0), SIMD2(35, 0)])
        let first = try #require(session.drawnIDs.first)
        _ = try session.toggleGate(first).get()
        #expect(session.fenceRun(first)?.gate == 1 || session.fenceRun(first)?.gate == 2)
        // Begun 0.5 from the first run's start, going the other way.
        let change = try lay(&session, [SIMD2(29.6, 0.3), SIMD2(29.6, 2.8), SIMD2(29.6, 5.3)])
        #expect(change.removed.map(\.id) == [first] && session.document.items.count == 1)
        let joined = try #require(session.drawnIDs.first)
        let points = run(session, joined)
        #expect(points.count == 5 && points.contains(SIMD2(30, 0)) && !points.contains(SIMD2(29.6, 0.3)), "\(points)")
        // The gate is where it was along the old run.
        let gate = try #require(session.fenceRun(joined)?.gate)
        let a = session.fenceRun(joined)!.points[gate - 1], b = session.fenceRun(joined)!.points[gate]
        #expect(a.z == 0 && b.z == 0 && min(a.x, b.x) >= 30 && max(a.x, b.x) <= 35, "\(a) \(b)")
        // Undone: the two runs as they were.
        session.apply(change.inverse)
        #expect(session.document.items.count == 1 && run(session, first).count >= 3 && session.fenceRun(first)!.gate > 0)
    }

    @Test("a run ending where it began closes on itself")
    func closes() throws {
        var session = empty()
        _ = try lay(&session, [SIMD2(30, 0), SIMD2(35, 0), SIMD2(35, 5), SIMD2(30, 5), SIMD2(30.4, 0.3)])
        let points = run(session, session.drawnIDs[0])
        #expect(points.first == points.last && points.count == 5)
        #expect(!session.canStraighten(session.drawnIDs[0]), "a closed run has no straight form")
    }

    @Test("a run is refused off the picnic ground, outside the meadow, across a tree, past the fence posts' cap")
    func refused() throws {
        let session = empty()
        #expect(session.fenceRefusal(try #require(session.fenceLaying([SIMD2(10, 10), SIMD2(30, 10)]))) == .keptForWorkspaces)
        #expect(session.fenceRefusal(try #require(session.fenceLaying([SIMD2(150, 0), SIMD2(165, 0)]))) == .outsideMeadow)
        let trees = MeadowEditSession(MeadowDocument(name: "Trees", entries: [.item(MeadowFile.MeadowItem(asset: "tree.oak", placement: .at(MeadowPoint(40, 0)), seed: 1))]))
        #expect(trees.fenceRefusal(try #require(trees.fenceLaying([SIMD2(35, 0), SIMD2(45, 0)]))) == .tooClose(to: "tree.oak"))
        // Rows of fence until the meadow holds as many posts as it can.
        var full = empty()
        var refusal: MeadowEditRefusal?
        for k in 0..<30 where refusal == nil {
            let z = -140.0 + Double(k) * 5
            let points: [SIMD2<Double>] = (0..<41).map { SIMD2(25 + Double($0) * 2.5, z) }.filter { hypot($0.x, $0.y) < 158 }
            let laying = try #require(full.fenceLaying(points))
            refusal = full.fenceRefusal(laying)
            if refusal == nil { _ = try full.layFence(laying).get() }
        }
        #expect(refusal == .full(.fencePosts, limit: 600))
        #expect(full.document.counts(full.catalog)[.fencePosts, default: 0] <= 600)
    }

    @Test("Straighten makes it one length from end to end, its gate kept as near where it was; Add Gate and its undoing")
    func straightenAndGate() throws {
        var session = empty()
        _ = try lay(&session, [SIMD2(30, 0), SIMD2(32, 1.5), SIMD2(34, 0), SIMD2(36, -1.5), SIMD2(38, 0)])
        let id = session.drawnIDs[0]
        #expect(session.canStraighten(id) && session.canToggleGate(id))
        let gated = try session.toggleGate(id).get()
        let gate = try #require(session.fenceRun(id)?.gate)
        #expect(gate > 0 && session.scenery.things[0].gate == gate)
        let straightened = try session.straighten(id).get()
        let points = run(session, id)
        #expect(points.allSatisfy { abs($0.y) < 1e-9 } && points.first == SIMD2(30, 0) && points.last == SIMD2(38, 0))
        let after = try #require(session.fenceRun(id))
        #expect(after.gate > 0 && abs(MeadowEditSession.gateMiddle(after.points, gate: after.gate) - 4) < 2.6)
        // The posts stand where a straight run's do.
        #expect(MeadowScenery.fencePosts(along: session.scenery.things[0].points).count == 5)
        let ungated = try session.toggleGate(id).get()
        #expect(session.fenceRun(id)?.gate == 0 && session.document.items[0].params["gate"] == nil)
        for change in [ungated, straightened, gated] { session.apply(change.inverse) }
        #expect(run(session, id) == [SIMD2(30, 0), SIMD2(32, 1.5), SIMD2(34, 0), SIMD2(36, -1.5), SIMD2(38, 0)] && session.fenceRun(id)?.gate == 0)
    }

    @Test("a run moves, turns about its middle, copies and pastes whole")
    func whole() throws {
        var session = empty()
        _ = try lay(&session, [SIMD2(30, 0), SIMD2(35, 0)])
        let id = session.drawnIDs[0]
        _ = try session.move([id], by: SIMD2(2, 3)).get()
        #expect(run(session, id) == [SIMD2(32, 3), SIMD2(37, 3)])
        _ = try session.turn([id], by: .pi / 2).get()
        let turned = run(session, id)
        #expect(abs(turned[0].x - 34.5) < 1e-3 && abs(turned[0].y - 5.5) < 1e-3 && abs(turned[1].y - 0.5) < 1e-3, "\(turned)")
        #expect(session.document.items[0].turn == 0)
        let copy = try session.duplicate([id], toward: SIMD2(1, 0)).get()
        #expect(copy.added.count == 1 && session.fenceRun(copy.added[0].id)?.points.count == 2)
        let data = try #require(session.copied([id], writtenBy: "0.1.0"))
        let pasted = try #require(MeadowEditSession.pasted(data))
        #expect(pasted.count == 1 && pasted[0].placement.points.count == 2)
    }
}

@Suite struct Colours {
    @Test("a colour is kept in params, its own written as none, undoable, and drawn as its swatch")
    func recolour() throws {
        var session = empty()
        let bench = try session.place(MeadowFile.MeadowItem(asset: "work.bench", placement: .at(MeadowPoint(40, 0)))).get().added[0].id
        let daisy = try session.place(MeadowFile.MeadowItem(asset: "flower.daisy", placement: .at(MeadowPoint(50, 0)))).get().added[0].id
        #expect(session.colour(of: bench) == "wood" && session.colour(of: daisy) == nil && session.palette(of: "work.bench") == ["wood", "sage", "cream", "slate"])
        let change = try session.recolour([bench, daisy], to: "sage").get()
        #expect(change.edited.map(\.id) == [bench] && session.document.items[0].params["colour"] == .string("sage"))
        #expect(session.scenery.things[0].swatch == 1)
        _ = try session.recolour([bench], to: "wood").get()
        #expect(session.document.items[0].params["colour"] == nil && session.scenery.things[0].swatch == 0)
        _ = try session.recolour([bench], to: "plum").get()
        #expect(session.scenery.things[0].swatch == 0, "no such swatch: unchanged")
        session.apply(change.inverse)
        #expect(session.colour(of: bench) == "wood")
    }

    @Test("every catalog palette is the scene's, name for name, and every colour choice draws its own swatch")
    func palettesMatch() {
        for asset in MeadowCatalog.current.assets {
            guard case .choice(let choices) = asset.parameter("colour")?.kind else {
                #expect(MeadowScenery.palette(of: asset.id).isEmpty, "\(asset.id)")
                continue
            }
            #expect(MeadowScenery.palette(of: asset.id).map(\.name) == choices.map(\.name), "\(asset.id)")
        }
    }
}

@Suite struct TheGardenFixture {
    func fixture(_ name: String) throws -> Data {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MeadowFileTests/Fixtures/MeadowFiles", isDirectory: true)
        return try Data(contentsOf: folder.appendingPathComponent(name))
    }

    /// The garden as the editor makes it: one of each Stage 8 thing, those with a palette in a colour not their own,
    /// a fence round them with a gate, joined at a corner from two runs, and a straight run beside.
    static func made() throws -> MeadowDocument {
        var session = empty()
        let things: [(String, Double, Double, String?)] = [
            ("garden.flowerPot", 40, 4, "glazeCeladon"), ("garden.planter", 46, 4, nil), ("garden.wateringCan", 52, 4, "duckEgg"), ("garden.birdhouse", 58, 4, nil),
            ("garden.skep", 64, 4, nil), ("work.desk", 40, 12, nil), ("work.cushion", 40, 15.5, "mustard"), ("work.bookshelf", 47, 12, nil), ("work.bench", 54, 12, "sage"),
            ("work.signpost", 61, 12, nil), ("work.mailbox", 66, 12, "cream"), ("work.noticeboard", 40, 22, nil), ("place.shed", 50, 24, "lavender"),
            ("place.tent", 62, 24, "olive"), ("cat.yarn", 46, 17, "rose"), ("cat.bed", 52, 18, "sage"), ("cat.bowl", 56, 17, "terracotta"),
        ]
        for (asset, x, z, colour) in things {
            let id = try session.place(MeadowFile.MeadowItem(asset: asset, placement: .at(MeadowPoint(x, z)), turn: 0.7854)).get().added[0].id
            if let colour { _ = try session.recolour([id], to: colour).get() }
        }
        _ = try lay(&session, (0...12).map { SIMD2(35 + Double($0) * 2.5, -1) })
        _ = try lay(&session, (0...12).map { SIMD2(35.3, -0.6 + Double($0) * 2.5) })
        _ = try session.toggleGate(session.drawnIDs.last!).get()
        _ = try lay(&session, [SIMD2(75, -1), SIMD2(75, 30)])
        session.rename("Garden Office")
        return session.document
    }

    @Test("a garden laid out by the editor (every Stage 8 thing, palettes, fences joined and gated) reads, draws and writes back byte for byte")
    func garden() throws {
        let data = try fixture("v1-catalog1-garden.whiskrmeadow")
        let reading = try MeadowDocument.read(data)
        #expect(reading.leftOutside == 0 && !reading.keepsNewerContent)
        #expect(try Self.made().items == reading.document.items && reading.document.name == "Garden Office")
        #expect(try reading.document.fileData(writtenBy: "0.1.0") == data)
        let scenery = MeadowScenery(reading.document)
        #expect(scenery.things.count == reading.document.items.count)
        let fences = scenery.things.filter(\.isRun)
        #expect(fences.count == 2 && fences.contains { $0.gate > 0 && $0.points.count > 20 })
        #expect(scenery.things.filter { $0.swatch > 0 }.count == 10)
        // Back to a document: the same things, colours and runs.
        #expect(MeadowDocument(scenery, name: "Garden Office").items.map(\.params) == reading.document.items.map(\.params))
    }
}

private extension MeadowFile.MeadowItem.Placement {
    var points: [MeadowPoint] {
        switch self {
        case .at(let p): [p]
        case .run(let points): points
        }
    }
}
