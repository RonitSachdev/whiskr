import Foundation

/// The painted ground: a 512 × 512 grid over x, z ∈ [−150, 150] (about 0.59 units a cell), each cell 0
/// (the meadow's own long grass) or a 1-based index into `paints`. In a file the cells are run-length
/// encoded, row by row from the row at z = −150, each row from x = −150: `[value, count, value, count, …]`,
/// the counts adding up to exactly 262,144. Plain integers: no compression library, no decompression
/// bomb, readable in any language.
///
/// A paint this Whiskr does not know keeps its place in `paints` and its cells keep their value; they
/// are drawn as long grass and written back unchanged.
public struct GroundGrid: Equatable, Sendable {
    /// Cells along each side.
    public static let side = 512
    public static let cellCount = side * side
    /// Half the grid's width, in units. Things may stand a little further out (`MeadowFormat.reach`).
    public static let reach = 150.0
    /// The most paints one meadow lists.
    public static let maxPaints = 16

    /// Paint ids (current ids; aliases resolved), in index order (cell value 1 is `paints[0]`).
    public private(set) var paints: [String]
    /// `cellCount` values, row-major; each 0…`paints.count`.
    public private(set) var cells: [UInt8]
    /// Fields of the ground section from a newer Whiskr, kept as they were.
    public var unknownFields: [String: MeadowJSON]

    /// Unpainted ground.
    public init() {
        paints = []
        cells = [UInt8](repeating: 0, count: Self.cellCount)
        unknownFields = [:]
    }

    init(paints: [String], cells: [UInt8], unknownFields: [String: MeadowJSON]) {
        precondition(cells.count == Self.cellCount)
        self.paints = paints
        self.cells = cells
        self.unknownFields = unknownFields
    }

    /// The cell's value at column `column` (along x) and row `row` (along z).
    public subscript(column: Int, row: Int) -> UInt8 {
        get { cells[row * Self.side + column] }
        set {
            precondition(Int(newValue) <= paints.count, "a cell holds 0 or the index of a listed paint")
            cells[row * Self.side + column] = newValue
        }
    }

    /// The cell a ground point lies in, or nil outside the grid.
    public static func cell(at point: MeadowPoint) -> (column: Int, row: Int)? {
        let size = 2 * reach / Double(side)
        let column = Int(((point.x + reach) / size).rounded(.down)), row = Int(((point.z + reach) / size).rounded(.down))
        guard (0..<side).contains(column), (0..<side).contains(row) else { return nil }
        return (column, row)
    }

    /// The cell value for paint `id` (a `.paint` asset), listing it if it is not listed yet; nil when
    /// `paints` is full. The eraser paints 0.
    public mutating func index(of id: String) -> UInt8? {
        if let i = paints.firstIndex(of: id) { return UInt8(i + 1) }
        guard paints.count < Self.maxPaints else { return nil }
        paints.append(id)
        return UInt8(paints.count)
    }

    /// The paint drawn in a cell: nil for long grass or a paint this Whiskr does not know.
    public func drawnPaint(_ value: UInt8, _ catalog: MeadowCatalog) -> String? {
        guard value > 0, Int(value) <= paints.count else { return nil }
        return catalog.asset(paints[Int(value) - 1])?.id
    }

    /// Whether anything here is kept only because a newer Whiskr wrote it.
    public func hasNewerContent(_ catalog: MeadowCatalog) -> Bool {
        !unknownFields.isEmpty || paints.contains { catalog.asset($0) == nil }
    }

    /// Whether nothing is painted: every cell the meadow's own long grass.
    public var isWild: Bool { !cells.contains { $0 != 0 } }

    /// Lists no more than the first `count` paints (a stroke undone takes back the paints it listed). Every
    /// cell must already hold 0 or one of those.
    public mutating func keepPaints(_ count: Int) {
        guard count < paints.count else { return }
        precondition(count >= 0 && !cells.contains { Int($0) > count }, "only paints no cell holds are let go")
        paints.removeLast(paints.count - count)
    }

    /// How many runs `runs` holds (its length is twice this), counted without making them.
    public var runCount: Int { 1 + changes(in: 0..<Self.cellCount) }

    /// How many cells in `range` (of the cells, in order) differ from the cell before; the first cell of the
    /// grid has none before it. A stroke counts its rows before and after to keep `runCount` without
    /// counting the whole grid again.
    public func changes(in range: Range<Int>) -> Int {
        let range = max(range.lowerBound, 1)..<min(range.upperBound, Self.cellCount)
        guard !range.isEmpty else { return 0 }
        return cells.withUnsafeBufferPointer { cells in
            var changes = 0
            for i in range where cells[i] != cells[i - 1] { changes += 1 }
            return changes
        }
    }

    /// The cells as runs: `[value, count, …]`, neighbouring runs of one value joined.
    public var runs: [Int] {
        var out: [Int] = []
        var value = cells[0], count = 0
        for cell in cells {
            if cell == value {
                count += 1
            } else {
                out += [Int(value), count]
                value = cell
                count = 1
            }
        }
        out += [Int(value), count]
        return out
    }

    /// Why runs cannot be cells.
    public enum RunsProblem: Error, Equatable, Sendable {
        /// An odd number of numbers: a value without its count.
        case unpaired
        /// A value over the number of paints, at the pair's index.
        case value(pair: Int)
        /// A count of 0 or less, at the pair's index.
        case count(pair: Int)
        /// The counts add up to this many cells, not `cellCount`.
        case total(Int)
    }

    /// The cells `runs` describe, with values at most `paintCount`.
    public static func cells(runs: [Int], paintCount: Int) throws(RunsProblem) -> [UInt8] {
        guard runs.count % 2 == 0 else { throw .unpaired }
        var total = 0
        for pair in 0..<(runs.count / 2) {
            let value = runs[pair * 2], count = runs[pair * 2 + 1]
            guard (0...paintCount).contains(value) else { throw .value(pair: pair) }
            guard count > 0 else { throw .count(pair: pair) }
            total += count
            guard total <= cellCount else { throw .total(total) }
        }
        guard total == cellCount else { throw .total(total) }
        var cells = [UInt8](repeating: 0, count: cellCount)
        var at = 0
        for pair in 0..<(runs.count / 2) {
            let value = UInt8(runs[pair * 2]), count = runs[pair * 2 + 1]
            if value != 0 { cells.replaceSubrange(at..<(at + count), with: repeatElement(value, count: count)) }
            at += count
        }
        return cells
    }
}
