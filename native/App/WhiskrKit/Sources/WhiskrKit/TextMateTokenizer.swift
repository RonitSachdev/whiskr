import Foundation
import Synchronization

// Tokenizing a line with a TextMate grammar, translated from vscode-textmate's grammar/tokenizeString.ts
// and grammar/grammar.ts (StateStackImpl, LineTokens) (MIT, Copyright (c) Microsoft Corporation): the same
// search for the earliest match among the current rule's patterns and the injections, the same captures,
// the same protections against a grammar that loops without advancing, and the same line state.

/// What a line leaves open for the next: the rules entered and not yet ended, innermost on top, with
/// their scopes. Immutable and shared: lines whose states are the same hold the same objects, and an
/// edit compares the state a line now ends in with the one it ended in before, to stop re-tokenizing
/// (`SyntaxStates`). Equality is VS Code's: the same rules, the same back-referenced ends, the same scopes.
public final class StateStack: Sendable, Equatable {
    let parent: StateStack?
    let ruleID: Int
    let depth: Int
    /// Where on its line it was entered, and the anchor position then; meaningful only on the line being
    /// tokenized (`line`), -1 on any later line.
    private let enterPosition: Int
    private let anchorPosition: Int
    private let line: UInt64
    /// The region's `begin` matched up to the line's end: `\G` holds at the start of the next line.
    let beginRuleCapturedEOL: Bool
    /// The region's `end` (or `while`) with the `begin`'s captures filled in.
    let endRule: String?
    /// The scopes up to and including this rule's name.
    let nameScopes: ScopeStack
    /// … and its content name: what text inside the region is in.
    public let contentScopes: ScopeStack

    init(parent: StateStack?, ruleID: Int, enterPosition: Int, anchorPosition: Int, line: UInt64, beginRuleCapturedEOL: Bool,
         endRule: String?, nameScopes: ScopeStack, contentScopes: ScopeStack) {
        self.parent = parent
        self.ruleID = ruleID
        depth = (parent?.depth ?? 0) + 1
        self.enterPosition = enterPosition
        self.anchorPosition = anchorPosition
        self.line = line
        self.beginRuleCapturedEOL = beginRuleCapturedEOL
        self.endRule = endRule
        self.nameScopes = nameScopes
        self.contentScopes = contentScopes
    }

    public static func == (a: StateStack, b: StateStack) -> Bool {
        if a === b { return true }
        guard a.contentScopes == b.contentScopes else { return false }
        var x: StateStack? = a, y: StateStack? = b
        while let left = x, let right = y {
            if left === right { return true }
            guard left.depth == right.depth, left.ruleID == right.ruleID, left.endRule == right.endRule else { return false }
            x = left.parent
            y = right.parent
        }
        return x == nil && y == nil
    }

    func enterPosition(onLine current: UInt64) -> Int { line == current ? enterPosition : -1 }
    func anchorPosition(onLine current: UInt64) -> Int { line == current ? anchorPosition : -1 }

    func push(ruleID: Int, enterPosition: Int, anchorPosition: Int, line: UInt64, beginRuleCapturedEOL: Bool, endRule: String?,
              nameScopes: ScopeStack, contentScopes: ScopeStack) -> StateStack {
        StateStack(parent: self, ruleID: ruleID, enterPosition: enterPosition, anchorPosition: anchorPosition, line: line,
                   beginRuleCapturedEOL: beginRuleCapturedEOL, endRule: endRule, nameScopes: nameScopes, contentScopes: contentScopes)
    }

    func with(contentScopes: ScopeStack) -> StateStack {
        guard contentScopes != self.contentScopes else { return self }
        return StateStack(parent: parent, ruleID: ruleID, enterPosition: enterPosition, anchorPosition: anchorPosition, line: line,
                          beginRuleCapturedEOL: beginRuleCapturedEOL, endRule: endRule, nameScopes: nameScopes, contentScopes: contentScopes)
    }

    func with(endRule: String) -> StateStack {
        guard endRule != self.endRule else { return self }
        return StateStack(parent: parent, ruleID: ruleID, enterPosition: enterPosition, anchorPosition: anchorPosition, line: line,
                          beginRuleCapturedEOL: beginRuleCapturedEOL, endRule: endRule, nameScopes: nameScopes, contentScopes: contentScopes)
    }

    var safeParent: StateStack { parent ?? self }

    /// The same rule entered at the same place further down: a grammar going round without advancing.
    func hasSameRule(as other: StateStack, onLine current: UInt64) -> Bool {
        var element: StateStack? = self
        let enter = other.enterPosition(onLine: current)
        while let node = element, node.enterPosition(onLine: current) == enter {
            if node.ruleID == other.ruleID { return true }
            element = node.parent
        }
        return false
    }
}

/// A run of a line's text and the scopes it is in. Offsets are UTF-16 units within the line.
public struct SyntaxToken: Equatable, Sendable {
    private var start: UInt32
    private var end: UInt32
    public var scopes: ScopeStack

    public init(range: Range<Int>, scopes: ScopeStack) {
        start = UInt32(range.lowerBound)
        end = UInt32(range.upperBound)
        self.scopes = scopes
    }

    public var range: Range<Int> { Int(start)..<Int(end) }
}

/// A line's tokens and the state it ends in.
public struct TokenizedLine: Sendable {
    /// Cover the whole line, in order.
    public var tokens: [SyntaxToken]
    public var end: StateStack
    /// The line was longer than `TextMateTokenizer.lineLimit` or took longer than the time allowed: it is
    /// shown plain (or coloured as far as it got), and the next line starts in the state this one did.
    public var stoppedEarly: Bool
}

/// Tokenizes lines with a grammar, one line at a time from any thread (a lock keeps the compiled
/// expressions to one line at once). One per language is shared by every document (`GrammarStore`), so
/// the expressions the background has compiled are ready when the main thread tokenizes an edit, which
/// waits at most a moment for a line under way elsewhere (`tokenize(…waitingAtMost:)`).
public final class TextMateTokenizer: @unchecked Sendable {
    public let grammar: TextMateGrammar

    /// Lines longer than this are not tokenized (VS Code's `editor.maxTokenizationLineLength`): a minified
    /// file's one line is shown plain, and the state carries over.
    public static let lineLimit = 20_000

    private var scanners: [Int: ScannerSet] = [:]
    private var whileScanners: [Int: ScannerSet] = [:]
    private var injectionMatches: [UInt64: Bool] = [:]
    private var scopeCache: [ScopeKey: ScopeStack] = [:]
    /// The line being tokenized, numbered across every tokenizer: rules entered on it know their
    /// positions, rules entered on any earlier line (a state from another thread included) do not.
    private var lineCounter: UInt64 = 0
    private static let lines = Atomic<UInt64>(0)
    private var stringCounter = 0
    public let rootScopes: ScopeStack

    private struct ScopeKey: Hashable {
        var parent: UInt32
        var name: String
    }

    /// A rule's patterns as expressions, and their compiled forms: one, or four when an expression uses
    /// `\A` or `\G` (each anchor kept or switched off), made as they are first needed.
    private final class ScannerSet {
        var sources: [RegexSource]
        /// Where the back-referenced end (or while) is, and the expression it was last made with.
        let endIndex: Int?
        var endSource: String?
        private var hasAnchors: Bool
        private var variants: [CompiledRule?] = [nil, nil, nil, nil]

        init(sources: [RegexSource], endIndex: Int?) {
            self.sources = sources
            self.endIndex = endIndex
            hasAnchors = sources.contains { $0.hasAnchor }
        }

        func reset() {
            variants = [nil, nil, nil, nil]
            hasAnchors = sources.contains { $0.hasAnchor }
        }

        func compiled(allowA: Bool, allowG: Bool) -> CompiledRule {
            let slot = hasAnchors ? (allowA ? 2 : 0) + (allowG ? 1 : 0) : 0
            if let made = variants[slot] { return made }
            let made = CompiledRule(scanner: RegexScanner(sources: sources.map { $0.resolvingAnchors(allowA: allowA, allowG: allowG) }), ruleIDs: sources.map(\.ruleID))
            variants[slot] = made
            return made
        }
    }

    struct CompiledRule {
        let scanner: RegexScanner
        let ruleIDs: [Int]

        func findNextMatch(_ line: RegexLine, _ position: Int) -> (ruleID: Int, captures: [CaptureRange])? {
            guard let match = scanner.findNextMatch(line, from: position) else { return nil }
            return (ruleIDs[match.index], match.captures)
        }
    }

    private let lock = NSLock()

    public init(grammar: TextMateGrammar) {
        self.grammar = grammar
        let root = grammar.rule(grammar.rootRuleID)
        rootScopes = ScopeStack.root(root.name?.text ?? "unknown")
    }

    /// The state the first line starts in.
    public var initialState: StateStack {
        StateStack(parent: nil, ruleID: grammar.rootRuleID, enterPosition: -1, anchorPosition: -1, line: 0, beginRuleCapturedEOL: false,
                   endRule: nil, nameScopes: rootScopes, contentScopes: rootScopes)
    }

    /// One line, without its line break. `state` is the previous line's end, nil for the first line.
    /// `timeLimit` (in seconds) stops a line that takes longer, as `stoppedEarly`.
    public func tokenize(_ text: String, state: StateStack?, timeLimit: Double? = nil) -> TokenizedLine {
        var units = Array(text.utf16)
        units.append(0x0A)
        return tokenize(units: units, state: state, timeLimit: timeLimit)
    }

    /// One line as UTF-16 units, which must end in "\n" (the line's own break, or one added).
    public func tokenize(units: [UInt16], state: StateStack?, timeLimit: Double? = nil) -> TokenizedLine {
        lock.lock()
        defer { lock.unlock() }
        return tokenizeLocked(units: units, state: state, timeLimit: timeLimit)
    }

    /// As `tokenize(units:state:timeLimit:)`, but nil when another thread's line has not finished within
    /// `wait` seconds (the main thread hands the line to the background instead of waiting).
    public func tokenize(units: [UInt16], state: StateStack?, timeLimit: Double?, waitingAtMost wait: Double) -> TokenizedLine? {
        guard lock.lock(before: Date(timeIntervalSinceNow: wait)) else { return nil }
        defer { lock.unlock() }
        return tokenizeLocked(units: units, state: state, timeLimit: timeLimit)
    }

    private func tokenizeLocked(units: [UInt16], state: StateStack?, timeLimit: Double?) -> TokenizedLine {
        let isFirstLine = state == nil
        let start = state ?? initialState
        let length = units.count - 1
        guard length <= Self.lineLimit else {
            return TokenizedLine(tokens: length > 0 ? [SyntaxToken(range: 0..<length, scopes: rootScopes)] : [], end: start, stoppedEarly: true)
        }
        lineCounter = Self.lines.add(1, ordering: .relaxed).newValue
        let line = RegexLine(units: units, id: nextStringID())
        var tokens = LineTokens()
        let deadline = timeLimit.map { DispatchTime.now().uptimeNanoseconds + UInt64($0 * 1e9) }
        let result = tokenizeString(line, isFirstLine: isFirstLine, position: 0, stack: start, tokens: &tokens, checkWhile: true, deadline: deadline)
        var list = tokens.finish(lineLength: units.count, stack: result.stack)
        if result.stoppedEarly {
            // What is left of the line in the scopes it had reached; the next line starts as this one did.
            let reached = list.last?.range.upperBound ?? 0
            if reached < length { list.append(SyntaxToken(range: reached..<length, scopes: result.stack.contentScopes)) }
            return TokenizedLine(tokens: list, end: start, stoppedEarly: true)
        }
        return TokenizedLine(tokens: list, end: result.stack, stoppedEarly: false)
    }

    private func nextStringID() -> Int {
        stringCounter += 1
        return stringCounter
    }

    // MARK: Scopes

    /// `scopes` with each of a space-separated `name`'s scopes inside it.
    private func push(_ scopes: ScopeStack, _ name: String?) -> ScopeStack {
        guard let name, !name.isEmpty else { return scopes }
        var result = scopes
        for part in name.split(separator: " ") {
            let key = ScopeKey(parent: result.id, name: String(part))
            if let cached = scopeCache[key] {
                result = cached
            } else {
                let made = result.pushing(key.name)
                scopeCache[key] = made
                result = made
            }
        }
        return result
    }

    // MARK: Scanning

    private struct Scan {
        var stack: StateStack
        var stoppedEarly: Bool
    }

    private func tokenizeString(_ line: RegexLine, isFirstLine firstLine: Bool, position start: Int, stack initial: StateStack, tokens: inout LineTokens,
                                checkWhile: Bool, deadline: UInt64?) -> Scan {
        let lineLength = line.count
        let current = lineCounter
        var stack = initial
        var position = start
        var isFirstLine = firstLine
        var anchorPosition = -1

        if checkWhile {
            let result = checkWhileConditions(line, isFirstLine: isFirstLine, position: position, stack: stack, tokens: &tokens)
            stack = result.stack
            position = result.position
            isFirstLine = result.isFirstLine
            anchorPosition = result.anchorPosition
        }

        while true {
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { return Scan(stack: stack, stoppedEarly: true) }

            guard let match = matchRuleOrInjections(line, isFirstLine: isFirstLine, position: position, stack: stack, anchorPosition: anchorPosition) else {
                tokens.produce(stack.contentScopes, lineLength)
                return Scan(stack: stack, stoppedEarly: false)
            }
            let captures = match.captures
            let hasAdvanced = !captures.isEmpty && captures[0].end > position

            if match.ruleID == RegexSource.endRuleID {
                // The region's end: leave it.
                guard case .beginEnd(_, _, _, let endCaptures, _, _) = grammar.rule(stack.ruleID).kind else { break }
                tokens.produce(stack.contentScopes, captures[0].start)
                stack = stack.with(contentScopes: stack.nameScopes)
                handleCaptures(line, isFirstLine: isFirstLine, stack: stack, tokens: &tokens, captures: endCaptures, indices: captures)
                tokens.produce(stack.contentScopes, captures[0].end)

                let popped = stack
                stack = stack.parent ?? stack
                anchorPosition = popped.anchorPosition(onLine: current)

                if !hasAdvanced && popped.enterPosition(onLine: current) == position {
                    // Entered and left without advancing: carry on in the region, as its author meant.
                    stack = popped
                    tokens.produce(stack.contentScopes, lineLength)
                    return Scan(stack: stack, stoppedEarly: false)
                }
            } else {
                let rule = grammar.rule(match.ruleID)
                tokens.produce(stack.contentScopes, captures[0].start)
                let beforePush = stack
                let nameScopes = push(stack.contentScopes, rule.name?.resolve(line, captures))
                stack = stack.push(ruleID: match.ruleID, enterPosition: position, anchorPosition: anchorPosition, line: current,
                                   beginRuleCapturedEOL: captures[0].end == lineLength, endRule: nil, nameScopes: nameScopes, contentScopes: nameScopes)

                switch rule.kind {
                case .beginEnd(_, let beginCaptures, let end, _, _, _):
                    handleCaptures(line, isFirstLine: isFirstLine, stack: stack, tokens: &tokens, captures: beginCaptures, indices: captures)
                    tokens.produce(stack.contentScopes, captures[0].end)
                    anchorPosition = captures[0].end
                    stack = stack.with(contentScopes: push(nameScopes, rule.contentName?.resolve(line, captures)))
                    if end.hasBackReferences { stack = stack.with(endRule: end.resolvingBackReferences(line, captures)) }
                    if !hasAdvanced && beforePush.hasSameRule(as: stack, onLine: current) {
                        // The same region entered again without advancing.
                        stack = stack.parent ?? stack
                        tokens.produce(stack.contentScopes, lineLength)
                        return Scan(stack: stack, stoppedEarly: false)
                    }
                case .beginWhile(_, let beginCaptures, let whileSource, _, _):
                    handleCaptures(line, isFirstLine: isFirstLine, stack: stack, tokens: &tokens, captures: beginCaptures, indices: captures)
                    tokens.produce(stack.contentScopes, captures[0].end)
                    anchorPosition = captures[0].end
                    stack = stack.with(contentScopes: push(nameScopes, rule.contentName?.resolve(line, captures)))
                    if whileSource.hasBackReferences { stack = stack.with(endRule: whileSource.resolvingBackReferences(line, captures)) }
                    if !hasAdvanced && beforePush.hasSameRule(as: stack, onLine: current) {
                        stack = stack.parent ?? stack
                        tokens.produce(stack.contentScopes, lineLength)
                        return Scan(stack: stack, stoppedEarly: false)
                    }
                default:
                    if case .match(_, let matchCaptures) = rule.kind {
                        handleCaptures(line, isFirstLine: isFirstLine, stack: stack, tokens: &tokens, captures: matchCaptures, indices: captures)
                    }
                    tokens.produce(stack.contentScopes, captures[0].end)
                    // A match is left at once.
                    stack = stack.parent ?? stack
                    if !hasAdvanced {
                        // Matching without advancing, entering or leaving anything: stop the line here.
                        stack = stack.safeParent
                        tokens.produce(stack.contentScopes, lineLength)
                        return Scan(stack: stack, stoppedEarly: false)
                    }
                }
            }

            if captures[0].end > position {
                position = captures[0].end
                isFirstLine = false
            }
        }
        tokens.produce(stack.contentScopes, lineLength)
        return Scan(stack: stack, stoppedEarly: false)
    }

    private struct WhileResult {
        var stack: StateStack
        var position: Int
        var anchorPosition: Int
        var isFirstLine: Bool
    }

    /// From the bottom of the stack up, each `while` region must match at the line's start, or it and
    /// everything above it ends. A `while` may consume text.
    private func checkWhileConditions(_ line: RegexLine, isFirstLine firstLine: Bool, position start: Int, stack initial: StateStack, tokens: inout LineTokens) -> WhileResult {
        var stack = initial
        var position = start
        var isFirstLine = firstLine
        var anchorPosition = stack.beginRuleCapturedEOL ? 0 : -1

        var whiles: [StateStack] = []
        var node: StateStack? = stack
        while let element = node {
            if case .beginWhile = grammar.rule(element.ruleID).kind { whiles.append(element) }
            node = element.parent
        }
        while let element = whiles.popLast() {
            guard case .beginWhile(_, _, _, let whileCaptures, _) = grammar.rule(element.ruleID).kind else { continue }
            let scanner = compiledWhile(element.ruleID, endSource: element.endRule, allowA: isFirstLine, allowG: position == anchorPosition)
            guard let match = scanner.findNextMatch(line, position) else {
                stack = element.parent ?? element
                break
            }
            guard match.ruleID == RegexSource.whileRuleID else {
                stack = element.parent ?? element
                break
            }
            let captures = match.captures
            if !captures.isEmpty {
                tokens.produce(element.contentScopes, captures[0].start)
                handleCaptures(line, isFirstLine: isFirstLine, stack: element, tokens: &tokens, captures: whileCaptures, indices: captures)
                tokens.produce(element.contentScopes, captures[0].end)
                anchorPosition = captures[0].end
                if captures[0].end > position {
                    position = captures[0].end
                    isFirstLine = false
                }
            }
        }
        return WhileResult(stack: stack, position: position, anchorPosition: anchorPosition, isFirstLine: isFirstLine)
    }

    private func matchRuleOrInjections(_ line: RegexLine, isFirstLine: Bool, position: Int, stack: StateStack, anchorPosition: Int) -> (ruleID: Int, captures: [CaptureRange])? {
        let compiled = compiled(stack.ruleID, endSource: stack.endRule, allowA: isFirstLine, allowG: position == anchorPosition)
        let own = compiled.findNextMatch(line, position)
        guard !grammar.injections.isEmpty else { return own }
        guard let injected = matchInjections(line, isFirstLine: isFirstLine, position: position, stack: stack, anchorPosition: anchorPosition) else { return own }
        guard let own else { return (injected.ruleID, injected.captures) }
        let ownStart = own.captures[0].start, injectedStart = injected.captures[0].start
        if injectedStart < ownStart || (injected.priority && injectedStart == ownStart) { return (injected.ruleID, injected.captures) }
        return own
    }

    private func matchInjections(_ line: RegexLine, isFirstLine: Bool, position: Int, stack: StateStack, anchorPosition: Int) -> (ruleID: Int, captures: [CaptureRange], priority: Bool)? {
        var best: (ruleID: Int, captures: [CaptureRange], priority: Bool)?
        var bestStart = Int.max
        var scopes: [String]?
        for (index, injection) in grammar.injections.enumerated() {
            let key = UInt64(stack.contentScopes.id) << 16 | UInt64(index)
            let applies: Bool
            if let known = injectionMatches[key] {
                applies = known
            } else {
                if scopes == nil { scopes = stack.contentScopes.scopes }
                applies = injection.selector.matches(scopes!)
                injectionMatches[key] = applies
            }
            guard applies else { continue }
            let compiled = compiled(injection.ruleID, endSource: nil, allowA: isFirstLine, allowG: position == anchorPosition)
            guard let match = compiled.findNextMatch(line, position) else { continue }
            let start = match.captures[0].start
            // Injections are in priority order: an earlier one with the same start wins.
            guard start < bestStart else { continue }
            bestStart = start
            best = (match.ruleID, match.captures, injection.priority == -1)
            if start == position { break }
        }
        return best
    }

    // MARK: Captures

    private func handleCaptures(_ line: RegexLine, isFirstLine: Bool, stack: StateStack, tokens: inout LineTokens, captures: [Rule?], indices: [CaptureRange]) {
        guard !captures.isEmpty else { return }
        let count = min(captures.count, indices.count)
        var local: [(scopes: ScopeStack, end: Int)] = []
        let maxEnd = indices[0].end

        for index in 0..<count {
            guard let capture = captures[index] else { continue }
            let range = indices[index]
            if range.length == 0 { continue }
            if range.start > maxEnd { break }

            while let last = local.last, last.end <= range.start {
                tokens.produce(last.scopes, last.end)
                local.removeLast()
            }
            if let last = local.last {
                tokens.produce(last.scopes, range.start)
            } else {
                tokens.produce(stack.contentScopes, range.start)
            }

            if case .capture(let retokenize?) = capture.kind {
                // The captured text is tokenized again, with the capture's own patterns.
                let nameScopes = push(stack.contentScopes, capture.name?.resolve(line, indices))
                let contentScopes = push(nameScopes, capture.contentName?.resolve(line, indices))
                let inner = stack.push(ruleID: retokenize, enterPosition: range.start, anchorPosition: -1, line: lineCounter, beginRuleCapturedEOL: false,
                                       endRule: nil, nameScopes: nameScopes, contentScopes: contentScopes)
                let substring = RegexLine(prefixOf: line, length: range.end, id: nextStringID())
                _ = tokenizeString(substring, isFirstLine: isFirstLine && range.start == 0, position: range.start, stack: inner, tokens: &tokens,
                                   checkWhile: false, deadline: nil)
                continue
            }

            if let name = capture.name?.resolve(line, indices) {
                let base = local.last?.scopes ?? stack.contentScopes
                local.append((push(base, name), range.end))
            }
        }

        while let last = local.popLast() {
            tokens.produce(last.scopes, last.end)
        }
    }

    // MARK: Compiled patterns

    /// The patterns searched inside rule `ruleID` (with its end, for a region), compiled the first time.
    private func compiled(_ ruleID: Int, endSource: String?, allowA: Bool, allowG: Bool) -> CompiledRule {
        let set: ScannerSet
        if let known = scanners[ruleID] {
            set = known
        } else {
            let rule = grammar.rule(ruleID)
            var sources = patternSources(rule)
            var endIndex: Int?
            var endHasBackReferences = false
            if case .beginEnd(_, _, let end, _, let last, _) = rule.kind {
                if last { sources.append(end) } else { sources.insert(end, at: 0) }
                endIndex = last ? sources.count - 1 : 0
                endHasBackReferences = end.hasBackReferences
            }
            set = ScannerSet(sources: sources, endIndex: endHasBackReferences ? endIndex : nil)
            scanners[ruleID] = set
        }
        if let endIndex = set.endIndex {
            // The end is made from what the region's begin captured: compiled again when that differs.
            let source = endSource ?? set.sources[endIndex].source
            if set.endSource != source {
                set.endSource = source
                set.sources[endIndex] = RegexSource(source, ruleID: RegexSource.endRuleID)
                set.reset()
            }
        }
        return set.compiled(allowA: allowA, allowG: allowG)
    }

    private func compiledWhile(_ ruleID: Int, endSource: String?, allowA: Bool, allowG: Bool) -> CompiledRule {
        let set: ScannerSet
        if let known = whileScanners[ruleID] {
            set = known
        } else {
            guard case .beginWhile(_, _, let whileSource, _, _) = grammar.rule(ruleID).kind else { preconditionFailure("not a while rule") }
            set = ScannerSet(sources: [whileSource], endIndex: whileSource.hasBackReferences ? 0 : nil)
            whileScanners[ruleID] = set
        }
        if set.endIndex != nil {
            let source = endSource ?? "\u{FFFF}"
            if set.endSource != source {
                set.endSource = source
                set.sources[0] = RegexSource(source, ruleID: RegexSource.whileRuleID)
                set.reset()
            }
        }
        return set.compiled(allowA: allowA, allowG: allowG)
    }

    /// The expressions a rule's patterns contribute, in order (each include followed).
    private var collected: [Int: [RegexSource]] = [:]

    private func patternSources(_ rule: Rule) -> [RegexSource] {
        if let known = collected[rule.id] { return known }
        var result: [RegexSource] = []
        var visiting: Set<Int> = []
        func collect(_ id: Int) {
            let rule = grammar.rule(id)
            switch rule.kind {
            case .match(let source, _): result.append(source)
            case .beginEnd(let begin, _, _, _, _, _), .beginWhile(let begin, _, _, _, _): result.append(begin)
            case .includeOnly(let patterns):
                // An include that leads back to itself adds nothing more.
                guard visiting.insert(id).inserted else { return }
                patterns.forEach(collect)
                visiting.remove(id)
            case .capture: break
            }
        }
        switch rule.kind {
        case .match(let source, _): result = [source]
        case .includeOnly(let patterns), .beginEnd(_, _, _, _, _, let patterns), .beginWhile(_, _, _, _, let patterns):
            visiting.insert(rule.id)
            patterns.forEach(collect)
        case .capture: break
        }
        collected[rule.id] = result
        return result
    }
}

/// A line's tokens as they are produced: each `produce` ends the current run at an offset, in the scopes
/// it was in; runs in the same scopes as the one before join it.
private struct LineTokens {
    private(set) var tokens: [SyntaxToken] = []
    private var lastEnd = 0

    mutating func produce(_ scopes: ScopeStack, _ end: Int) {
        guard lastEnd < end else { return }
        if let last = tokens.last, last.scopes == scopes {
            tokens[tokens.count - 1] = SyntaxToken(range: last.range.lowerBound..<end, scopes: scopes)
        } else {
            tokens.append(SyntaxToken(range: lastEnd..<end, scopes: scopes))
        }
        lastEnd = end
    }

    /// The tokens without the line break; a line with none gets one in the state's scopes.
    mutating func finish(lineLength: Int, stack: StateStack) -> [SyntaxToken] {
        let textLength = lineLength - 1
        var result: [SyntaxToken] = []
        result.reserveCapacity(tokens.count)
        for token in tokens {
            let upper = min(token.range.upperBound, textLength)
            if upper > token.range.lowerBound { result.append(SyntaxToken(range: token.range.lowerBound..<upper, scopes: token.scopes)) }
        }
        if result.isEmpty && textLength > 0 { result.append(SyntaxToken(range: 0..<textLength, scopes: stack.contentScopes)) }
        return result
    }
}
