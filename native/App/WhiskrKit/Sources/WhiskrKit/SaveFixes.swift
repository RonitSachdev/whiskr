import Foundation

/// What saving does to the text when asked (Settings › Editor, or a file's `.editorconfig`): trailing spaces
/// and tabs taken off every line, and a line break added at the end. As VS Code's
/// `files.trimTrailingWhitespace` and `files.insertFinalNewline` do on an explicit save: every line, the
/// cursor's too, and nothing for an empty file.
public enum SaveFixes {
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// The edits, first to last (apply them last to first, or all at once).
    public static func edits(in text: NSString, trimTrailingWhitespace: Bool, insertFinalNewline: Bool) -> [Edit] {
        var edits: [Edit] = []
        let length = text.length
        if trimTrailingWhitespace {
            // Lines end at "\n" only (`LineMoves.contentsEnd`): a U+2028 or "\r" inside a line is its text.
            var lineStart = 0
            while lineStart < length {
                let contentsEnd = LineMoves.contentsEnd(text, lineStart)
                let lineEnd = contentsEnd + 1
                var trimmed = contentsEnd
                while trimmed > lineStart, text.character(at: trimmed - 1) == 0x20 || text.character(at: trimmed - 1) == 0x09 { trimmed -= 1 }
                if trimmed < contentsEnd { edits.append(Edit(range: NSRange(location: trimmed, length: contentsEnd - trimmed), text: "")) }
                lineStart = lineEnd
            }
        }
        if insertFinalNewline, length > 0, text.character(at: length - 1) != 0x0A {
            // Not after a last line that trimming leaves empty (VS Code trims first, then looks).
            let last = LineMoves.lineStart(text, length - 1)
            let blank = (last..<length).allSatisfy { text.character(at: $0) == 0x20 || text.character(at: $0) == 0x09 }
            if !(trimTrailingWhitespace && blank) { edits.append(Edit(range: NSRange(location: length, length: 0), text: "\n")) }
        }
        return edits
    }
}
