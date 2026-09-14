import Foundation

/// Words in code, as VS Code's default word definition sees them (anything but whitespace and
/// `USUAL_WORD_SEPARATORS`), and the other places a word occurs: the editor highlights them while the
/// cursor is in the word, or the word is selected (whole words, case-sensitive, as VS Code's textual
/// occurrences).
public enum Occurrences {
    /// VS Code's `USUAL_WORD_SEPARATORS` (src/vs/editor/common/core/wordHelper.ts).
    static let separators: Set<unichar> = Set("`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?".utf16)

    public static func isWordCharacter(_ unit: unichar) -> Bool {
        guard !separators.contains(unit) else { return false }
        switch unit {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0xA0, 0x3000: return false
        default: return true
        }
    }

    /// The word the cursor is in or just after, within its line.
    public static func word(in text: NSString, at offset: Int) -> NSRange? {
        guard offset >= 0, offset <= text.length else { return nil }
        var start = offset, end = offset
        while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWordCharacter(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// The word to highlight for a selection: the word at an empty selection, or a selection that is exactly
    /// one word; nil otherwise.
    public static func highlightedWord(in text: NSString, selection: NSRange) -> NSRange? {
        if selection.length == 0 { return word(in: text, at: selection.location) }
        guard NSMaxRange(selection) <= text.length, let word = word(in: text, at: selection.location), word == selection else { return nil }
        return word
    }

    /// Every whole-word occurrence of `word` within `range`, in order.
    public static func find(_ word: String, in text: NSString, range: NSRange) -> [NSRange] {
        let length = (word as NSString).length
        guard length > 0 else { return [] }
        var found: [NSRange] = []
        var search = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        while search.length >= length {
            let match = text.range(of: word, options: .literal, range: search)
            guard match.location != NSNotFound else { break }
            let before = match.location > 0 ? text.character(at: match.location - 1) : 0x20
            let after = NSMaxRange(match) < text.length ? text.character(at: NSMaxRange(match)) : 0x20
            if !isWordCharacter(before), !isWordCharacter(after) { found.append(match) }
            let next = match.location + 1
            search = NSRange(location: next, length: NSMaxRange(search) - next)
        }
        return found
    }

    /// What to highlight for a selection, within `visible`: every occurrence of its word (the one under an
    /// empty selection too, as VS Code does), or nothing.
    public static func highlights(in text: NSString, selection: NSRange, visible: NSRange) -> [NSRange] {
        guard let word = highlightedWord(in: text, selection: selection) else { return [] }
        let all = find(text.substring(with: word), in: text, range: visible)
        return selection.length > 0 ? all.filter { $0 != selection } : all
    }
}
