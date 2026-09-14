import Foundation

/// The syntax of every line of a document, kept as it is edited: the state each line starts in and its
/// tokens. A line is tokenized on its own from its start state, so an edit costs only the lines whose
/// tokens or end state it changes.
///
/// Lines `0..<valid` are right; the rest are worked out in order (`advance`), on the main thread for an
/// edit's own lines and on a background queue for the rest (`BackgroundTokenizer`), which hands back what
/// it worked out (`Progress`). An edit keeps the old states and tokens of the lines after it: tokenizing
/// forward from the edit, as soon as a line starts in the state it started in before, everything that was
/// right after it is right again (an edit inside a function changes one line, not the rest of the file).
/// Until then the old tokens of those lines are still shown: they are usually right, and are replaced as
/// the new ones come.
public struct SyntaxStates: Sendable {
    /// The state each line starts in (nil for the first line, and for lines not reached yet).
    private var starts: [StateStack?]
    /// Each line's tokens; for lines from `valid` on, possibly out of date, or nil.
    private var tokens: [[SyntaxToken]?]
    /// Lines `0..<valid` have their right tokens, and line `valid` its right start state.
    public private(set) var valid = 0
    /// After edits: stretches of lines whose old states and tokens are right again once tokenizing
    /// reaches `line` and finds the state it started in before.
    private var resumes: [Resume] = []

    struct Resume: Equatable {
        /// The first line whose old start state may be met again …
        var line: Int
        /// … and up to which the old ones are then right (its start state too).
        var until: Int
    }

    public init(lineCount: Int) {
        starts = Array(repeating: nil, count: max(lineCount, 1))
        tokens = Array(repeating: nil, count: max(lineCount, 1))
    }

    public var lineCount: Int { starts.count }
    public var isComplete: Bool { valid >= starts.count }

    /// Line `line`'s tokens: right for lines before `valid`, the last known (or nil) after.
    public func tokens(line: Int) -> [SyntaxToken]? {
        line < tokens.count ? tokens[line] : nil
    }

    /// Lines `range` were replaced by `count` lines (`LineIndex.replace` says which).
    public mutating func replaceLines(_ range: Range<Int>, with count: Int) {
        let lower = min(range.lowerBound, starts.count)
        let upper = min(max(range.upperBound, lower), starts.count)
        let delta = count - (upper - lower)
        // The edited lines' first keeps its start state: it depends only on the lines above.
        var newStarts = [StateStack?](repeating: nil, count: count)
        if count > 0, lower < starts.count { newStarts[0] = starts[lower] }
        starts.replaceSubrange(lower..<upper, with: newStarts)
        tokens.replaceSubrange(lower..<upper, with: [[SyntaxToken]?](repeating: nil, count: count))
        if starts.isEmpty {
            starts = [nil]
            tokens = [nil]
        }

        var moved: [Resume] = []
        for resume in resumes {
            if resume.until <= lower {
                moved.append(resume)
            } else if resume.line >= upper {
                moved.append(Resume(line: resume.line + delta, until: resume.until + delta))
            } else if resume.line < lower {
                // The stretch is cut at the edit: what is above it stays good.
                moved.append(Resume(line: resume.line, until: lower))
            } else if resume.until >= upper {
                // It began inside the edit: what follows the edit stays good together.
                moved.append(Resume(line: lower + count, until: resume.until + delta))
            }
        }
        if valid >= upper {
            moved.append(Resume(line: lower + count, until: min(valid + delta, starts.count)))
        }
        resumes = moved.filter { $0.line <= $0.until && $0.until <= starts.count }.sorted { ($0.line, $0.until) < ($1.line, $1.until) }
        valid = min(valid, lower)
    }

    /// Tokenizes lines from `valid` on, until every line is right, `deadline` passes (an uptime in
    /// nanoseconds) or `lines` have been tokenized. `units` gives a line's UTF-16 units ending in "\n".
    /// A line that gives up (`TokenizedLine.stoppedEarly`) because it ran past `lineTimeLimit` is kept as
    /// far as it got when `keepsStoppedLines` (the background's long limit), else left for the background,
    /// as is a line the tokenizer is not free for within `lockWait` seconds, when given (the main thread's),
    /// and a line longer than `longestLine` units: the time limit is checked only between matches, and one
    /// search in a long line can scan it from every position, so only the line's length bounds its cost.
    /// Returns the lines tokenized (with, between them, any whose old tokens turned out right again).
    @discardableResult
    public mutating func advance(using tokenizer: TextMateTokenizer, deadline: UInt64 = .max, lines: Int = .max, lineTimeLimit: Double? = nil,
                                 keepsStoppedLines: Bool = true, lockWait: Double? = nil, longestLine: Int = .max,
                                 units: (Int) -> [UInt16]) -> Range<Int> {
        let first = valid
        var last = valid
        var done = 0
        while valid < starts.count, done < lines {
            if done > 0, DispatchTime.now().uptimeNanoseconds >= deadline { break }
            let line = valid
            let text = units(line)
            if text.count - 1 > longestLine { break }
            let state = line == 0 ? nil : starts[line]
            let tokenized = lockWait.map { tokenizer.tokenize(units: text, state: state, timeLimit: lineTimeLimit, waitingAtMost: $0) }
                ?? tokenizer.tokenize(units: text, state: state, timeLimit: lineTimeLimit)
            guard let result = tokenized else { break }
            if result.stoppedEarly, !keepsStoppedLines, text.count - 1 <= TextMateTokenizer.lineLimit {
                // Too slow for here: left for the background.
                break
            }
            tokens[line] = result.tokens
            done += 1
            last = line + 1
            let next = line + 1
            guard next < starts.count else {
                valid = next
                resumes.removeAll()
                break
            }
            if let index = resumes.firstIndex(where: { $0.line <= next && next <= $0.until }), let old = starts[next], old == result.end {
                // The line ends as it did before the edit: the old tokens after it are right.
                valid = max(next, resumes[index].until)
                resumes.removeAll { $0.until <= valid }
                continue
            }
            starts[next] = result.end
            valid = next
            // The old state just replaced can no longer be met again: a stretch now starts after it.
            resumes = resumes.compactMap { resume in
                var resume = resume
                if resume.line <= next { resume.line = next + 1 }
                return resume.line <= resume.until ? resume : nil
            }
        }
        return first..<max(first, last)
    }

    /// Tokens for lines not reached yet, worked out from a guessed start (`BackgroundTokenizer`'s view of
    /// a far part of a file): shown until the right ones come. Only lines with no tokens take them: lines
    /// already right are left as they are, and so are a line's last known tokens, which may turn out right
    /// again when tokenizing meets their old start state (`advance` then keeps them, and would keep a guess).
    public mutating func takeProvisional(_ provisional: [[SyntaxToken]], from line: Int) -> Range<Int> {
        let lower = max(line, valid), upper = min(line + provisional.count, tokens.count)
        guard lower < upper else { return lower..<lower }
        var changed: Range<Int>?
        for index in lower..<upper where tokens[index] == nil {
            tokens[index] = provisional[index - line]
            changed = (changed?.lowerBound ?? index)..<(index + 1)
        }
        return changed ?? lower..<lower
    }

    // MARK: Work done elsewhere

    /// What a copy worked out: lines `lines`, their tokens and the states they start in.
    public struct Progress: Sendable {
        public let lines: Range<Int>
        let starts: [StateStack?]
        let tokens: [[SyntaxToken]?]
        let valid: Int
        let resumes: [Resume]
    }

    /// Lines `lines` as this copy has them (what its `advance` returned), for the value it was copied from.
    public func progress(of lines: Range<Int>) -> Progress {
        let lower = min(lines.lowerBound, tokens.count), upper = min(lines.upperBound, tokens.count)
        let startsUpper = min(upper + 1, starts.count)
        return Progress(lines: lower..<upper, starts: Array(starts[lower..<startsUpper]), tokens: Array(tokens[lower..<upper]), valid: valid, resumes: resumes)
    }

    /// Takes in a copy's progress. The copy must have been made from this value with no edit since.
    public mutating func apply(_ progress: Progress) {
        let lower = progress.lines.lowerBound
        guard lower + progress.starts.count <= starts.count, progress.lines.upperBound <= tokens.count else { return }
        starts.replaceSubrange(lower..<(lower + progress.starts.count), with: progress.starts)
        tokens.replaceSubrange(progress.lines, with: progress.tokens)
        valid = progress.valid
        resumes = progress.resumes
    }
}
