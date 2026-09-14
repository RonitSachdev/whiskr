import Foundation

/// Where each line of a text starts, in UTF-16 offsets (as NSString and NSRange count), kept up to date
/// edit by edit: the editor's gutter numbers lines, Go to Line finds one, and the highlighter knows which
/// lines an edit touched, without ever walking the whole text again. Lines are broken by "\n" only (the
/// editor's text is normalised, `TextFile`).
public struct LineIndex: Sendable, Equatable {
    /// The first line starts at 0; one more entry follows each "\n".
    public private(set) var starts: [Int]
    public private(set) var length: Int

    public init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        self.starts = starts
        length = offset
    }

    public var lineCount: Int { starts.count }

    /// The line holding `offset` (0-based); an offset at the very end belongs to the last line.
    public func line(at offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The longest line (the first, of equals) and its length in UTF-16 units, without its "\n".
    public var longestLine: (line: Int, length: Int) {
        var best = (line: 0, length: 0)
        for line in starts.indices {
            let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
            if end - starts[line] > best.length { best = (line, end - starts[line]) }
        }
        return best
    }

    /// A line's range without its "\n".
    public func range(ofLine line: Int) -> Range<Int> {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return start..<max(start, end)
    }

    /// `removed` (a range of the old text) was replaced by `inserted`. Returns the lines the edit touched,
    /// in the new text, and how many lines they replaced in the old.
    @discardableResult
    public mutating func replace(_ removed: Range<Int>, with inserted: String) -> (lines: Range<Int>, replacing: Int) {
        let first = line(at: removed.lowerBound)
        let last = line(at: removed.upperBound)
        var added: [Int] = []
        var offset = removed.lowerBound
        for unit in inserted.utf16 {
            offset += 1
            if unit == 0x0A { added.append(offset) }
        }
        let delta = offset - removed.upperBound
        // Line starts after the removed text move by the change in length.
        var tail = Array(starts[(last + 1)...])
        for index in tail.indices { tail[index] += delta }
        starts.removeSubrange((first + 1)...)
        starts += added
        starts += tail
        length += delta
        return (first..<(first + added.count + 1), last - first + 1)
    }
}
