import Foundation
import Synchronization

/// A document's text as it was at one moment, for reading off the main thread.
public struct TextSnapshot: @unchecked Sendable {
    // An immutable copy, never changed after it is made.
    private let text: NSString
    public let lines: LineIndex

    /// Copies `text` (a document's storage changes under it).
    public init(_ text: NSString, lines: LineIndex) {
        self.text = text.copy() as! NSString
        self.lines = lines
    }

    /// Line `line` as UTF-16 units ending in "\n", as a tokenizer takes it.
    public func units(_ line: Int) -> [UInt16] {
        Self.units(of: text, lines: lines, line: line)
    }

    /// Line `line` of `text` as UTF-16 units ending in "\n".
    public static func units(of text: NSString, lines: LineIndex, line: Int) -> [UInt16] {
        guard line < lines.lineCount else { return [0x0A] }
        let range = lines.range(ofLine: line)
        let length = min(range.count, max(0, text.length - range.lowerBound))
        var units = [UInt16](repeating: 0x0A, count: length + 1)
        units.withUnsafeMutableBufferPointer { buffer in
            text.getCharacters(buffer.baseAddress!, range: NSRange(location: range.lowerBound, length: length))
        }
        return units
    }
}

/// Works out a document's syntax off the main thread, in order from the first line not yet right, and
/// hands back what it has every few milliseconds, so colours appear as it goes and the main thread only
/// takes them in. A part of the file shown before the pass reaches it is tokenized on its own first, from
/// a guessed start (the nearest line above at the left margin), so it is coloured almost at once and
/// corrected when the pass arrives.
///
/// Each `update` starts over from a new copy of the states and text (an edit the main thread could not
/// finish within its budget, a language change, a reload); what was being done for an older one is
/// dropped. It shares its language's tokenizer, line by line, with the main thread and other documents.
public final class BackgroundTokenizer: Sendable {
    public enum Delivery: Sendable {
        /// Lines worked out by the pass for `generation`.
        case progress(generation: Int, SyntaxStates.Progress)
        /// Lines `lines` from a guessed start, until the pass reaches them.
        case provisional(generation: Int, lines: Range<Int>, tokens: [[SyntaxToken]])
    }

    /// How long a stretch of work runs before what it did is handed back.
    static let stretch: UInt64 = 8_000_000
    /// A line may take this long (VS Code's limit) before it is left as far as it got.
    static let lineTimeLimit = 0.5
    /// How far up a guessed start for a shown part of the file is looked for.
    static let guessDistance = 200

    private struct Job {
        var generation: Int
        var states: SyntaxStates
        var text: TextSnapshot
    }

    private struct Work {
        var job: Job?
        /// The pass under way (also while its job is out being worked on): its generation, and how far it is.
        var pass: (generation: Int, valid: Int)?
        /// The lines shown, when the pass has not reached them.
        var shown: (generation: Int, lines: Range<Int>)?
        var running = false
        var stopped = false
    }

    private let tokenizer: TextMateTokenizer
    private let deliver: @Sendable (Delivery) -> Void
    private let queue = DispatchQueue(label: "Whiskr.BackgroundTokenizer", qos: .utility)
    private let work = Mutex(Work())

    public init(tokenizer: TextMateTokenizer, deliver: @escaping @Sendable (Delivery) -> Void) {
        self.tokenizer = tokenizer
        self.deliver = deliver
    }

    /// Works on from `states` (a copy of the document's) over `text`; replaces whatever was being done.
    public func update(generation: Int, states: SyntaxStates, text: TextSnapshot) {
        let start = work.withLock { work -> Bool in
            work.job = Job(generation: generation, states: states, text: text)
            work.pass = states.isComplete ? nil : (generation, states.valid)
            if let shown = work.shown, shown.generation != generation { work.shown = nil }
            return startRunning(&work)
        }
        if start { queue.async { self.run() } }
    }

    /// Lines `lines` are on screen. If the pass has not reached them (and will not soon), they are
    /// tokenized from a guessed start first.
    public func show(generation: Int, lines: Range<Int>) {
        let start = work.withLock { work -> Bool in
            guard let pass = work.pass, pass.generation == generation, lines.lowerBound - pass.valid > Self.guessDistance else { return false }
            work.shown = (generation, lines)
            return startRunning(&work)
        }
        if start { queue.async { self.run() } }
    }

    /// Nothing more is done or delivered.
    public func stop() {
        work.withLock { work in
            work.stopped = true
            work.job = nil
            work.pass = nil
            work.shown = nil
        }
    }

    private func startRunning(_ work: inout Work) -> Bool {
        guard !work.running, !work.stopped else { return false }
        work.running = true
        return true
    }

    private func run() {
        while true {
            enum Next {
                case shown(Range<Int>, Job)
                case pass(Job)
            }
            let next: Next? = work.withLock { work in
                if let shown = work.shown, let job = work.job, job.generation == shown.generation {
                    work.shown = nil
                    if shown.lines.lowerBound - job.states.valid > Self.guessDistance { return .shown(shown.lines, job) }
                }
                guard let job = work.job.take() else {
                    work.running = false
                    return nil
                }
                return .pass(job)
            }
            switch next {
            case nil:
                return
            case .shown(let lines, let job)?:
                let tokens = guess(lines, job.text, tokenizer)
                deliver(.provisional(generation: job.generation, lines: lines, tokens: tokens))
            case .pass(var job)?:
                let deadline = DispatchTime.now().uptimeNanoseconds + Self.stretch
                let done = job.states.advance(using: tokenizer, deadline: deadline, lineTimeLimit: Self.lineTimeLimit, units: job.text.units)
                let progress = job.states.progress(of: done)
                let finished = job.states.isComplete
                let current = work.withLock { work -> Bool in
                    // A newer update replaced this one meanwhile: it is dropped.
                    guard work.job == nil, !work.stopped else { return false }
                    if finished {
                        work.pass = nil
                    } else {
                        work.job = job
                        work.pass = (job.generation, job.states.valid)
                    }
                    return true
                }
                if current { deliver(.progress(generation: job.generation, progress)) }
            }
        }
    }

    /// Tokens for `lines` from a guessed start: the nearest line above them that starts at the left
    /// margin (a top-level declaration, most likely outside any comment or string), in the grammar's
    /// first state.
    private func guess(_ lines: Range<Int>, _ text: TextSnapshot, _ tokenizer: TextMateTokenizer) -> [[SyntaxToken]] {
        var start = lines.lowerBound
        let floor = max(0, lines.lowerBound - Self.guessDistance)
        var line = lines.lowerBound
        while line > floor {
            let units = text.units(line)
            if let first = units.first, first != 0x20, first != 0x09, first != 0x0A {
                start = line
                break
            }
            line -= 1
        }
        var state = tokenizer.initialState
        var result: [[SyntaxToken]] = []
        result.reserveCapacity(lines.count)
        for index in start..<min(lines.upperBound, text.lines.lineCount) {
            let tokenized = tokenizer.tokenize(units: text.units(index), state: state, timeLimit: Self.lineTimeLimit)
            state = tokenized.end
            if index >= lines.lowerBound { result.append(tokenized.tokens) }
        }
        return result
    }
}
