import Foundation
import MeadowFile
import MeadowScene
import Testing
import simd
@testable import WhiskrMeadow

// The Ground tool's strokes: cells painted under the circle, the scene's ground kept with the file's, one step a
// stroke undone and done again exactly, the wild grass painting a meadow back to no ground at all, and a stroke
// stopped before the file could hold no more. And the stepping stones laid a stride apart along a drag.

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

/// A stroke of `paint` through `spots`, as the editor makes it on a working copy, and its change.
private func stroke(_ session: MeadowEditSession, _ paint: String, _ spots: [SIMD2<Double>], radius: Double = 3) -> (change: MeadowChange, refused: MeadowEditRefusal?) {
    var working = session
    var stroke = working.beginGroundStroke()
    var refused: MeadowEditRefusal?
    for spot in spots { refused = working.paintGround(paint, at: spot, radius: radius, stroke: &stroke) ?? refused }
    return (working.change(of: stroke), refused)
}

@Suite struct PaintingTheGround {
    @Test("a dab paints the cells whose middles lie in its circle, listing the paint; the scene draws the same")
    func dab() throws {
        var session = MeadowEditSession(MeadowDocument(entries: []))
        let made = stroke(session, "ground.path", [SIMD2(10, -20)], radius: 2)
        #expect(made.refused == nil)
        session.apply(made.change)
        let ground = try #require(session.document.ground)
        #expect(ground.paints == ["ground.path"])
        let size = 300.0 / 512
        var painted = 0
        for row in 0..<GroundGrid.side {
            for column in 0..<GroundGrid.side {
                let x = -150 + (Double(column) + 0.5) * size, z = -150 + (Double(row) + 0.5) * size
                let inside = hypot(x - 10, z + 20) <= 2
                #expect((ground[column, row] == 1) == inside)
                if inside { painted += 1 }
                #expect(session.scenery.ground?[column, row] == (inside ? .path : .wild))
            }
        }
        #expect(painted > 30 && painted < 45, "about π·2² / 0.34 cells: \(painted)")
        #expect(session.scenery.ground == MeadowScenery.Ground(session.document.ground), "the scene's ground is the file's as drawn")
    }

    @Test("one stroke is one change: undone the ground is as it was, done again exactly as painted, and it is small")
    func undo() throws {
        var session = MeadowEditSession(MeadowDocument(entries: []))
        session.apply(stroke(session, "ground.lawn", [SIMD2(0, 30)], radius: 6).change)
        let lawn = session.document
        let spots = (0..<40).map { SIMD2(Double($0) * 0.5 - 10, 30) }
        let path = stroke(session, "ground.path", spots, radius: 1.5).change
        let patch = try #require(path.ground)
        #expect(patch.paintsBefore == ["ground.lawn"] && patch.paintsAfter == ["ground.lawn", "ground.path"])
        #expect(patch.before.count == patch.columns.count * patch.rows.count && patch.before.count < 3_000, "a rectangle round the stroke, not the grid")
        session.apply(path)
        let painted = session.document, drawn = session.scenery
        session.apply(path.inverse)
        #expect(session.document == lawn && session.scenery.ground == MeadowScenery.Ground(lawn.ground))
        session.apply(path)
        #expect(session.document == painted && session.scenery == drawn)
    }

    @Test("the wild grass paints a meadow back: all of it wild, it has no ground and its file no ground section; undone it is back")
    func wild() throws {
        var session = MeadowEditSession(MeadowDocument(entries: []))
        #expect(stroke(session, "ground.wild", [SIMD2(0, 0)]).change.isEmpty, "nothing to paint back")
        let soil = stroke(session, "ground.soil", [SIMD2(5, 5), SIMD2(6, 5)]).change
        session.apply(soil)
        let painted = session.document
        let back = stroke(session, "ground.wild", [SIMD2(5, 5), SIMD2(6, 5)], radius: 5).change
        #expect(back.ground?.groundAfter == false)
        session.apply(back)
        #expect(session.document.ground == nil && session.scenery.ground == nil)
        #expect(!String(decoding: try session.document.fileData(writtenBy: "1.0.0"), as: UTF8.self).contains("\"ground\""))
        session.apply(back.inverse)
        #expect(session.document == painted)
        session.apply(soil.inverse)
        #expect(session.document.ground == nil)
    }

    @Test("what a newer Whiskr painted is kept: its paints stay listed, its cells painted over only where painted")
    func newer() throws {
        var grid = GroundGrid()
        let moss = grid.index(of: "ground.moss")!
        grid[100, 100] = moss
        var session = MeadowEditSession(MeadowDocument(entries: [], ground: grid))
        #expect(session.scenery.ground?[100, 100] == .wild, "drawn as the wild grass")
        session.apply(stroke(session, "ground.wild", [SIMD2(100, 100)], radius: 2).change)
        #expect(session.document.ground?[100, 100] == moss && session.document.ground?.paints == ["ground.moss"])
        session.apply(stroke(session, "ground.path", [SIMD2(-150 + 100.5 * 300 / 512, -150 + 100.5 * 300 / 512)], radius: 1).change)
        #expect(session.document.ground?.paints == ["ground.moss", "ground.path"] && session.document.ground?[100, 100] == 2)
    }

    @Test("a painted meadow round-trips its file byte for byte")
    func roundTrip() throws {
        var session = MeadowEditSession(MeadowDocument(name: "Painted", entries: []))
        for (paint, at) in [("ground.path", SIMD2(-20.0, 4.0)), ("ground.lawn", SIMD2(30, -10)), ("ground.soil", SIMD2(-25, -12))] {
            session.apply(stroke(session, paint, (0..<20).map { at + SIMD2(Double($0) * 0.7, sin(Double($0)) * 2) }).change)
        }
        let data = try session.document.fileData(writtenBy: "1.0.0")
        var read = try MeadowDocument.read(data).document
        read.readFrom = nil
        #expect(read == session.document)
        #expect(try read.fileData(writtenBy: "1.0.0") == data)
        #expect(MeadowEditSession(read).scenery == session.scenery)
    }

    @Test("runs are counted as a file writes them, a stroke's rows at a time")
    func runs() throws {
        var session = MeadowEditSession(MeadowDocument(entries: []))
        var working = session
        var stroke = working.beginGroundStroke()
        for k in 0..<30 { _ = working.paintGround(k % 2 == 0 ? "ground.path" : "ground.soil", at: SIMD2(Double(k) * 1.3 - 20, Double(k % 5) * 2), radius: 1.5, stroke: &stroke) }
        #expect(stroke.runs == working.document.ground?.runCount && working.document.ground?.runCount == (working.document.ground?.runs.count ?? 0) / 2)
        session.apply(working.change(of: stroke))
        #expect(session.document == working.document)
    }

    @Test("a stroke stops where the file could hold no more of the ground, says why, and what it painted stays within the limits")
    func full() throws {
        // A meadow whose room is a few hundred runs: its things already near the file's limit of values.
        var entries: [MeadowEntry] = []
        let unknown = MeadowJSON.array((0..<500).map { MeadowJSON.number(Double($0)) })
        while entries.count < 390 {
            entries.append(.parcel(MeadowParcel(fields: ["id": .string("water.pond"), "at": .array([.number(1), .number(2)]), "lilies": unknown])))
        }
        let document = MeadowDocument(entries: entries)
        let room = document.groundRoom()
        #expect(room > 0 && room < 2_000, "\(room)")
        var session = MeadowEditSession(document)
        // Dots a cell wide, each two runs: soon past the room.
        let spots = (0..<2_000).map { SIMD2(Double($0 % 60) * 2.4 - 70, Double($0 / 60) * 2.4 - 40) }
        let made = stroke(session, "ground.path", spots, radius: 0.45)
        #expect(made.refused == .groundFull)
        session.apply(made.change)
        #expect(session.document.ground!.runCount <= room)
        let data = try session.document.fileData(writtenBy: String(repeating: "9", count: 32))
        #expect(data.count <= MeadowFormat.maxBytes)
        // An empty meadow has room for a ground of the most detail at all.
        #expect(MeadowDocument(entries: []).groundRoom() > 90_000)
    }
}

@Suite struct TheGroundFixture {
    /// A released meadow file (`MeadowFileTests/Fixtures/MeadowFiles`), read from the source tree.
    func fixture(_ name: String) throws -> Data {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MeadowFileTests/Fixtures/MeadowFiles", isDirectory: true)
        return try Data(contentsOf: folder.appendingPathComponent(name))
    }

    @Test("a meadow painted and laid by the editor (path, lawn, soil, stepping stones) reads, draws, and writes back byte for byte")
    func painted() throws {
        let data = try fixture("v1-catalog1-ground.whiskrmeadow")
        let reading = try MeadowDocument.read(data)
        #expect(reading.leftOutside == 0 && !reading.keepsNewerContent)
        var document = reading.document
        document.readFrom = nil
        #expect(try document.fileData(writtenBy: "0.1.0") == data)
        let scenery = MeadowScenery(document)
        let ground = try #require(scenery.ground)
        #expect(Set(ground.cells) == Set(MeadowScenery.Ground.Paint.allCases.map(\.rawValue)), "every paint drawn, and the wild grass")
        #expect(scenery.things.count == 12 && scenery.things.allSatisfy { $0.id == "stone.stepping" })
        #expect(MeadowEditSession(document).scenery == scenery)
    }
}

@Suite struct LayingSteppingStones {
    @Test("a stepping stone is laid across the way, a hair off the line, wider than deep, its own size and turn")
    func stone() throws {
        let session = MeadowEditSession(MeadowDocument(entries: []))
        var random = Steady(5)
        let stones = (0..<30).compactMap { _ in session.steppingStone(at: SIMD2(10, 10), heading: SIMD2(1, 0), using: &random) }
        #expect(stones.count == 30 && Set(stones.compactMap(\.size)).count == 30 && Set(stones.map(\.turn)).count == 30)
        for stone in stones {
            let size = try #require(stone.size)
            #expect(size[0] > size[2] && (0.8...1.2).contains(size[0]) && (0.8...1.2).contains(size[2]))
            #expect(abs(stone.at.x - 10) <= 0.03 + 1e-9 && abs(stone.at.z - 10) <= 0.1 + 1e-9)
            // Its long side (its own x, along (cos t, −sin t)) square to the way (+x), give or take 0.3 rad.
            let side = SIMD2(cos(stone.turn), -sin(stone.turn))
            #expect(abs(side.x) <= sin(0.3) + 1e-3)
        }
    }

    @Test("stones a stride apart along a drag may each stand where they are, next to the last, with grass between")
    func row() throws {
        var session = MeadowEditSession(MeadowDocument(entries: []))
        var random = Steady(9)
        var field = session.placingField
        var laid: [MeadowFile.MeadowItem] = []
        for k in 0..<20 {
            let spot = SIMD2(Double(k) * MeadowEditSession.steppingStride - 10, 40.0)
            let stone = try #require(session.steppingStone(at: spot, heading: SIMD2(1, 0), using: &random))
            let thing = try #require(session.thing(stone))
            #expect(field.refusal(for: thing) == nil, "stone \(k)")
            field.add(thing)
            laid.append(stone)
        }
        let change = session.append(laid)
        #expect(change.added.count == 20 && session.scenery.things.filter { $0.id == "stone.stepping" }.count == 20)
        #expect(MeadowScenery.draws("stone.stepping"))
    }
}
