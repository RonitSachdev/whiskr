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
}
