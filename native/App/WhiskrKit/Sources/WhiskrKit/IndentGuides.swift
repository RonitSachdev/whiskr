import Foundation

/// Indent guides: how many thin lines each line shows (one at each level of indentation, a blank line
/// taking its block's), and the block the cursor is in, whose guide is drawn stronger. Translated from VS
/// Code's `computeIndentLevel`, `getLinesIndentGuides` and `getActiveIndentGuide`
/// (src/vs/editor/common/model/utils.ts and guidesTextModelPart.ts in microsoft/vscode, MIT).
public enum IndentGuides {
    /// The indentation's width in columns (a tab to the next multiple of `tabSize`); nil for a line of only
    /// whitespace.
    public static func indentColumns(_ line: String, tabSize: Int) -> Int? {
        var indent = 0
        for unit in line.utf16 {
            switch unit {
            case 0x20: indent += 1
            case 0x09: indent = indent - indent % tabSize + tabSize
            default: return indent
            }
        }
        return nil
    }

    /// The lines' text and the sizes, for looking up and down from a line.
    public struct Lines {
        public var count: Int
        public var text: (Int) -> String
        public var tabSize: Int
        public var indentSize: Int
        /// Python's and YAML's rule (VS Code's `offSide`): a blank line before a dedent belongs to the block
        /// below, not the one above.
        public var offSide: Bool
        /// How far to look for the line with text around a run of blank lines.
        public var reach = 5000

        public init(count: Int, tabSize: Int, indentSize: Int, offSide: Bool = false, text: @escaping (Int) -> String) {
            self.count = count
            self.text = text
            self.tabSize = max(1, tabSize)
            self.indentSize = max(1, indentSize)
            self.offSide = offSide
        }

        func indent(_ line: Int) -> Int? { indentColumns(text(line), tabSize: tabSize) }

        func level(columns: Int) -> Int { (columns + indentSize - 1) / indentSize }

        /// The indentation of the nearest line with text above (`step` -1) or below `line`; -1 for none.
        func neighbour(of line: Int, step: Int) -> Int {
            var index = line + step
            var looked = 0
            while index >= 0, index < count, looked < reach {
                if let indent = indent(index) { return indent }
                index += step
                looked += 1
            }
            return -1
        }

        /// A blank line's level, from the lines with text around it.
        func blankLevel(above: Int, below: Int) -> Int {
            if above == -1 || below == -1 { return 0 }
            if above < below { return 1 + above / indentSize }
            if above == below { return level(columns: below) }
            return offSide ? level(columns: below) : 1 + below / indentSize
        }

        /// The number of guides `line` shows.
        public func level(_ line: Int) -> Int {
            if let indent = indent(line) { return level(columns: indent) }
            return blankLevel(above: neighbour(of: line, step: -1), below: neighbour(of: line, step: 1))
        }
    }

    /// The number of guides on each line of `range`.
    public static func levels(_ range: Range<Int>, of lines: Lines) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(range.count)
        var above = -2, below = -2, belowLine = -1
        for line in range {
            if let indent = lines.indent(line) {
                above = indent
                result.append(lines.level(columns: indent))
                continue
            }
            if above == -2 { above = lines.neighbour(of: line, step: -1) }
            if below == -2 || belowLine < line {
                below = -1
                belowLine = lines.count
                var index = line + 1
                while index < lines.count, index - line <= lines.reach {
                    if let indent = lines.indent(index) {
                        below = indent
                        belowLine = index
                        break
                    }
                    index += 1
                }
            }
            result.append(lines.blankLevel(above: above, below: below))
        }
        return result
    }

    /// The block the cursor's line belongs to: its first and last line and its level (its guide is the
    /// `level`th, drawn at column `(level - 1) * indentSize`). Level 0 is no block. Looks no further than
    /// `bounds` (the lines on screen), as VS Code does.
    public struct Active: Equatable, Sendable {
        public var lines: ClosedRange<Int>
        public var level: Int
    }

    public static func active(at line: Int, in lines: Lines, bounds: Range<Int>) -> Active {
        let initial = lines.level(line)
        // The first line of a block (its next line one level deeper) shows the block it opens; the last
        // (the line before one level deeper), the block it closes.
        if line + 1 < lines.count, lines.level(line + 1) == initial + 1 {
            return extend(Active(lines: (line + 1)...(line + 1), level: initial + 1), in: lines, bounds: bounds, up: false)
        }
        if line > 0, lines.level(line - 1) == initial + 1 {
            return extend(Active(lines: (line - 1)...(line - 1), level: initial + 1), in: lines, bounds: bounds, down: false)
        }
        guard initial > 0 else { return Active(lines: line...line, level: 0) }
        return extend(Active(lines: line...line, level: initial), in: lines, bounds: bounds)
    }

    private static func extend(_ start: Active, in lines: Lines, bounds: Range<Int>, up: Bool = true, down: Bool = true) -> Active {
        var lower = start.lines.lowerBound, upper = start.lines.upperBound
        if up {
            while lower - 1 >= max(0, bounds.lowerBound), lines.level(lower - 1) >= start.level { lower -= 1 }
        }
        if down {
            while upper + 1 < min(lines.count, bounds.upperBound), lines.level(upper + 1) >= start.level { upper += 1 }
        }
        return Active(lines: lower...upper, level: start.level)
    }
}
