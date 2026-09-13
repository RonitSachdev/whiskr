import Foundation

/// The lexer's state at the start of every line of a document, kept as the document is edited, so a line
/// can be coloured on its own and an edit costs only the lines it changes.
///
/// States are known for a prefix of the document (`known` lines); the rest is worked out lazily, when a
/// line further down is asked for. An edit forgets what follows it, but keeps the old states: lexing
/// forward from the edit, as soon as a line starts in the state it had before, everything known after it
/// is known again (an edit inside a function changes one line, not the rest of the file).
public struct SyntaxStates: Sendable {
    public let lexer: SyntaxLexer
    /// The state each line starts in; right for the first `known` lines.
    private var starts: [LexerState]
    public private(set) var known: Int
    /// After an edit: from this line on, a recomputed state equal to the old one means the old states up
    /// to `resumeKnown` are right again.
    private var resumeLine: Int?
    private var resumeKnown = 0

    public init(lexer: SyntaxLexer, lineCount: Int) {
        self.lexer = lexer
        starts = Array(repeating: .initial, count: max(lineCount, 1))
        known = 1
    }

    public var lineCount: Int { starts.count }

    /// Lines `range` were replaced by `count` lines (`LineIndex.replace` says which).
    public mutating func replaceLines(_ range: Range<Int>, with count: Int) {
        let lower = min(range.lowerBound, starts.count)
        let upper = min(range.upperBound, starts.count)
        let delta = count - (upper - lower)
        let knewPast = known >= upper
        starts.replaceSubrange(lower..<upper, with: Array(repeating: .initial, count: count))
        if starts.isEmpty { starts = [.initial] }
        if knewPast {
            resumeLine = lower + count
            resumeKnown = min(known + delta, starts.count)
        } else if let line = resumeLine, line >= upper {
            // An earlier edit's resume point is after this one: it moves with the text.
            resumeLine = line + delta
            resumeKnown = min(resumeKnown + delta, starts.count)
        } else {
            resumeLine = nil
        }
        known = min(known, lower + 1)
    }

    /// The tokens of line `line`, lexing the lines above it first if their states are not known yet.
    /// `text` gives a line's text without its "\n".
    public mutating func tokens(line: Int, text: (Int) -> String) -> [SyntaxToken] {
        guard line < starts.count else { return [] }
        advance(through: line, text: text)
        return lexer.tokenize(text(line), from: starts[line]).tokens
    }

    /// The state line `line` starts in, lexing what is needed above it.
    public mutating func state(atLine line: Int, text: (Int) -> String) -> LexerState {
        guard line < starts.count else { return .initial }
        advance(through: line, text: text)
        return starts[line]
    }

    /// After an edit of `lines` (in the new text): lexes from their first line until a line starts as it
    /// did before (the rest of the document is as it was) or `budget` lines have been lexed. Returns the
    /// lines whose colours may have changed: up to that line, or to the end when the budget ran out.
    public mutating func relex(_ lines: Range<Int>, budget: Int, text: (Int) -> String) -> Range<Int> {
        let first = min(lines.lowerBound, starts.count - 1)
        // Nothing is known that far down yet: it is worked out when it is shown.
        guard first < known else { return first..<starts.count }
        var line = first
        var lexed = 0
        while line + 1 < starts.count {
            let end = lexer.tokenize(text(line), from: starts[line]).end
            let next = line + 1
            lexed += 1
            if next >= lines.upperBound, let resume = resumeLine, next >= resume, starts[next] == end, next < resumeKnown {
                known = max(known, resumeKnown)
                resumeLine = nil
                return first..<next
            }
            starts[next] = end
            known = max(known, next + 1)
            line = next
            if next >= lines.upperBound, lexed >= budget { return first..<starts.count }
        }
        resumeLine = nil
        return first..<starts.count
    }

    /// Takes in states worked out elsewhere (a background pass over the whole document).
    public mutating func adopt(_ other: SyntaxStates) {
        guard other.starts.count == starts.count, other.lexer.language == lexer.language else { return }
        self = other
    }

    private mutating func advance(through line: Int, text: (Int) -> String) {
        while known <= line {
            let previous = known - 1
            let end = lexer.tokenize(text(previous), from: starts[previous]).end
            if let resume = resumeLine, known >= resume, starts[known] == end, known < resumeKnown {
                known = resumeKnown
                resumeLine = nil
                continue
            }
            starts[known] = end
            known += 1
        }
    }
}
