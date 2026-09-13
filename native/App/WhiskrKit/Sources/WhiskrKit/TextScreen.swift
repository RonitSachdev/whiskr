import Foundation

/// What a terminal shows, as text only: fed a program's output, it keeps the screen (and the lines that
/// scrolled off its top) the way a terminal would lay them out, for reading a terminal from the command line.
///
/// Only what decides where text lands is understood: cursor moves, erasing, inserting and deleting,
/// scroll regions, wrapping, the alternate screen and the line-drawing character set. Colours and every
/// other setting pass by. Bytes may arrive split anywhere, inside a character or an escape sequence.
public struct TextScreen: Sendable {
    private var stream = TerminalStream()
    private var grid: TextGrid

    public init(columns: Int, rows: Int, scrollback: Int = 10_000) {
        grid = TextGrid(columns: max(columns, 1), rows: max(rows, 1), scrollback: max(scrollback, 0))
    }

    public mutating func feed(_ data: Data) {
        stream.feed(data, into: &grid)
    }

    /// Exactly `rows` lines, each without its trailing blanks.
    public var screenLines: [String] { grid.screen.map(TextGrid.text(of:)) }

    /// Lines that scrolled off the main screen's top, oldest first.
    public var historyLines: [String] {
        grid.history.suffix(grid.scrollback).map { line in
            var line = line
            while line.last == " " { line.removeLast() }
            return line
        }
    }

    /// The last `history` lines of history followed by the screen, with trailing empty screen lines dropped.
    public func text(history: Int) -> [String] {
        var screen = screenLines
        while let last = screen.last, last.isEmpty { screen.removeLast() }
        return Array(historyLines.suffix(max(history, 0))) + screen
    }

    /// As `text(history:)`, but a line the terminal only wrapped because it was too long comes back as the
    /// one line the program printed (a log line, a path): what reading a terminal usually wants.
    public func unwrappedText(history: Int) -> [String] {
        let kept = max(history, 0)
        var rows = Array(zip(grid.history, grid.historyWrapped).suffix(kept)).map { (text: $0.0, wraps: $0.1) }
        rows += grid.screen.indices.map { (text: grid.rowText($0), wraps: grid.wrapped[$0]) }
        var lines: [String] = []
        var joining = false
        for row in rows {
            if joining, !lines.isEmpty { lines[lines.count - 1] += row.text } else { lines.append(row.text) }
            joining = row.wraps
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.map { line in
            var line = line
            while line.last == " " { line.removeLast() }
            return line
        }
    }

    public var cursor: (row: Int, column: Int) { (grid.row, grid.column) }
    public var isAlternateScreen: Bool { grid.usingAlternate }
    public var columns: Int { grid.columns }
    public var rows: Int { grid.rows }
}

// MARK: The stream

/// One control sequence (`ESC [ … final`): its numbers (-1 where one was left out), the private marker
/// before them (`?`, `>`, `<`, `=`; 0 for none), any intermediate bytes and the final byte.
struct ControlSequence: Sendable {
    var parameters: [Int] = []
    var marker: UInt8 = 0
    var intermediates: [UInt8] = []
    var final: UInt8 = 0

    /// The `index`-th number, or `fallback` when it was left out.
    func value(_ index: Int, _ fallback: Int) -> Int {
        index < parameters.count && parameters[index] >= 0 ? parameters[index] : fallback
    }

    /// A count or a position: left out or 0 both mean 1.
    func count(_ index: Int) -> Int { max(value(index, 1), 1) }
}

/// Whoever acts on what the stream finds in a program's output.
protocol TerminalPerformer {
    mutating func printScalar(_ scalar: Unicode.Scalar)
    /// A C0 control character other than ESC, CAN and SUB (which the stream handles itself).
    mutating func control(_ byte: UInt8)
    mutating func controlSequence(_ sequence: ControlSequence)
    mutating func escape(intermediates: [UInt8], final: UInt8)
}

/// Splits a program's output into text, control characters and escape sequences, carrying a part-read
/// character or sequence over to the next call. Strings (OSC, DCS, APC, PM, SOS) are skipped whole.
struct TerminalStream: Sendable {
    private enum State: Sendable { case ground, escape, escapeIntermediate, control, controlIgnore, string, stringEscape }

    private var state = State.ground
    private var utf8: [UInt8] = []
    private var utf8Needed = 0
    private var sequence = ControlSequence()
    private var parameter = -1
    private var collected = 0
    private var intermediates: [UInt8] = []

    /// Past these a sequence is malformed: it is abandoned and what follows is read as text again.
    private static let longestSequence = 64
    private static let longestString = 1 << 20
    private static let escapeByte: UInt8 = 0x1B

    mutating func feed<Performer: TerminalPerformer>(_ data: Data, into performer: inout Performer) {
        data.withUnsafeBytes { raw in
            var index = 0
            while index < raw.count {
                if step(raw[index], &performer) { index += 1 }
            }
        }
    }

    /// Takes one byte; false when the byte ended something and must be read again from the new state.
    private mutating func step<Performer: TerminalPerformer>(_ byte: UInt8, _ performer: inout Performer) -> Bool {
        switch state {
        case .ground:
            return ground(byte, &performer)
        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                sequence = ControlSequence()
                parameter = -1
                collected = 0
                state = .control
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                collected = 0
                state = .string
            case 0x20...0x2F:
                intermediates = [byte]
                state = .escapeIntermediate
            case 0x30...0x7E:
                state = .ground
                performer.escape(intermediates: [], final: byte)
            case Self.escapeByte:
                break
            case 0x18, 0x1A:
                state = .ground
            case 0x00..<0x20:
                performer.control(byte)
            default:
                state = .ground
                return false
            }
        case .escapeIntermediate:
            switch byte {
            case 0x20...0x2F:
                if intermediates.count < 4 { intermediates.append(byte) }
            case 0x30...0x7E:
                state = .ground
                performer.escape(intermediates: intermediates, final: byte)
            case Self.escapeByte:
                state = .escape
            case 0x18, 0x1A:
                state = .ground
            case 0x00..<0x20:
                performer.control(byte)
            default:
                state = .ground
                return false
            }
        case .control:
            collected += 1
            switch byte {
            case 0x30...0x39:
                parameter = min(max(parameter, 0) * 10 + Int(byte - 0x30), 65_535)
            case UInt8(ascii: ";"), UInt8(ascii: ":"):
                sequence.parameters.append(parameter)
                parameter = -1
                if sequence.parameters.count > 32 { state = .controlIgnore }
            case 0x3C...0x3F:
                if collected == 1 { sequence.marker = byte } else { state = .controlIgnore }
            case 0x20...0x2F:
                sequence.intermediates.append(byte)
            case 0x40...0x7E:
                if parameter >= 0 || !sequence.parameters.isEmpty { sequence.parameters.append(parameter) }
                sequence.final = byte
                state = .ground
                performer.controlSequence(sequence)
            case Self.escapeByte:
                state = .escape
            case 0x18, 0x1A:
                state = .ground
            case 0x00..<0x20:
                performer.control(byte)
            default:
                state = .ground
                return false
            }
            if state == .control, collected > Self.longestSequence { state = .controlIgnore }
        case .controlIgnore:
            switch byte {
            case 0x40...0x7E: state = .ground
            case Self.escapeByte: state = .escape
            case 0x18, 0x1A: state = .ground
            case 0x00..<0x20: performer.control(byte)
            case 0x80...0xFF:
                state = .ground
                return false
            default: break
            }
        case .string:
            collected += 1
            switch byte {
            case 0x07:
                state = .ground
            case Self.escapeByte:
                state = .stringEscape
            case 0x0A, 0x0D:
                // No string holds a line break: this one was never ended. The text goes on from here.
                state = .ground
                return false
            default:
                if collected > Self.longestString { state = .ground }
            }
        case .stringEscape:
            if byte == UInt8(ascii: "\\") {
                state = .ground
            } else {
                // ESC and anything else ends the string and starts a sequence of its own.
                state = .escape
                return false
            }
        }
        return true
    }

    private mutating func ground<Performer: TerminalPerformer>(_ byte: UInt8, _ performer: inout Performer) -> Bool {
        if utf8Needed > 0 {
            guard byte & 0xC0 == 0x80 else {
                // A character cut short: shown as the replacement character, and the byte read afresh.
                utf8.removeAll(keepingCapacity: true)
                utf8Needed = 0
                performer.printScalar("\u{FFFD}")
                return false
            }
            utf8.append(byte)
            if utf8.count == utf8Needed + 1 {
                let scalar = String(decoding: utf8, as: UTF8.self).unicodeScalars.first ?? "\u{FFFD}"
                utf8.removeAll(keepingCapacity: true)
                utf8Needed = 0
                performer.printScalar(scalar)
            }
            return true
        }
        switch byte {
        case Self.escapeByte:
            state = .escape
        case 0x18, 0x1A, 0x7F:
            break
        case 0x00..<0x20:
            performer.control(byte)
        case 0x20..<0x80:
            performer.printScalar(Unicode.Scalar(byte))
        case 0xC2...0xDF:
            utf8 = [byte]
            utf8Needed = 1
        case 0xE0...0xEF:
            utf8 = [byte]
            utf8Needed = 2
        case 0xF0...0xF4:
            utf8 = [byte]
            utf8Needed = 3
        default:
            performer.printScalar("\u{FFFD}")
        }
        return true
    }
}

// MARK: The grid

/// The screens themselves: the main one with its history, the alternate one full-screen programs draw
/// on, the cursor, and the settings that change where text lands.
struct TextGrid: Sendable, TerminalPerformer {
    struct Cell: Sendable {
        /// What is drawn here; empty for a blank.
        var text = ""
        /// The left half of a character two cells wide.
        var wide = false
        /// The right half of one.
        var continuation = false
    }

    private struct SavedCursor: Sendable {
        var row = 0
        var column = 0
        var originMode = false
        var autowrap = true
        var graphics: (Bool, Bool) = (false, false)
        var shiftedOut = false
    }

    let columns: Int
    let rows: Int
    let scrollback: Int
    /// The screen being drawn on, and the other one while it is not.
    private(set) var screen: [[Cell]]
    private var stash: [[Cell]]
    /// Each row of the screen ran on into the next because it was full (a soft wrap), not on a new line.
    private(set) var wrapped: [Bool]
    private var stashWrapped: [Bool]
    private(set) var usingAlternate = false
    private(set) var history: [String] = []
    /// Whether each line of history ran on into the next, as `wrapped`. Its row text is kept untrimmed then.
    private(set) var historyWrapped: [Bool] = []
    private(set) var row = 0
    private(set) var column = 0
    /// The cursor is past the last column: the next character starts a new line.
    private var pendingWrap = false
    private var top = 0
    private var bottom: Int
    private var originMode = false
    private var autowrap = true
    private var insertMode = false
    /// G0 and G1 hold the DEC line-drawing set; SO selects G1.
    private var graphics: (Bool, Bool) = (false, false)
    private var shiftedOut = false
    private var saved: [SavedCursor] = [SavedCursor(), SavedCursor()]
    private var savedForAlternate = SavedCursor()
    private var lastPrinted: Unicode.Scalar?
    private var lastCell: (row: Int, column: Int)?

    init(columns: Int, rows: Int, scrollback: Int) {
        self.columns = columns
        self.rows = rows
        self.scrollback = scrollback
        bottom = rows - 1
        screen = Self.blankScreen(columns: columns, rows: rows)
        stash = screen
        wrapped = Array(repeating: false, count: rows)
        stashWrapped = wrapped
    }

    /// A row's text: untrimmed when it wraps on, so a space at its end is not lost when joined.
    func rowText(_ r: Int) -> String {
        guard wrapped[r] else { return Self.text(of: screen[r]) }
        return screen[r].filter { !$0.continuation }.map { $0.text.isEmpty ? " " : $0.text }.joined()
    }

    private static func blankScreen(columns: Int, rows: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(), count: columns), count: rows)
    }

    private var blankLine: [Cell] { Array(repeating: Cell(), count: columns) }

    static func text(of line: [Cell]) -> String {
        var text = ""
        for cell in line where !cell.continuation { text += cell.text.isEmpty ? " " : cell.text }
        while text.last == " " { text.removeLast() }
        return text
    }

    // MARK: Text

    mutating func printScalar(_ given: Unicode.Scalar) {
        var scalar = given
        if graphics.0 && !shiftedOut || graphics.1 && shiftedOut, let drawn = Self.lineDrawing[scalar.value] { scalar = drawn }
        var width = Self.width(of: scalar)
        if width == 0 { return join(scalar) }
        if width == 2 && columns < 2 { width = 1 }
        if pendingWrap {
            pendingWrap = false
            wrapped[row] = true
            column = 0
            index()
        }
        if width == 2 && column == columns - 1 {
            if autowrap {
                blank(row, column)
                wrapped[row] = true
                column = 0
                index()
            } else {
                column = columns - 2
            }
        }
        if insertMode { shiftRight(at: column, by: width) }
        blank(row, column)
        screen[row][column] = Cell(text: String(scalar), wide: width == 2)
        if width == 2 {
            blank(row, column + 1)
            screen[row][column + 1] = Cell(continuation: true)
        }
        lastCell = (row, column)
        lastPrinted = scalar
        column += width
        if column >= columns {
            column = columns - 1
            pendingWrap = autowrap
        }
    }

    /// A combining mark or a joiner goes with the character before it.
    private mutating func join(_ scalar: Unicode.Scalar) {
        guard let (r, c) = lastCell, r < rows, c < columns, !screen[r][c].text.isEmpty else { return }
        screen[r][c].text.unicodeScalars.append(scalar)
    }

    /// Makes a cell blank, and with it the other half of a wide character it belonged to.
    private mutating func blank(_ r: Int, _ c: Int) {
        guard r >= 0, r < rows, c >= 0, c < columns else { return }
        if screen[r][c].continuation, c > 0 { screen[r][c - 1] = Cell() }
        if screen[r][c].wide, c + 1 < columns { screen[r][c + 1] = Cell() }
        screen[r][c] = Cell()
        if let last = lastCell, last == (r, c) { lastCell = nil }
    }

    /// Blanks cells `from..<to` of a line, and the halves of wide characters cut at either end.
    private mutating func erase(row r: Int, from: Int, to: Int) {
        let from = max(from, 0), to = min(to, columns)
        guard from < to else { return }
        if screen[r][from].continuation, from > 0 { screen[r][from - 1] = Cell() }
        if to < columns, screen[r][to].continuation { screen[r][to] = Cell() }
        for c in from..<to { screen[r][c] = Cell() }
        if to == columns { wrapped[r] = false }
        // A line rubbed out from its start no longer continues the one before it.
        if from == 0 && to == columns {
            if r > 0 { wrapped[r - 1] = false } else if !usingAlternate, !historyWrapped.isEmpty { historyWrapped[historyWrapped.count - 1] = false }
        }
        lastCell = nil
    }

    private mutating func shiftRight(at c: Int, by count: Int) {
        let count = min(count, columns - c)
        guard count > 0 else { return }
        if screen[row][c].continuation, c > 0 { screen[row][c - 1] = Cell() }
        screen[row].insert(contentsOf: Array(repeating: Cell(), count: count), at: c)
        screen[row].removeLast(count)
        if let last = screen[row].last, last.wide { screen[row][columns - 1] = Cell() }
        lastCell = nil
    }

    private mutating func deleteCharacters(at c: Int, count: Int) {
        let count = min(count, columns - c)
        guard count > 0 else { return }
        if screen[row][c].continuation, c > 0 { screen[row][c - 1] = Cell() }
        if c + count < columns, screen[row][c + count].continuation { screen[row][c + count] = Cell() }
        screen[row].removeSubrange(c..<c + count)
        screen[row].append(contentsOf: Array(repeating: Cell(), count: count))
        lastCell = nil
    }

    // MARK: Lines and scrolling

    /// Down a line, scrolling the region at its bottom (a line feed, IND).
    private mutating func index() {
        if row == bottom {
            scrollUp(1)
        } else if row < rows - 1 {
            row += 1
        }
    }

    /// Up a line, scrolling the region down at its top (RI).
    private mutating func reverseIndex() {
        if row == top {
            scrollDown(1)
        } else if row > 0 {
            row -= 1
        }
    }

    private mutating func scrollUp(_ count: Int) {
        let count = min(count, bottom - top + 1)
        let keeps = !usingAlternate && top == 0 && bottom == rows - 1 && scrollback > 0
        for _ in 0..<max(count, 0) {
            if keeps {
                history.append(rowText(top))
                historyWrapped.append(wrapped[top])
            }
            screen.remove(at: top)
            wrapped.remove(at: top)
            screen.insert(blankLine, at: bottom)
            wrapped.insert(false, at: bottom)
        }
        if keeps, history.count > scrollback + max(64, scrollback / 8) {
            history.removeFirst(history.count - scrollback)
            historyWrapped.removeFirst(historyWrapped.count - scrollback)
        }
        lastCell = nil
    }

    private mutating func scrollDown(_ count: Int) {
        let count = min(count, bottom - top + 1)
        for _ in 0..<max(count, 0) {
            screen.remove(at: bottom)
            wrapped.remove(at: bottom)
            screen.insert(blankLine, at: top)
            wrapped.insert(false, at: top)
        }
        lastCell = nil
    }

    private mutating func insertLines(_ count: Int) {
        guard row >= top, row <= bottom else { return }
        for _ in 0..<min(count, bottom - row + 1) {
            screen.remove(at: bottom)
            wrapped.remove(at: bottom)
            screen.insert(blankLine, at: row)
            wrapped.insert(false, at: row)
        }
        column = 0
        lastCell = nil
    }

    private mutating func deleteLines(_ count: Int) {
        guard row >= top, row <= bottom else { return }
        for _ in 0..<min(count, bottom - row + 1) {
            screen.remove(at: row)
            wrapped.remove(at: row)
            screen.insert(blankLine, at: bottom)
            wrapped.insert(false, at: bottom)
        }
        column = 0
        lastCell = nil
    }

    // MARK: Cursor

    private mutating func moveTo(row r: Int, column c: Int) {
        if originMode {
            row = min(max(top + r, top), bottom)
        } else {
            row = min(max(r, 0), rows - 1)
        }
        column = min(max(c, 0), columns - 1)
        pendingWrap = false
    }

    private mutating func save() {
        saved[usingAlternate ? 1 : 0] = currentCursor
    }

    private var currentCursor: SavedCursor {
        SavedCursor(row: row, column: column, originMode: originMode, autowrap: autowrap, graphics: graphics, shiftedOut: shiftedOut)
    }

    private mutating func restore(_ cursor: SavedCursor) {
        row = min(cursor.row, rows - 1)
        column = min(cursor.column, columns - 1)
        originMode = cursor.originMode
        autowrap = cursor.autowrap
        graphics = cursor.graphics
        shiftedOut = cursor.shiftedOut
        pendingWrap = false
    }

    // MARK: Screens

    private mutating func useAlternate(clearing: Bool) {
        guard !usingAlternate else { return }
        swap(&screen, &stash)
        swap(&wrapped, &stashWrapped)
        usingAlternate = true
        if clearing {
            screen = Self.blankScreen(columns: columns, rows: rows)
            wrapped = Array(repeating: false, count: rows)
        }
        lastCell = nil
    }

    private mutating func useMain(clearingAlternate: Bool) {
        guard usingAlternate else { return }
        if clearingAlternate {
            screen = Self.blankScreen(columns: columns, rows: rows)
            wrapped = Array(repeating: false, count: rows)
        }
        swap(&screen, &stash)
        swap(&wrapped, &stashWrapped)
        usingAlternate = false
        lastCell = nil
    }

    private mutating func reset() {
        useMain(clearingAlternate: true)
        screen = Self.blankScreen(columns: columns, rows: rows)
        stash = screen
        wrapped = Array(repeating: false, count: rows)
        stashWrapped = wrapped
        row = 0
        column = 0
        pendingWrap = false
        top = 0
        bottom = rows - 1
        originMode = false
        autowrap = true
        insertMode = false
        graphics = (false, false)
        shiftedOut = false
        saved = [SavedCursor(), SavedCursor()]
        lastPrinted = nil
        lastCell = nil
    }

    // MARK: Controls

    mutating func control(_ byte: UInt8) {
        switch byte {
        case 0x0A, 0x0B, 0x0C:
            pendingWrap = false
            index()
        case 0x0D:
            column = 0
            pendingWrap = false
        case 0x08:
            if column > 0 { column -= 1 }
            pendingWrap = false
        case 0x09:
            column = min(columns - 1, (column / 8 + 1) * 8)
            pendingWrap = false
        case 0x0E:
            shiftedOut = true
        case 0x0F:
            shiftedOut = false
        default:
            break
        }
    }

    mutating func escape(intermediates: [UInt8], final: UInt8) {
        if let first = intermediates.first {
            switch first {
            case UInt8(ascii: "("): graphics.0 = final == UInt8(ascii: "0")
            case UInt8(ascii: ")"): graphics.1 = final == UInt8(ascii: "0")
            default: break
            }
            return
        }
        switch final {
        case UInt8(ascii: "7"): save()
        case UInt8(ascii: "8"): restore(saved[usingAlternate ? 1 : 0])
        case UInt8(ascii: "D"):
            pendingWrap = false
            index()
        case UInt8(ascii: "M"):
            pendingWrap = false
            reverseIndex()
        case UInt8(ascii: "E"):
            column = 0
            pendingWrap = false
            index()
        case UInt8(ascii: "c"): reset()
        default: break
        }
    }

    mutating func controlSequence(_ s: ControlSequence) {
        if s.marker == UInt8(ascii: "?") {
            guard s.intermediates.isEmpty, s.final == UInt8(ascii: "h") || s.final == UInt8(ascii: "l") else { return }
            for mode in s.parameters { setPrivateMode(mode, on: s.final == UInt8(ascii: "h")) }
            return
        }
        guard s.marker == 0 else { return }
        if s.intermediates == [UInt8(ascii: "!")], s.final == UInt8(ascii: "p") {
            // A soft reset: the modes and margins, not the screen.
            originMode = false
            autowrap = true
            insertMode = false
            top = 0
            bottom = rows - 1
            return
        }
        guard s.intermediates.isEmpty else { return }
        let n = s.count(0)
        switch s.final {
        case UInt8(ascii: "A"):
            row = max(row - n, row >= top ? top : 0)
            pendingWrap = false
        case UInt8(ascii: "B"), UInt8(ascii: "e"):
            row = min(row + n, row <= bottom ? bottom : rows - 1)
            pendingWrap = false
        case UInt8(ascii: "C"), UInt8(ascii: "a"):
            column = min(column + n, columns - 1)
            pendingWrap = false
        case UInt8(ascii: "D"):
            column = max(column - n, 0)
            pendingWrap = false
        case UInt8(ascii: "E"):
            row = min(row + n, row <= bottom ? bottom : rows - 1)
            column = 0
            pendingWrap = false
        case UInt8(ascii: "F"):
            row = max(row - n, row >= top ? top : 0)
            column = 0
            pendingWrap = false
        case UInt8(ascii: "G"), UInt8(ascii: "`"):
            column = min(n - 1, columns - 1)
            pendingWrap = false
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            moveTo(row: s.count(0) - 1, column: s.count(1) - 1)
        case UInt8(ascii: "d"):
            moveTo(row: n - 1, column: column)
        case UInt8(ascii: "J"):
            eraseDisplay(s.value(0, 0))
        case UInt8(ascii: "K"):
            switch s.value(0, 0) {
            case 0: erase(row: row, from: column, to: columns)
            case 1: erase(row: row, from: 0, to: column + 1)
            case 2: erase(row: row, from: 0, to: columns)
            default: break
            }
        case UInt8(ascii: "X"):
            erase(row: row, from: column, to: column + n)
        case UInt8(ascii: "@"):
            shiftRight(at: column, by: n)
        case UInt8(ascii: "P"):
            deleteCharacters(at: column, count: n)
        case UInt8(ascii: "L"):
            insertLines(n)
        case UInt8(ascii: "M"):
            deleteLines(n)
        case UInt8(ascii: "S"):
            scrollUp(n)
        case UInt8(ascii: "T"):
            // With more numbers this is a mouse report, not a scroll.
            if s.parameters.count <= 1 { scrollDown(n) }
        case UInt8(ascii: "r"):
            let first = s.count(0) - 1, last = min(s.value(1, rows), rows) - 1
            if first < last {
                top = first
                bottom = last
                moveTo(row: 0, column: 0)
            }
        case UInt8(ascii: "s"):
            if s.parameters.isEmpty { save() }
        case UInt8(ascii: "u"):
            if s.parameters.isEmpty { restore(saved[usingAlternate ? 1 : 0]) }
        case UInt8(ascii: "b"):
            if let last = lastPrinted { for _ in 0..<min(n, columns * rows) { printScalar(last) } }
        case UInt8(ascii: "I"):
            for _ in 0..<min(n, columns) { column = min(columns - 1, (column / 8 + 1) * 8) }
            pendingWrap = false
        case UInt8(ascii: "Z"):
            for _ in 0..<min(n, columns) { column = max(0, (column - 1) / 8 * 8) }
            pendingWrap = false
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            if s.parameters.contains(4) { insertMode = s.final == UInt8(ascii: "h") }
        default:
            break
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            erase(row: row, from: column, to: columns)
            for r in row + 1..<rows { erase(row: r, from: 0, to: columns) }
        case 1:
            for r in 0..<row { erase(row: r, from: 0, to: columns) }
            erase(row: row, from: 0, to: column + 1)
        case 2:
            for r in 0..<rows { erase(row: r, from: 0, to: columns) }
        case 3:
            history.removeAll()
            historyWrapped.removeAll()
        default:
            break
        }
    }

    private mutating func setPrivateMode(_ mode: Int, on: Bool) {
        switch mode {
        case 6:
            originMode = on
            moveTo(row: 0, column: 0)
        case 7:
            autowrap = on
            if !on { pendingWrap = false }
        case 1049:
            if on {
                savedForAlternate = currentCursor
                useAlternate(clearing: true)
            } else if usingAlternate {
                useMain(clearingAlternate: false)
                restore(savedForAlternate)
            }
        case 1047:
            if on { useAlternate(clearing: false) } else { useMain(clearingAlternate: true) }
        case 47:
            if on { useAlternate(clearing: false) } else { useMain(clearingAlternate: false) }
        default:
            break
        }
    }

    // MARK: Character widths

    /// Cells a character takes: 0 for combining marks and joiners, 2 for East Asian wide characters and
    /// emoji shown as pictures, 1 for the rest.
    static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x300 { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if (0x1160...0x11FF).contains(value) { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        for range in wideRanges where range.contains(value) { return 2 }
        return 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
        0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    /// DEC special graphics, as `ESC ( 0` selects them: the box-drawing set full-screen programs use.
    static let lineDrawing: [UInt32: Unicode.Scalar] = {
        let pairs: [(Character, Unicode.Scalar)] = [
            ("`", "◆"), ("a", "▒"), ("b", "␉"), ("c", "␌"), ("d", "␍"), ("e", "␊"), ("f", "°"), ("g", "±"),
            ("h", "␤"), ("i", "␋"), ("j", "┘"), ("k", "┐"), ("l", "┌"), ("m", "└"), ("n", "┼"), ("o", "⎺"),
            ("p", "⎻"), ("q", "─"), ("r", "⎼"), ("s", "⎽"), ("t", "├"), ("u", "┤"), ("v", "┴"), ("w", "┬"),
            ("x", "│"), ("y", "≤"), ("z", "≥"), ("{", "π"), ("|", "≠"), ("}", "£"), ("~", "·"),
        ]
        var table: [UInt32: Unicode.Scalar] = [:]
        for (key, value) in pairs { table[key.unicodeScalars.first!.value] = value }
        return table
    }()
}
