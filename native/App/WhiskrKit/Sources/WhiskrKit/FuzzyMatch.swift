import Foundation

/// Typing a few letters of a name finds it, as in Xcode's Open Quickly or Raycast: the letters must
/// appear in order, and a match scores higher when they start words, run together and start the name.
/// Case and accents are ignored. The best of all the ways the letters can line up is found (the names
/// are short, so this costs nothing that shows).
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        /// Higher is better. Only comparable between matches of the same query.
        public let score: Int
        /// The matched characters' offsets in the text, for drawing them bold.
        public let offsets: [Int]
        /// The query is the start of the text (ignoring case): the strongest kind of match.
        public let isPrefix: Bool
    }

    private static let matchBonus = 16
    private static let wordStartBonus = 24
    private static let runBonus = 18
    private static let firstLetterBonus = 30
    private static let gapPenalty = 2

    /// The best way `query` matches `text`, or nil when its letters are not all in `text` in order.
    /// Spaces in the query are ignored, so "shop web" finds "shop-web".
    public static func match(_ query: String, in text: String) -> Match? {
        let needle = Array(fold(query).filter { !$0.isWhitespace })
        let hay = Array(fold(text))
        guard !needle.isEmpty else { return Match(score: 0, offsets: [], isPrefix: true) }
        guard needle.count <= hay.count else { return nil }
        let original = Array(text)
        let starts = (0..<hay.count).map { isWordStart(original, $0) }

        // best[i * columns + j]: the best score with needle[0...i] matched and needle[i] at hay[j]; from[…]:
        // where needle[i - 1] was then. One flat table each, filled through raw buffers: this runs for
        // hundreds of names a keystroke, and stays quick even in a debug build.
        let none = Int.min / 2
        let rows = needle.count, columns = hay.count
        var best = [Int](repeating: none, count: rows * columns)
        var from = [Int](repeating: -1, count: rows * columns)
        best.withUnsafeMutableBufferPointer { best in
            from.withUnsafeMutableBufferPointer { from in
                // Plain loops: a range's iterator is generic, and slow in a debug build.
                var i = 0
                while i < rows {
                    defer { i += 1 }
                    let row = i * columns, above = row - columns
                    // The previous letter at k, then a gap of j - k - 1 letters, costs gapPenalty per letter:
                    // so the best earlier k (two or more back) is the one with the most best[i-1, k] +
                    // gapPenalty * k, kept as j moves along. Right before j (no gap) earns the run bonus instead.
                    var farthest = none, farthestAt = -1
                    var j = -1
                    while j + 1 < columns {
                        j += 1
                        if i > 0, j >= 2, best[above + j - 2] > none, best[above + j - 2] + gapPenalty * (j - 2) > farthest {
                            farthest = best[above + j - 2] + gapPenalty * (j - 2)
                            farthestAt = j - 2
                        }
                        guard hay[j] == needle[i] else { continue }
                        let bonus = matchBonus + (starts[j] ? wordStartBonus : 0) + (j == 0 ? firstLetterBonus : 0)
                        if i == 0 {
                            best[row + j] = bonus - j
                            continue
                        }
                        if farthestAt >= 0 {
                            best[row + j] = farthest - gapPenalty * (j - 1) + bonus
                            from[row + j] = farthestAt
                        }
                        if j >= 1, best[above + j - 1] > none, best[above + j - 1] + runBonus + bonus >= best[row + j] {
                            best[row + j] = best[above + j - 1] + runBonus + bonus
                            from[row + j] = j - 1
                        }
                    }
                }
            }
        }
        let last = (rows - 1) * columns
        var end = 0
        for column in 1..<max(columns, 1) where best[last + column] > best[last + end] { end = column }
        guard best[last + end] > none else { return nil }
        var offsets = [end]
        var i = rows - 1, j = end
        while i > 0 {
            j = from[i * columns + j]
            i -= 1
            offsets.insert(j, at: 0)
        }
        let prefix = hay.starts(with: Array(fold(query)))
        return Match(score: best[last + end] + (prefix ? 1000 : 0), offsets: offsets, isPrefix: prefix)
    }

    /// Lowercased with accents removed, one Character per Character of the original (so offsets hold).
    static func fold(_ text: String) -> [Character] {
        text.map { character in
            // Plain ASCII needs no Foundation: only its capitals change.
            if let ascii = character.asciiValue {
                return (0x41...0x5A).contains(ascii) ? Character(UnicodeScalar(ascii + 32)) : character
            }
            let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            return folded.count == 1 ? Character(folded) : character
        }
    }

    /// The first letter of a word: the text's first, after a space or punctuation, or a capital after a
    /// lower-case letter ("goToNext").
    static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = text[index - 1], here = text[index]
        if !before.isLetter && !before.isNumber { return here.isLetter || here.isNumber }
        return here.isUppercase && before.isLowercase
    }
}
