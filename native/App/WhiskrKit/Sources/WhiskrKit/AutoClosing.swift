import Foundation

/// Where in a line's tokens a position is, as far as pairs care (VS Code's `notIn`: "string", "comment",
/// "regex").
public enum TokenContext: String, Sendable, Hashable, CaseIterable {
    case code, string, comment, regex
}

/// A language's brackets and quotes as the editor's typing uses them, in the shape of a VS Code language
/// configuration (`brackets`, `autoClosingPairs` with `notIn`, `surroundingPairs`, `autoCloseBefore`).
public struct EditingPairs: Sendable, Equatable {
    public struct Pair: Sendable, Hashable {
        public var open: String
        public var close: String
        public init(_ open: String, _ close: String) {
            self.open = open
            self.close = close
        }
    }

    public struct AutoClosingPair: Sendable, Hashable {
        public var open: String
        public var close: String
        /// Where typing the opening does not add the closing.
        public var notIn: Set<TokenContext>
        public init(_ open: String, _ close: String, notIn: Set<TokenContext> = []) {
            self.open = open
            self.close = close
            self.notIn = notIn
        }
    }

    /// What bracket matching pairs up.
    public var brackets: [Pair]
    public var autoClosingPairs: [AutoClosingPair]
    /// What a typed opening wraps a selection in.
    public var surroundingPairs: [Pair]
    /// The characters before which a pair is closed; nil takes VS Code's defaults.
    public var autoCloseBefore: String?

    /// As VS Code reads a configuration: auto-closing pairs default to the brackets, surrounding pairs to
    /// the auto-closing pairs.
    public init(brackets: [Pair], autoClosingPairs: [AutoClosingPair]? = nil, surroundingPairs: [Pair]? = nil, autoCloseBefore: String? = nil) {
        self.brackets = brackets
        let closing = autoClosingPairs ?? brackets.map { AutoClosingPair($0.open, $0.close) }
        self.autoClosingPairs = closing
        self.surroundingPairs = surroundingPairs ?? closing.map { Pair($0.open, $0.close) }
        self.autoCloseBefore = autoCloseBefore
    }

    /// No pairs at all (plain text, as in VS Code).
    public static let none = EditingPairs(brackets: [])

    /// The pairs most languages' configurations give: three brackets, and quotes that do not close inside a
    /// string or comment.
    public static let common = EditingPairs(
        brackets: [Pair("{", "}"), Pair("[", "]"), Pair("(", ")")],
        autoClosingPairs: [
            AutoClosingPair("{", "}"), AutoClosingPair("[", "]"), AutoClosingPair("(", ")"),
            AutoClosingPair("\"", "\"", notIn: [.string]), AutoClosingPair("'", "'", notIn: [.string, .comment]),
        ])

    /// VS Code's characters before which a pair closes when the language does not say
    /// (`CharacterPairSupport.DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_*`).
    static let defaultBeforeQuotes = ";:.,=}])> \n\t"
    static let defaultBeforeBrackets = "'\"`;:.,=}])> \n\t"

    func autoCloseBefore(forQuote: Bool) -> String {
        autoCloseBefore ?? (forQuote ? Self.defaultBeforeQuotes : Self.defaultBeforeBrackets)
    }
}

/// What typing does around pairs, with VS Code's rules (`editor.autoClosingBrackets` and
/// `autoClosingQuotes` "languageDefined", `autoClosingOvertype` and `autoClosingDelete` "auto",
/// `autoSurround` "languageDefined"; the behaviour of `cursorTypeEditOperations.ts` and
/// `cursorDeleteOperations.ts` in microsoft/vscode, MIT):
///
/// - An opening bracket or quote adds its closing one when the cursor is at the end of the line, before
///   whitespace or one of the language's `autoCloseBefore` characters, or before another pair's closing;
///   not where the language's `notIn` says (a quote in a string or comment), not a quote right after a
///   word character (`don't`), and not a bracket when the line already has a closing one with no opening.
/// - Typing a closing character that the editor itself put there steps over it.
/// - Backspace between an empty pair the editor closed deletes both.
/// - With text selected, an opening bracket or quote wraps the selection.
public enum AutoClosing {
    /// What typing a character does instead of inserting it.
    public enum Typing: Equatable, Sendable {
        /// Step over the closing character after the cursor.
        case overtype
        /// Insert `open` and, after the cursor, `close` (remembered as put there by the editor).
        case close(open: String, close: String)
        /// Wrap the selection, which stays on the text inside.
        case surround(open: String, close: String)
    }

    /// The cursor's surroundings.
    public struct Place: Sendable {
        /// The line's text before the cursor (or the selection).
        public var before: String
        /// The line's text after the cursor (or the selection), without the line break.
        public var after: String
        /// The selected text; empty when nothing is selected.
        public var selected: String
        /// Whether the character after the cursor is a closing the editor put there and the cursor has stayed
        /// inside its pair since.
        public var closerWasAdded: Bool
        /// Where the cursor is: in code, a string, a comment.
        public var context: TokenContext

        public init(before: String, after: String, selected: String = "", closerWasAdded: Bool = false, context: TokenContext = .code) {
            self.before = before
            self.after = after
            self.selected = selected
            self.closerWasAdded = closerWasAdded
            self.context = context
        }
    }

    static func isQuote(_ text: String) -> Bool { text == "\"" || text == "'" || text == "`" }

    /// What typing `typed` (one character) does at `place`; nil when it is just inserted.
    public static func typing(_ typed: String, at place: Place, pairs: EditingPairs) -> Typing? {
        guard typed.count == 1 else { return nil }
        if place.selected.isEmpty {
            if overtypes(typed, at: place, pairs: pairs) { return .overtype }
            if let pair = closingPair(for: typed, at: place, pairs: pairs) { return .close(open: typed, close: pair.close) }
            return nil
        }
        return surround(typed, selected: place.selected, pairs: pairs).map { .surround(open: typed, close: $0) }
    }

    /// A closing character the editor added, typed again right before it: step over it (not a quote after a
    /// backslash, which escapes it).
    static func overtypes(_ typed: String, at place: Place, pairs: EditingPairs) -> Bool {
        guard place.closerWasAdded, place.after.hasPrefix(typed),
              pairs.autoClosingPairs.contains(where: { $0.close == typed }) else { return false }
        if isQuote(typed), place.before.hasSuffix("\\") { return false }
        return true
    }

    /// The pair whose opening `typed` completes, if it should be closed here (the longest such opening, so
    /// `/**` wins over a shorter one ending in `*`).
    static func closingPair(for typed: String, at place: Place, pairs: EditingPairs) -> EditingPairs.AutoClosingPair? {
        let candidates = pairs.autoClosingPairs.filter { $0.open.hasSuffix(typed) && (place.before + typed).hasSuffix($0.open) }
        guard let pair = candidates.max(by: { $0.open.count < $1.open.count }) else { return nil }
        if pair.notIn.contains(place.context) { return nil }
        let quote = isQuote(typed)
        // Only before whitespace, the language's characters, or another pair's closing.
        if let next = place.after.first {
            let allowed = pairs.autoCloseBefore(forQuote: quote)
            if !allowed.contains(next) && !isBeforeClosing(place.after, pairs: pairs) { return nil }
        }
        // Not a quote straight after a word character (`don't`).
        if pair.open.count == 1, typed == "'" || typed == "\"",
           let last = place.before.utf16.last, Occurrences.isWordCharacter(last) { return nil }
        // A bracket whose closing the line already has, unmatched: typing it completes that pair.
        if !quote, pairs.brackets.contains(where: { $0.open == pair.open }),
           hasUnmatchedClosing(after: place.before, place.after, pair: pair) { return nil }
        return pair
    }

    /// The text after the cursor starts with a pair's closing and not with an opening (VS Code's
    /// `_isBeforeClosingBrace`).
    static func isBeforeClosing(_ after: String, pairs: EditingPairs) -> Bool {
        let opens = pairs.autoClosingPairs.contains { after.hasPrefix($0.open) }
        let closes = pairs.autoClosingPairs.contains { after.hasPrefix($0.close) }
        return closes && !opens
    }

    /// Whether, in this line, a `pair.close` after the cursor has no opening before it. (VS Code asks its
    /// bracket tree about the whole file; within the line is what matters while typing.)
    static func hasUnmatchedClosing(after before: String, _ after: String, pair: EditingPairs.AutoClosingPair) -> Bool {
        let open = Array(pair.open.utf16), close = Array(pair.close.utf16)
        // An empty side would match everywhere without moving on.
        guard !open.isEmpty, !close.isEmpty else { return false }
        let text = Array((before + after).utf16)
        let cursor = before.utf16.count
        var depth = 0
        var index = 0
        while index < text.count {
            if text[index...].starts(with: open) {
                depth += 1
                index += open.count
            } else if text[index...].starts(with: close) {
                if depth == 0, index >= cursor { return true }
                depth = max(0, depth - 1)
                index += close.count
            } else {
                index += 1
            }
        }
        return false
    }

    /// The closing that wraps a selection when `typed` is a surrounding pair's opening; not for a selection
    /// of only whitespace, nor a quote typed over a single quote.
    static func surround(_ typed: String, selected: String, pairs: EditingPairs) -> String? {
        guard let pair = pairs.surroundingPairs.first(where: { $0.open == typed }) else { return nil }
        guard selected.contains(where: { $0 != " " && $0 != "\t" && $0 != "\n" }) else { return nil }
        if isQuote(typed), isQuote(selected) { return nil }
        return pair.close
    }

    /// Backspace right after an opening whose closing the editor added right after the cursor: both go.
    public static func deletesPair(at place: Place, pairs: EditingPairs) -> Bool {
        guard place.selected.isEmpty, place.closerWasAdded, let open = place.before.last, let close = place.after.first else { return false }
        return pairs.autoClosingPairs.contains { $0.open == String(open) && $0.close == String(close) }
    }

    /// Closings the editor added, followed through edits: each is forgotten once an edit touches its pair
    /// or the cursor leaves it (VS Code's `AutoClosedAction`).
    public struct Added: Sendable, Equatable {
        /// Each pair's opening and closing offsets (UTF-16).
        public private(set) var pairs: [(open: Int, close: Int)] = []

        public init() {}

        public static func == (lhs: Added, rhs: Added) -> Bool {
            lhs.pairs.map(\.open) == rhs.pairs.map(\.open) && lhs.pairs.map(\.close) == rhs.pairs.map(\.close)
        }

        public mutating func add(open: Int, close: Int) {
            pairs.append((open, close))
        }

        public mutating func removeAll() { pairs.removeAll() }

        /// `range` was replaced by `length` characters: pairs after it move, a pair it touches is forgotten.
        public mutating func edited(_ range: NSRange, replacementLength length: Int) {
            let delta = length - range.length
            let end = range.location + range.length
            pairs = pairs.compactMap { pair in
                if end <= pair.open { return (pair.open + delta, pair.close + delta) }
                // Typing between the opening and the closing: the closing moves.
                if range.location > pair.open, end <= pair.close { return (pair.open, pair.close + delta) }
                if range.location > pair.close { return pair }
                return nil
            }
        }

        /// Keeps the pairs the selection is still inside of (after the opening, at or before the closing).
        public mutating func keep(inside selection: NSRange) {
            pairs.removeAll { selection.location <= $0.open || selection.location + selection.length > $0.close }
        }

        /// Whether the editor added the closing at `offset`, with the cursor still inside its pair.
        public func isClosing(at offset: Int) -> Bool {
            pairs.contains { $0.close == offset }
        }
    }
}
