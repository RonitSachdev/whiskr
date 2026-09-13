import Foundation

/// The editor's line commands as plain text transformations, so they can be tested without a window:
/// Toggle Comment, Shift Right and Left, and the indentation a new line starts with.
public enum TextEdits {
    /// Comments the lines out, or back in when every non-blank one already is (Xcode's and VS Code's
    /// rule). The marker goes at the shallowest indentation of the lines, followed by a space; blank lines
    /// are left alone.
    public static func toggleLineComment(_ lines: [String], marker: String) -> [String] {
        let filled = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        guard !filled.isEmpty else { return lines }
        let commented = filled.allSatisfy { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(marker) }
        if commented {
            return lines.map { line in
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                var rest = line.dropFirst(indent.count)
                guard rest.hasPrefix(marker) else { return line }
                rest = rest.dropFirst(marker.count)
                if rest.first == " " { rest = rest.dropFirst() }
                return String(indent + rest)
            }
        }
        let column = filled.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { line in
            guard !line.allSatisfy(\.isWhitespace) else { return line }
            let index = line.index(line.startIndex, offsetBy: column)
            return String(line[..<index]) + marker + " " + String(line[index...])
        }
    }

    /// Wraps the text in a block comment, or unwraps it when it already is one (for languages without line
    /// comments: HTML, CSS, Markdown).
    public static func toggleBlockComment(_ text: String, open: String, close: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count >= open.count + close.count {
            var inner = trimmed.dropFirst(open.count).dropLast(close.count)
            if inner.first == " " { inner = inner.dropFirst() }
            if inner.last == " " { inner = inner.dropLast() }
            let lead = String(text.prefix { $0.isWhitespace })
            let trail = String(text.reversed().prefix { $0.isWhitespace }.reversed())
            return lead + String(inner) + trail
        }
        let lead = String(text.prefix { $0 == " " || $0 == "\t" })
        let body = text.dropFirst(lead.count)
        let trailingBreak = body.hasSuffix("\n")
        let inner = String(trailingBreak ? body.dropLast() : body)
        let wrapped: String = lead + open + " " + inner + " " + close
        return trailingBreak ? wrapped + "\n" : wrapped
    }

    /// One more level of indentation on every non-blank line.
    public static func shiftRight(_ lines: [String], unit: String) -> [String] {
        lines.map { $0.allSatisfy(\.isWhitespace) ? $0 : unit + $0 }
    }

    /// One level less: a tab, or up to `width` spaces.
    public static func shiftLeft(_ lines: [String], width: Int) -> [String] {
        lines.map { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix(while: { $0 == " " }).count
            return String(line.dropFirst(min(spaces, width)))
        }
    }

    /// The indentation for the line started by Return, given the text of the line before the cursor:
    /// the same as that line's, one level more after an opening bracket (or a colon ending a line in
    /// Python and YAML, or a tag left open in HTML).
    public static func newlineIndent(after line: String, unit: String, language: SyntaxLanguage) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return indent }
        switch language {
        case .python, .yaml:
            return last == ":" || "([{".contains(last) ? indent + unit : indent
        case .html, .xml:
            let opensTag = last == ">" && !trimmed.hasSuffix("/>") && trimmed.hasPrefix("<") && !trimmed.hasPrefix("</")
                && !trimmed.dropFirst().contains("</") && !trimmed.hasPrefix("<!") && !trimmed.hasPrefix("<?")
            return opensTag ? indent + unit : indent
        case .plain, .markdown:
            return indent
        default:
            return "([{".contains(last) ? indent + unit : indent
        }
    }

    /// The closing bracket typed at the start of an indented line takes one level off it ("}" lines up
    /// with the line that opened the block).
    public static func outdentedForClosing(_ indent: String, unit: String) -> String {
        if indent.hasSuffix(unit) { return String(indent.dropLast(unit.count)) }
        if indent.hasSuffix("\t") { return String(indent.dropLast()) }
        return indent
    }
}
