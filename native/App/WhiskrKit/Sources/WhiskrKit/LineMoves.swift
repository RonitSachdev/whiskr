import Foundation

/// The editor's whole-line commands, as VS Code has them: Move Line Up and Down (⌥↑ ⌥↓), Copy Line Up and
/// Down (⇧⌥↑ ⇧⌥↓) and Delete Line (⇧⌘K). Each acts on every line the selection touches (a selection
/// ending at the start of a line leaves that line out) and gives one replacement, so it is one undo.
public enum LineMoves {
    /// Replace `range` with `text`, then select `selection`.
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var text: String
        public var selection: NSRange
    }

    /// The lines the selection touches: where they start, and where their text ends (before the last
    /// line's "\n", if it has one).
    static func block(_ text: NSString, _ selection: NSRange) -> (start: Int, end: Int) {
        var last = NSMaxRange(selection)
        if selection.length > 0, last > selection.location, text.character(at: last - 1) == 0x0A { last -= 1 }
        let start = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var lineEnd = 0, contentsEnd = 0
        text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: max(start, last), length: 0))
        return (start, contentsEnd)
    }

    /// The block swapped with the line above (`up`) or below; nil at the top or the bottom.
    public static func move(_ text: NSString, selection: NSRange, up: Bool) -> Edit? {
        let (start, end) = block(text, selection)
        let body = text.substring(with: NSRange(location: start, length: end - start))
        if up {
            guard start > 0 else { return nil }
            let above = text.lineRange(for: NSRange(location: start - 1, length: 0))
            let line = text.substring(with: NSRange(location: above.location, length: start - 1 - above.location))
            let shift = (line as NSString).length + 1
            return Edit(range: NSRange(location: above.location, length: end - above.location), text: body + "\n" + line,
                        selection: NSRange(location: selection.location - shift, length: selection.length))
        }
        guard end < text.length else { return nil }
        var lineEnd = 0, contentsEnd = 0
        text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: end + 1, length: 0))
        let line = text.substring(with: NSRange(location: end + 1, length: contentsEnd - end - 1))
        let shift = (line as NSString).length + 1
        return Edit(range: NSRange(location: start, length: contentsEnd - start), text: line + "\n" + body,
                    selection: NSRange(location: selection.location + shift, length: selection.length))
    }

    /// The block doubled: the selection on the lower copy (`up` false) or where it was (the upper copy).
    public static func copy(_ text: NSString, selection: NSRange, up: Bool) -> Edit {
        let (start, end) = block(text, selection)
        let body = text.substring(with: NSRange(location: start, length: end - start))
        let shift = up ? 0 : (body as NSString).length + 1
        return Edit(range: NSRange(location: start, length: end - start), text: body + "\n" + body,
                    selection: NSRange(location: selection.location + shift, length: selection.length))
    }

    /// The block gone, with its line break; the cursor on the line that takes its place, at the same column
    /// where that line is long enough.
    public static func delete(_ text: NSString, selection: NSRange) -> Edit {
        let (start, end) = block(text, selection)
        let column = selection.location - start
        let isLast = end >= text.length
        var range = NSRange(location: start, length: end - start)
        var lineStart = start
        if !isLast {
            range.length += 1
        } else if start > 0 {
            // The last lines: the break before them goes instead, and the cursor goes up a line.
            range = NSRange(location: start - 1, length: end - start + 1)
            lineStart = text.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        let after = text.replacingCharacters(in: range, with: "") as NSString
        var lineEnd = 0, contentsEnd = 0
        after.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
        let caret = lineStart + min(column, contentsEnd - lineStart)
        return Edit(range: range, text: "", selection: NSRange(location: caret, length: 0))
    }
}
