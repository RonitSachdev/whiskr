import Foundation
import Testing
@testable import MeadowFile

@Suite("Meadow files: ground")
struct GroundGridTests {
    @Test("cells survive runs both ways, neighbouring runs joined")
    func runs() throws {
        var ground = GroundGrid()
        #expect(ground.runs == [0, GroundGrid.cellCount])
        let listed = ground.index(of: "ground.path")
        let path = try #require(listed)
        ground[0, 0] = path
        ground[511, 511] = path
        ground[5, 3] = path
        ground[6, 3] = path
        #expect(ground.runs == [1, 1, 0, 3 * 512 + 4, 1, 2, 0, GroundGrid.cellCount - 3 * 512 - 8, 1, 1])
        #expect(try GroundGrid.cells(runs: ground.runs, paintCount: 1) == ground.cells)
        // Runs need not be joined to be read.
        #expect(try GroundGrid.cells(runs: [0, 100, 0, GroundGrid.cellCount - 100], paintCount: 0) == GroundGrid().cells)
    }

    @Test("runs that are not exactly the grid are refused")
    func badRuns() {
        func problem(_ runs: [Int], paints: Int = 1) -> GroundGrid.RunsProblem? {
            do {
                _ = try GroundGrid.cells(runs: runs, paintCount: paints)
                return nil
            } catch {
                return error
            }
        }
        #expect(problem([0]) == .unpaired)
        #expect(problem([0, GroundGrid.cellCount - 1]) == .total(GroundGrid.cellCount - 1))
        #expect(problem([0, GroundGrid.cellCount, 1, 1]) == .total(GroundGrid.cellCount + 1))
        #expect(problem([2, GroundGrid.cellCount]) == .value(pair: 0))
        #expect(problem([-1, GroundGrid.cellCount]) == .value(pair: 0))
        #expect(problem([0, 0, 0, GroundGrid.cellCount]) == .count(pair: 0))
        #expect(problem([0, -5, 0, GroundGrid.cellCount + 5]) == .count(pair: 0))
        #expect(problem([]) == .total(0))
    }

    @Test("points map to cells over the editable disc's square, row by row along z")
    func cells() {
        #expect(GroundGrid.cell(at: MeadowPoint(-150, -150))! == (0, 0))
        #expect(GroundGrid.cell(at: MeadowPoint(149.99, 149.99))! == (511, 511))
        #expect(GroundGrid.cell(at: MeadowPoint(0, 0))! == (256, 256))
        #expect(GroundGrid.cell(at: MeadowPoint(-0.01, 0))! == (255, 256))
        #expect(GroundGrid.cell(at: MeadowPoint(150, 0)) == nil)
        #expect(GroundGrid.cell(at: MeadowPoint(0, -150.01)) == nil)
    }

    @Test("a paint is listed once, at most 16; one this Whiskr does not know is drawn as long grass")
    func paints() {
        var ground = GroundGrid()
        #expect(ground.index(of: "ground.lawn") == 1 && ground.index(of: "ground.soil") == 2 && ground.index(of: "ground.lawn") == 1)
        for i in 3...16 { #expect(ground.index(of: "ground.p\(i)") == UInt8(i)) }
        #expect(ground.index(of: "ground.more") == nil)
        #expect(ground.drawnPaint(1, .current) == "ground.lawn" && ground.drawnPaint(3, .current) == nil && ground.drawnPaint(0, .current) == nil)
        #expect(ground.hasNewerContent(.current))
    }

    @Test("runs are counted without being made, and a stretch of cells counts its own changes")
    func counting() {
        var ground = GroundGrid()
        #expect(ground.isWild && ground.runCount == 1 && ground.changes(in: 0..<GroundGrid.cellCount) == 0)
        let path = ground.index(of: "ground.path")!
        for column in 10..<20 { ground[column, 3] = path }
        ground[0, 0] = path
        #expect(!ground.isWild && ground.runCount == ground.runs.count / 2)
        #expect(ground.changes(in: (3 * 512)..<(4 * 512)) == 2 && ground.changes(in: 0..<1) == 0 && ground.changes(in: 0..<2) == 1)
    }

    @Test("paints no cell holds are let go from the end of the list; the first ones stay")
    func keepingPaints() {
        var ground = GroundGrid()
        let lawn = ground.index(of: "ground.lawn")!
        _ = ground.index(of: "ground.soil")
        ground[5, 5] = lawn
        ground.keepPaints(1)
        #expect(ground.paints == ["ground.lawn"] && ground[5, 5] == lawn)
        ground.keepPaints(4)
        #expect(ground.paints == ["ground.lawn"])
    }

    @Test("a meadow's room for its ground: the most runs that keep its file within the values and bytes any Whiskr reads")
    func room() throws {
        let empty = MeadowDocument()
        let room = empty.groundRoom()
        #expect(room > 90_000 && room <= MeadowFormat.limits.values / 2)
        // Filled to its room with runs of one cell, the file is still read; one run more and it would not be.
        var ground = GroundGrid()
        for paint in ["ground.path", "ground.lawn", "ground.soil"] { _ = ground.index(of: paint) }
        // Each cell painted apart from the rest adds two runs.
        for k in 0..<((room - 1) / 2) {
            let cell = 2 * k + 1
            ground[cell % 512, cell / 512] = UInt8(1 + k % 3)
        }
        #expect(ground.runCount >= room - 1 && ground.runCount <= room)
        var document = empty
        document.ground = ground
        let data = try document.fileData(writtenBy: String(repeating: "9", count: 32))
        #expect(data.count <= MeadowFormat.maxBytes)
        // Things in the meadow leave less room.
        let things = MeadowDocument(entries: (0..<2_000).map { .item(MeadowItem(asset: "flower.daisy", placement: .at(MeadowPoint(Double($0 % 50), Double($0 / 50))), size: [1.1, 1, 0.9])) })
        #expect(things.groundRoom() < room - 8_000)
    }
}
