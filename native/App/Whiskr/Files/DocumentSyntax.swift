import Foundation
import WhiskrKit

/// A document's syntax as it is worked out (docs/ARCHITECTURE.md, "Highlighting"): the grammar of its
/// language, compiled off the main thread the first time the language is needed; each line's tokens and
/// start state (`SyntaxStates`); and a background pass (`BackgroundTokenizer`) that works through what
/// the main thread leaves.
///
/// An edit re-tokenizes its own lines on the main thread, for at most `editBudget`: typing inside a line
/// settles there, so its colours are right in the same frame. Anything more (a comment opened above a
/// thousand lines, a paste, a file just opened) goes to the background pass, which hands back what it has
/// every few milliseconds; lines show their old colours (or none, for new ones) until then. Nothing waits
/// for it.
final class DocumentSyntax {
    /// How long an edit may tokenize on the main thread: well inside a frame, after the text system's own
    /// work for the keystroke.
    static let editBudget: UInt64 = 3_000_000
    /// How long an edit waits for a line another document's or the background's is tokenizing (with the
    /// same tokenizer) before leaving its own lines to the background.
    static let lockWait = 0.001
    /// The longest line an edit tokenizes here, in UTF-16 units. A search's time limit holds only between
    /// matches, and one search can scan a line from every position, so its cost grows with the square of
    /// the line (a C++ line of 2,000 spaces takes 20 ms, of 500 about 1 ms): longer lines go to the
    /// background, where a slow line stalls nothing. Lines of code are far shorter.
    static let editLineLimit = 500

    private(set) var language: CodeLanguage
    /// The language's tokenizer, shared with other documents in it; nil until its grammar is compiled.
    private var tokenizer: TextMateTokenizer?
    private var states = SyntaxStates(lineCount: 1)
    private var worker: BackgroundTokenizer?
    /// Goes up with every change of the text or the language; work for an older one is dropped.
    private var generation = 0
    private var loading: Task<Void, Never>?
    /// The text and its lines, read when a line is tokenized or a copy is handed to the background.
    private let text: () -> (text: NSString, lines: LineIndex)
    /// Told which lines' tokens changed, off an edit (the background's work, a grammar arriving).
    var onChange: ((Range<Int>) -> Void)?

    init(language: CodeLanguage, text: @escaping () -> (text: NSString, lines: LineIndex)) {
        self.language = language
        self.text = text
    }

    isolated deinit {
        worker?.stop()
        loading?.cancel()
    }

    /// Every line's tokens are worked out (or the language has no grammar).
    var isComplete: Bool { language.scopeName == nil || (tokenizer != nil && states.isComplete) }

    /// Line `line`'s tokens: right, last known, or none yet.
    func tokens(line: Int) -> [SyntaxToken] {
        states.tokens(line: line) ?? []
    }

    /// Whether text in `scopes` is code, a string or a comment (for pairs typed around).
    func context(of scopes: ScopeStack) -> TokenContext {
        tokenizer?.grammar.context(of: scopes) ?? .code
    }

    func setLanguage(_ language: CodeLanguage) {
        guard language != self.language else { return }
        reload(language)
    }

    /// Starts again with `language`'s grammar as it is now (also when it is the same language, after
    /// languages were added or removed).
    func reload(_ language: CodeLanguage) {
        self.language = language
        worker?.stop()
        worker = nil
        tokenizer = nil
        reset()
    }

    /// The whole text was replaced (opened, reloaded): everything is worked out again.
    func reset() {
        generation += 1
        let previous = states.lineCount
        states = SyntaxStates(lineCount: text().lines.lineCount)
        onChange?(0..<max(previous, states.lineCount))
        if tokenizer != nil {
            handToBackground()
        } else {
            load()
        }
    }

    /// Lines `range` were replaced by `count` lines. Returns the lines re-tokenized here.
    func edited(_ range: Range<Int>, count: Int) -> Range<Int> {
        generation += 1
        states.replaceLines(range, with: count)
        guard let tokenizer else { return range.lowerBound..<range.lowerBound }
        var done = states.valid..<states.valid
        // Only an edit in the part already worked out is tokenized here; anything further down waits for
        // the pass anyway.
        if states.valid >= range.lowerBound {
            let start = DispatchTime.now().uptimeNanoseconds
            let (text, lines) = text()
            done = states.advance(using: tokenizer, deadline: start + Self.editBudget, lineTimeLimit: Double(Self.editBudget) / 1e9,
                                  keepsStoppedLines: false, lockWait: Self.lockWait, longestLine: Self.editLineLimit) {
                TextSnapshot.units(of: text, lines: lines, line: $0)
            }
        }
        if !states.isComplete { handToBackground() }
        return done
    }

    /// Lines on screen: if the background has not reached them, it looks at them first.
    func show(_ lines: Range<Int>) {
        worker?.show(generation: generation, lines: lines)
    }

    /// The whole text was replaced, with its first lines already tokenized in `language` while the file was
    /// read (`FileDocument.PreparedSyntax`): those show at once, the background does the rest.
    func reset(language: CodeLanguage, tokenizer: TextMateTokenizer, states: SyntaxStates) {
        guard states.lineCount == text().lines.lineCount else {
            self.language = language
            return reload(language)
        }
        if language != self.language || self.tokenizer !== tokenizer {
            worker?.stop()
            worker = nil
            loading?.cancel()
            self.language = language
            start(with: tokenizer)
        }
        generation += 1
        let previous = self.states.lineCount
        self.states = states
        onChange?(0..<max(previous, states.lineCount))
        handToBackground()
    }

    private func load() {
        loading?.cancel()
        let language = language
        loading = Task { [weak self] in
            let tokenizer = await GrammarStore.shared.tokenizer(for: language)
            guard let self, !Task.isCancelled, self.language == language, let tokenizer else { return }
            self.start(with: tokenizer)
            self.handToBackground()
        }
    }

    private func start(with tokenizer: TextMateTokenizer) {
        self.tokenizer = tokenizer
        worker = BackgroundTokenizer(tokenizer: tokenizer) { [weak self] delivery in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.take(delivery) }
            }
        }
    }

    private func handToBackground() {
        guard let worker else { return }
        let (text, lines) = text()
        worker.update(generation: generation, states: states, text: TextSnapshot(text, lines: lines))
    }

    private func take(_ delivery: BackgroundTokenizer.Delivery) {
        switch delivery {
        case .progress(let generation, let progress):
            guard generation == self.generation else { return }
            states.apply(progress)
            if !progress.lines.isEmpty { onChange?(progress.lines) }
        case .provisional(let generation, let lines, let tokens):
            guard generation == self.generation else { return }
            let changed = states.takeProvisional(tokens, from: lines.lowerBound)
            if !changed.isEmpty { onChange?(changed) }
        }
    }
}
