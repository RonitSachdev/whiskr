import Foundation

/// The bracket at the cursor and its partner, as VS Code's bracket matching finds them: a bracket right
/// after the cursor first, else the one right before it; brackets in strings and comments are neither
/// matched nor counted. Single-character brackets only (the ones every language's configuration has).
public enum BracketMatching {
    public struct Match: Equatable, Sendable {
        /// The opening and the closing bracket's offsets (UTF-16).
        public var open: Int
        public var close: Int
        public init(open: Int, close: Int) {
            self.open = open
            self.close = close
        }
    }

    /// The pair touching `offset` (an unmatched bracket after the cursor gives way to a matched one before
    /// it), or nil when there is none, it is unmatched, or the search goes further
    /// than `limit` characters. `isCode` says whether a character's offset is outside strings and comments.
    public static func match(in text: NSString, at offset: Int, brackets: [EditingPairs.Pair], limit: Int = 200_000,
                             isCode: (Int) -> Bool = { _ in true }) -> Match? {
        let pairs = brackets.compactMap { pair -> (unichar, unichar)? in
            let open = Array(pair.open.utf16), close = Array(pair.close.utf16)
            return open.count == 1 && close.count == 1 ? (open[0], close[0]) : nil
        }
        guard !pairs.isEmpty else { return nil }
        for at in [offset, offset - 1] where at >= 0 && at < text.length {
            let unit = text.character(at: at)
            guard pairs.contains(where: { $0.0 == unit || $0.1 == unit }), isCode(at) else { continue }
            if let pair = pairs.first(where: { $0.0 == unit }) {
                if let close = scan(text, from: at, step: 1, same: pair.0, other: pair.1, limit: limit, isCode: isCode) { return Match(open: at, close: close) }
            } else if let pair = pairs.first(where: { $0.1 == unit }) {
                if let open = scan(text, from: at, step: -1, same: pair.1, other: pair.0, limit: limit, isCode: isCode) { return Match(open: open, close: at) }
            }
        }
        return nil
    }

    /// The innermost pair the cursor is inside (Go to Bracket away from any bracket): the nearest opening
    /// before `offset` left unclosed, and its partner.
    public static func enclosing(in text: NSString, at offset: Int, brackets: [EditingPairs.Pair], limit: Int = 200_000,
                                 isCode: (Int) -> Bool = { _ in true }) -> Match? {
        let pairs = brackets.compactMap { pair -> (unichar, unichar)? in
            let open = Array(pair.open.utf16), close = Array(pair.close.utf16)
            return open.count == 1 && close.count == 1 ? (open[0], close[0]) : nil
        }
        var depth: [unichar: Int] = [:]
        var index = min(offset, text.length) - 1
        var budget = limit
        while index >= 0, budget > 0 {
            let unit = text.character(at: index)
            if let pair = pairs.first(where: { $0.0 == unit || $0.1 == unit }), isCode(index) {
                if unit == pair.1 {
                    depth[pair.0, default: 0] += 1
                } else if depth[pair.0, default: 0] > 0 {
                    depth[pair.0, default: 0] -= 1
                } else if let close = scan(text, from: index, step: 1, same: pair.0, other: pair.1, limit: limit, isCode: isCode) {
                    return Match(open: index, close: close)
                }
            }
            index -= 1
            budget -= 1
        }
        return nil
    }

    /// From the bracket at `start`, the offset of the one that balances it.
    private static func scan(_ text: NSString, from start: Int, step: Int, same: unichar, other: unichar, limit: Int, isCode: (Int) -> Bool) -> Int? {
        var depth = 0
        var index = start + step
        var budget = limit
        while index >= 0, index < text.length, budget > 0 {
            let unit = text.character(at: index)
            if unit == same || unit == other, isCode(index) {
                if unit == same {
                    depth += 1
                } else if depth == 0 {
                    return index
                } else {
                    depth -= 1
                }
            }
            index += step
            budget -= 1
        }
        return nil
    }
}
