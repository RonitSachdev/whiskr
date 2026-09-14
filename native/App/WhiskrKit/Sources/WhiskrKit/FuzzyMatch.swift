import Foundation

/// Typing a few letters of a name finds it, as in Xcode's Open Quickly, Raycast or VS Code's Quick Open:
/// the letters must appear in order, and a match scores higher when they start words, run together and
/// start the name. Case and accents are ignored. The best of all the ways the letters can line up is
/// found (the names are short, so this costs nothing that shows).
///
/// Words separated by spaces are matched one by one, in any order, and all must match: "main java" finds
/// `src/main/java/App.java`. A word in double quotes must appear as it is, letters side by side:
/// `"bench+"` finds `Workbench+Scene.swift` but not `bench/x+y`.
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        /// Higher is better. Only comparable between matches of the same query.
        public let score: Int
        /// The matched characters' offsets in the text (every word's, in order), for drawing them bold.
        public let offsets: [Int]
        /// The query is the start of the text (ignoring case): the strongest kind of match.
        public let isPrefix: Bool
    }

    /// What was typed, split into words once so that matching it against many names repeats no work.
    public struct Query: Equatable, Sendable {
        public struct Word: Equatable, Sendable {
            /// As typed, without its quotes.
            public let text: String
            /// Its letters must sit side by side in the text (it was typed in double quotes).
            public let isContiguous: Bool
            /// `text` folded as the text is (`fold`).
            let letters: [Character]
        }

        public let words: [Word]
        /// The whole query folded, quotes removed and spaces kept, for telling whether it starts the text.
        let whole: [Character]

        /// Words are split at spaces; a double quote starts a word that runs to the next double quote (or
        /// the end, while it is still being typed), spaces and all.
        public init(_ text: String) {
            var words: [Word] = [], current = "", quoted = false
            func finish() {
                if !current.isEmpty { words.append(Word(text: current, isContiguous: quoted, letters: fold(current))) }
                current = ""
                quoted = false
            }
            for character in text {
                if character == "\"" {
                    if quoted { finish() } else { finish(); quoted = true }
                } else if character.isWhitespace && !quoted {
                    finish()
                } else {
                    current.append(character)
                }
            }
            finish()
            self.words = words
            whole = fold(text.filter { $0 != "\"" }.trimmingCharacters(in: .whitespaces))
        }

        public var isEmpty: Bool { words.isEmpty }
        /// Some word holds a "/": the query is for a path, not a name.
        public var mentionsFolder: Bool { words.contains { $0.text.contains("/") } }
    }

    private static let matchBonus = 16
    private static let firstLetterBonus = 30
    private static let gapPenalty = 2
    /// Matching a letter that starts a part of the text: a folder's or file's name after a "/" most, a
    /// word after other punctuation or a space less, a capital inside a word ("goToNext") less again.
    private static let afterSlashBonus = 30
    private static let afterSeparatorBonus = 24
    private static let capitalBonus = 12
    /// A letter right after the previous one is worth as much as one starting a name after a gap, so a
    /// word stays together: "java" in `src/main/java/App.java` is the folder's, not "jav" and `App`'s A.
    private static let runBonus = afterSlashBonus
    /// A query that starts the text wins over any other match, and among those, the one that covers
    /// more of the text: "window" puts `window.ts` before `windowActions.ts`.
    private static let prefixBonus = 1000
    private static let coverageBonus = 100

    /// The best way `query` matches `text`, or nil when some word of it does not.
    public static func match(_ query: String, in text: String) -> Match? {
        match(Query(query), in: text)
    }

    public static func match(_ query: Query, in text: String) -> Match? {
        guard !query.isEmpty else { return Match(score: 0, offsets: [], isPrefix: true) }
        let hay = fold(text)
        let bonuses = boundaryBonuses(Array(text))
        var score = 0, offsets = Set<Int>()
        for word in query.words {
            guard let found = best(word.letters, contiguous: word.isContiguous, in: hay, bonuses: bonuses) else { return nil }
            score += found.score
            offsets.formUnion(found.offsets)
        }
        let prefix = hay.starts(with: query.whole)
        if prefix { score += prefixBonus + coverageBonus * query.whole.count / hay.count }
        return Match(score: score, offsets: offsets.sorted(), isPrefix: prefix)
    }

    /// The best way one word's `needle` lines up in `hay`: its score and the offsets of its letters.
    private static func best(_ needle: [Character], contiguous: Bool, in hay: [Character], bonuses: [Int]) -> (score: Int, offsets: [Int])? {
        guard needle.count <= hay.count else { return nil }

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
                    // gapPenalty * k, kept as j moves along. Right before j (no gap) earns the run bonus
                    // instead. A word in quotes allows no gap at all.
                    var farthest = none, farthestAt = -1
                    var j = -1
                    while j + 1 < columns {
                        j += 1
                        if !contiguous, i > 0, j >= 2, best[above + j - 2] > none, best[above + j - 2] + gapPenalty * (j - 2) > farthest {
                            farthest = best[above + j - 2] + gapPenalty * (j - 2)
                            farthestAt = j - 2
                        }
                        guard hay[j] == needle[i] else { continue }
                        let bonus = matchBonus + bonuses[j] + (j == 0 ? firstLetterBonus : 0)
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
        return (best[last + end], offsets)
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

    /// What matching each character is worth beyond the match itself, by where it sits: the text's first
    /// character and one after punctuation or a space start a word; after a "/" or "\" they start a
    /// folder's or file's name, worth more; a capital after a lower-case letter ("goToNext") starts a word
    /// inside a word, worth less.
    static func boundaryBonuses(_ text: [Character]) -> [Int] {
        text.indices.map { index in
            let here = text[index]
            guard index > 0 else { return afterSeparatorBonus }
            let before = text[index - 1]
            if !before.isLetter && !before.isNumber {
                guard here.isLetter || here.isNumber else { return 0 }
                return before == "/" || before == "\\" ? afterSlashBonus : afterSeparatorBonus
            }
            return here.isUppercase && before.isLowercase ? capitalBonus : 0
        }
    }
}
