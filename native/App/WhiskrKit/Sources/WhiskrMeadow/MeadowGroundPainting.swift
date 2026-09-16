import Foundation
import MeadowFile
import MeadowScene
import simd

// Painting the ground (docs/DESIGN.md, "Edit Meadow"): the Ground tool's strokes of path, lawn and soil over
// the meadow's own long grass, and of the wild grass back over them. A stroke paints the cells of a meadow
// file's ground grid whose middles its circle passes over; the scene softens their edges where it draws
// them. Each stroke is one step, kept as the rectangle of cells it touched, before and after, so a history
// of hundreds of strokes stays small. A stroke stops where the file could hold no more of the ground's
// detail (`MeadowDocument.groundRoom`), so a meadow is never painted into one that cannot be saved.

/// The cells of the painted ground a change touched: a rectangle of the grid, as it was and as it is, with the
/// paints the grid listed and whether there was a ground at all, before and after.
public struct MeadowGroundPatch: Equatable, Sendable {
    public var columns: ClosedRange<Int>
    public var rows: ClosedRange<Int>
    /// The rectangle's cells, row by row, before and after.
    public var before: [UInt8]
    public var after: [UInt8]
    /// The paints listed before and after (after starts with those before: a stroke only lists more).
    public var paintsBefore: [String]
    public var paintsAfter: [String]
    /// Whether the meadow had a painted ground before and has one after (painted back to wild grass, it has
    /// none, and its file no ground section).
    public var groundBefore: Bool
    public var groundAfter: Bool

    /// What undoes it.
    public var inverse: MeadowGroundPatch {
        MeadowGroundPatch(columns: columns, rows: rows, before: after, after: before, paintsBefore: paintsAfter, paintsAfter: paintsBefore,
                          groundBefore: groundAfter, groundAfter: groundBefore)
    }
}

/// A stroke of the Ground tool under way, on a working copy of the session (`MeadowEditSession.paintGround`).
public struct MeadowGroundStroke: Sendable {
    /// The ground as the stroke found it.
    let before: GroundGrid?
    /// The cells it has painted, all together (nil: none yet).
    var columns: ClosedRange<Int>?
    var rows: ClosedRange<Int>?
    /// The runs the ground holds now (`GroundGrid.runCount`), and the most it may.
    var runs: Int
    let room: Int
}

extension MeadowEditSession {
    /// The ground tool's brush: how wide it can be, and how wide it starts, in units (its radius).
    public static let groundRadii: ClosedRange<Double> = 1...10
    public static let usualGroundRadius = 2.0

    /// A stroke of the Ground tool beginning on the meadow as it is now.
    public func beginGroundStroke() -> MeadowGroundStroke {
        MeadowGroundStroke(before: document.ground, runs: document.ground?.runCount ?? 1, room: document.groundRoom(catalog: catalog))
    }

    /// One dab of a stroke: every cell whose middle lies within `radius` of `spot` painted `paint` (a
    /// `.paint` asset's id, or the eraser's, `ground.wild`, which paints the long grass back). Refused, with
    /// nothing painted, when the ground would hold more detail than a file can (`groundFull`).
    public mutating func paintGround(_ paint: String, at spot: SIMD2<Double>, radius: Double, stroke: inout MeadowGroundStroke) -> MeadowEditRefusal? {
        guard let asset = catalog.asset(paint), asset.nature == .paint || asset.nature == .eraser else { return nil }
        let erasing = asset.nature == .eraser
        // Wild grass over a meadow with nothing painted changes nothing.
        if erasing, document.ground == nil { return nil }
        let size = 2 * GroundGrid.reach / Double(GroundGrid.side)
        func cell(_ v: Double) -> Int { Int(((v + GroundGrid.reach) / size).rounded(.down)) }
        let columns = max(cell(spot.x - radius), 0)...min(cell(spot.x + radius), GroundGrid.side - 1)
        let rows = max(cell(spot.y - radius), 0)...min(cell(spot.y + radius), GroundGrid.side - 1)
        guard columns.lowerBound <= columns.upperBound, rows.lowerBound <= rows.upperBound else { return nil }

        if document.ground == nil { document.ground = GroundGrid() }
        let listed = document.ground!.paints.count
        guard let value = erasing ? 0 : document.ground!.index(of: asset.id) else { return .groundFull }
        // The changes between neighbouring cells over the rows painted (and into the next row), before and after:
        // the runs a file writes go up or down by as many.
        let span = (rows.lowerBound * GroundGrid.side)..<((rows.upperBound + 1) * GroundGrid.side + 1)
        let changesBefore = document.ground!.changes(in: span)
        var painted: [(column: Int, row: Int, was: UInt8)] = []
        for row in rows {
            let z = -GroundGrid.reach + (Double(row) + 0.5) * size
            for column in columns {
                let x = -GroundGrid.reach + (Double(column) + 0.5) * size
                guard hypot(x - spot.x, z - spot.y) <= radius else { continue }
                let was = document.ground![column, row]
                guard was != value else { continue }
                painted.append((column, row, was))
                document.ground![column, row] = value
            }
        }
        let runs = stroke.runs + document.ground!.changes(in: span) - changesBefore
        if runs > stroke.room {
            for cell in painted { document.ground![cell.column, cell.row] = cell.was }
            document.ground!.keepPaints(listed)
            if stroke.before == nil, document.ground!.isWild { document.ground = nil }
            return .groundFull
        }
        stroke.runs = runs
        guard !painted.isEmpty else { return nil }
        let drawn = MeadowScenery.Ground.drawn(document.ground!, catalog)
        if scenery.ground == nil { scenery.ground = MeadowScenery.Ground() }
        for cell in painted { scenery.ground![cell.column, cell.row] = MeadowScenery.Ground.Paint(rawValue: drawn[Int(value)]) ?? .wild }
        let touched = (columns: painted.map(\.column), rows: painted.map(\.row))
        let paintedColumns = touched.columns.min()!...touched.columns.max()!, paintedRows = touched.rows.min()!...touched.rows.max()!
        stroke.columns = stroke.columns.map { min($0.lowerBound, paintedColumns.lowerBound)...max($0.upperBound, paintedColumns.upperBound) } ?? paintedColumns
        stroke.rows = stroke.rows.map { min($0.lowerBound, paintedRows.lowerBound)...max($0.upperBound, paintedRows.upperBound) } ?? paintedRows
        return nil
    }

    /// What a stroke painted, as one change: the rectangle of cells it touched before and after. Empty when it
    /// painted nothing. Painted back to wild grass everywhere (and holding nothing from a newer Whiskr), the
    /// meadow has no ground any more.
    public func change(of stroke: MeadowGroundStroke) -> MeadowChange {
        guard let columns = stroke.columns, let rows = stroke.rows else { return MeadowChange() }
        func cells(_ grid: GroundGrid?) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(columns.count * rows.count)
            for row in rows {
                for column in columns { out.append(grid?[column, row] ?? 0) }
            }
            return out
        }
        let after = document.ground
        let kept = after.map { !$0.isWild || $0.hasNewerContent(catalog) } ?? false
        let patch = MeadowGroundPatch(columns: columns, rows: rows, before: cells(stroke.before), after: cells(after),
                                      paintsBefore: stroke.before?.paints ?? [], paintsAfter: kept ? after?.paints ?? [] : [],
                                      groundBefore: stroke.before != nil, groundAfter: kept)
        return patch.before == patch.after && patch.groundBefore == patch.groundAfter ? MeadowChange() : MeadowChange(ground: patch)
    }

    /// Makes a patch of the painted ground (one made here, or the inverse of one).
    mutating func apply(_ patch: MeadowGroundPatch) {
        var grid = document.ground ?? GroundGrid()
        for paint in patch.paintsAfter where !grid.paints.contains(paint) { _ = grid.index(of: paint) }
        var k = 0
        for row in patch.rows {
            for column in patch.columns {
                grid[column, row] = patch.after[k]
                k += 1
            }
        }
        grid.keepPaints(patch.paintsAfter.count)
        guard patch.groundAfter else {
            document.ground = nil
            scenery.ground = nil
            return
        }
        let drawn = MeadowScenery.Ground.drawn(grid, catalog)
        if scenery.ground == nil || document.ground == nil {
            scenery.ground = MeadowScenery.Ground(grid, catalog: catalog)
        } else {
            for row in patch.rows {
                for column in patch.columns { scenery.ground![column, row] = MeadowScenery.Ground.Paint(rawValue: drawn[Int(grid[column, row])]) ?? .wild }
            }
        }
        document.ground = grid
    }
}
