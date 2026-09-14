import Foundation

/// A web address or a file path a terminal printed, found on the line under the pointer: underlined while
/// ⌘ is held, opened by a ⌘-click, offered by a right-click.
///
/// Paths are found by their look, as VS Code's terminal finds them: a "/" in them, or a name with an
/// extension ("README.md"); not "hello", "error:", "1.2.3", "12:30:45" or an IP address. A line and column
/// may follow in the forms compilers, test runners and `grep -n` print: "x.ts:12:3", "x.ts:12.3",
/// "x.ts#12", "x.ts(12,3)", "x.ts line 12", "x.ts:line 12" and Python's `"x.py", line 12, column 3`. A path
/// with spaces is found in quotes. Brackets, quotes and punctuation round a path are left out ("(x.ts:12)",
/// "see x.ts."), except the quotes of a quoted path, which are underlined with it.
///
/// What looks like a path need not be one: the app checks that a file is there (through `candidates`)
/// before treating it as a link.
public struct TerminalLink: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// "https://…", "ssh://…": anything with a scheme but `file`.
        case url(String)
        /// As written: relative, "~/…", or a "file://" URL (opened as a file, so a line can follow it);
        /// `candidates(for:folder:home:)` makes it absolute. Line and column are 1-based.
        case file(path: String, line: Int?, column: Int?)
    }

    public var target: Target
    /// Character offsets (Character indices of the given line) the link covers, for underlining.
    public var range: Range<Int>

    public init(target: Target, range: Range<Int>) {
        self.target = target
        self.range = range
    }

    /// The link at character offset `index` of `line`, or nil. Paths are returned as written (not resolved).
    public static func link(in line: String, at index: Int) -> TerminalLink? {
        links(in: line).first { $0.range.contains(index) }
    }

    /// Every link in the line, left to right. One hand-written pass per kind over the line's characters,
    /// each moving only forward: a line of 2,000 characters costs about a millisecond in a debug build.
    public static func links(in line: String) -> [TerminalLink] {
        var scan = LinkScan(line)
        scan.findURLs()
        scan.findQuotedPaths()
        scan.findPaths()
        return scan.found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Where the file at `path` (as a link gives it) may be, best first, absolute and standardized: "~"
    /// is `home`, a relative path is in `folder` (the terminal's), a "file://" URL is decoded. A path
    /// starting with one of git's diff prefixes ("a/" and "b/", and the "c/", "i/", "o/", "w/", "1/", "2/"
    /// of `diff.mnemonicPrefix` and `--no-index`) is tried without it first, then as written. The app
    /// opens the first that exists.
    public static func candidates(for path: String, folder: String, home: String = NSHomeDirectory()) -> [String] {
        if path.lowercased().hasPrefix("file://") {
            let decoded = URL(string: path).flatMap { $0.isFileURL ? $0.path : nil }
                ?? String(path.dropFirst("file://".count)).removingPercentEncoding
            return decoded.map { [standardized($0)] } ?? []
        }
        func absolute(_ path: String) -> String {
            if path == "~" || path.hasPrefix("~/") { return standardized(home + path.dropFirst()) }
            return standardized(path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path))
        }
        var written = [path]
        if let slash = path.firstIndex(of: "/"), path.distance(from: path.startIndex, to: slash) == 1,
           "abciow12".contains(path[path.startIndex]), path.index(after: slash) < path.endIndex {
            written.insert(String(path[path.index(after: slash)...]), at: 0)
        }
        var seen = Set<String>()
        return written.map(absolute).filter { seen.insert($0).inserted }
    }

    /// ".", "..", repeated slashes and a trailing slash taken out, without asking the disk anything.
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardized.path
    }
}

/// The search for links in one line: web addresses first, then quoted paths, then bare paths, each
/// skipping what an earlier kind took. It reads one byte per character (`codes`), as comparing
/// Characters themselves is slow.
private struct LinkScan {
    /// The line's characters; nil for a line of plain ASCII, where each byte is one.
    let characters: [Character]?
    /// Each character's ASCII value; for any other character, one of the codes below.
    let codes: [UInt8]
    var found: [TerminalLink] = []
    /// Which characters a link already holds.
    var taken: [Bool]
    /// Brackets that are a folder's or file's own name, as web frameworks name routes ("app/[id]/page.tsx",
    /// "app/(shop)/x.tsx"): a pair opened right after a "/" and closed right before a "/" or a ".". Any
    /// other bracket ends a path, as tools put them round one ("[x.ts:12]").
    var nameBrackets: [Bool]

    /// A letter or digit beyond ASCII ("資料/メモ.txt").
    static let wideLetter: UInt8 = 0x80
    /// A full-width bracket or punctuation mark, which ends a path as its ASCII form does ("「x.ts」").
    static let wideStop: UInt8 = 0x81
    /// Any other character beyond ASCII (symbols, emoji): part of a path, like ASCII symbols.
    static let wideOther: UInt8 = 0x82
    /// Whitespace beyond ASCII (a no-break space), which ends a path as a space does.
    static let wideSpace: UInt8 = 0x09
    private static let wideStops: Set<Character> = ["：", "（", "）", "「", "」", "『", "』", "【", "】", "、", "。", "，", "；", "＜", "＞"]

    init(_ line: String) {
        let bytes = Array(line.utf8)
        // Most lines are plain ASCII: no splitting into Characters ("\r\n" would be one).
        if !bytes.contains(where: { $0 >= 0x80 || $0 == 0x0D }) {
            characters = nil
            codes = bytes
        } else {
            let characters = Array(line)
            self.characters = characters
            codes = characters.map { character in
                if let ascii = character.asciiValue { return ascii }
                if character.isWhitespace { return Self.wideSpace }
                if Self.wideStops.contains(character) { return Self.wideStop }
                return character.isLetter || character.isNumber ? Self.wideLetter : Self.wideOther
            }
        }
        taken = [Bool](repeating: false, count: codes.count)
        nameBrackets = Self.nameBrackets(in: codes)
    }

    private static func nameBrackets(in codes: [UInt8]) -> [Bool] {
        var marked = [Bool](repeating: false, count: codes.count)
        let slash = UInt8(ascii: "/"), dot = UInt8(ascii: ".")
        for index in codes.indices where index > 0 && codes[index - 1] == slash {
            let open = codes[index]
            guard let close: UInt8 = open == UInt8(ascii: "[") ? UInt8(ascii: "]") : open == UInt8(ascii: "(") ? UInt8(ascii: ")") : nil else { continue }
            var end = index + 1
            while end < codes.count, codes[end] != close, !isSpace(codes[end]), !isStop(codes[end]) || codes[end] == UInt8(ascii: "*") { end += 1 }
            guard end < codes.count, codes[end] == close, end > index + 1, end + 1 < codes.count, codes[end + 1] == slash || codes[end + 1] == dot else { continue }
            marked[index] = true
            marked[end] = true
        }
        return marked
    }

    func text(_ range: Range<Int>) -> String {
        characters.map { String($0[range]) } ?? String(decoding: codes[range], as: UTF8.self)
    }

    static func isSpace(_ code: UInt8) -> Bool { code <= 0x20 || code == 0x7F }
    static func isDigit(_ code: UInt8) -> Bool { (0x30...0x39).contains(code) }
    static func isASCIILetter(_ code: UInt8) -> Bool { (0x41...0x5A).contains(code) || (0x61...0x7A).contains(code) }
    static func isAlphanumeric(_ code: UInt8) -> Bool { isDigit(code) || isASCIILetter(code) || code == wideLetter }

    /// What ends a bare path besides a space: the brackets, quotes and separators tools put round paths.
    static func isStop(_ code: UInt8) -> Bool {
        switch code {
        case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "|"),
             UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "="), UInt8(ascii: "*"), wideStop: true
        default: false
        }
    }

    /// What ends a web address besides a space (brackets do not: a link may hold them).
    static func isURLStop(_ code: UInt8) -> Bool {
        switch code {
        case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "|"),
             UInt8(ascii: "{"), UInt8(ascii: "}"), wideStop: true
        default: false
        }
    }

    /// The sentence's punctuation after a web address, not the address's.
    static func isURLTrailing(_ code: UInt8) -> Bool {
        switch code {
        case UInt8(ascii: "."), UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: ":"), UInt8(ascii: "!"), UInt8(ascii: "?"), UInt8(ascii: "*"): true
        default: false
        }
    }

    /// The sentence's punctuation after a path ("see x.ts.").
    static func isPathTrailing(_ code: UInt8) -> Bool {
        code == UInt8(ascii: ".") || code == UInt8(ascii: "!") || code == UInt8(ascii: "?")
    }

    mutating func add(_ target: TerminalLink.Target, _ range: Range<Int>) {
        found.append(TerminalLink(target: target, range: range))
        for index in range { taken[index] = true }
    }

    // MARK: Web addresses

    /// "scheme://…" up to a space or a quote, less the punctuation after it and any closing bracket it
    /// did not open ("(see https://x.org/a)"), keeping the ones it did ("…/wiki/Foo_(bar)").
    mutating func findURLs() {
        let colon = UInt8(ascii: ":"), slash = UInt8(ascii: "/")
        var index = 0
        while index + 3 < codes.count {
            guard codes[index] == colon, codes[index + 1] == slash, codes[index + 2] == slash else {
                index += 1
                continue
            }
            var start = index
            while start > 0, Self.isSchemeCharacter(codes[start - 1]) { start -= 1 }
            while start < index, !Self.isASCIILetter(codes[start]) { start += 1 }
            guard index - start >= 2, !hasFileScheme(at: start, before: index + 3) else {
                index += 3
                continue
            }
            var end = index + 3
            while end < codes.count, !Self.isSpace(codes[end]), !Self.isURLStop(codes[end]) { end += 1 }
            end = trimmedURLEnd(from: index + 3, to: end)
            if end > index + 3 { add(.url(text(start..<end)), start..<end) }
            index = max(end, index + 3)
        }
    }

    static func isSchemeCharacter(_ code: UInt8) -> Bool {
        isDigit(code) || isASCIILetter(code) || code == UInt8(ascii: "+") || code == UInt8(ascii: "-") || code == UInt8(ascii: ".")
    }

    func trimmedURLEnd(from start: Int, to end: Int) -> Int {
        // How many more round and square brackets close than open.
        var parentheses = 0, brackets = 0
        for code in codes[start..<end] {
            switch code {
            case UInt8(ascii: ")"): parentheses += 1
            case UInt8(ascii: "("): parentheses -= 1
            case UInt8(ascii: "]"): brackets += 1
            case UInt8(ascii: "["): brackets -= 1
            default: break
            }
        }
        var end = end
        while end > start {
            let last = codes[end - 1]
            if Self.isURLTrailing(last) {
                end -= 1
            } else if last == UInt8(ascii: ")"), parentheses > 0 {
                parentheses -= 1
                end -= 1
            } else if last == UInt8(ascii: "]"), brackets > 0 {
                brackets -= 1
                end -= 1
            } else {
                break
            }
        }
        return end
    }

    // MARK: Paths in quotes

    /// `"path with spaces/x.ts"`, `'…'`, or Python's `File "/x/foo.py", line 12`: what is between two
    /// quotes when it looks like a path, then a line and column after the closing quote. An apostrophe
    /// inside a word ("don't") opens nothing. A quoted text with a ":" in it is left to `findPaths`, which
    /// reads the line after it ("\"x.ts:12\"").
    mutating func findQuotedPaths() {
        var index = 0
        while index < codes.count {
            let quote = codes[index]
            guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "`") || (quote == UInt8(ascii: "'") && (index == 0 || !Self.isAlphanumeric(codes[index - 1]))),
                  let close = quotable(from: index + 1, to: quote), looksLikePath(index + 1..<close) else {
                index += 1
                continue
            }
            let inside = index + 1..<close
            let suffix = LineSuffix(codes, at: close + 1)
            let end = suffix?.end ?? close + 1
            add(.file(path: text(inside), line: suffix?.line, column: suffix?.column), index..<end)
            index = end
        }
    }

    /// Where the quote opened before `start` closes, when what is between could be a path: not empty,
    /// not starting or ending with a space, free of other whitespace, of links already found and of ":".
    /// Plain loops here and below: a slice's methods are generic, and slow in a debug build.
    func quotable(from start: Int, to quote: UInt8) -> Int? {
        guard start < codes.count, codes[start] != 0x20, !taken[start - 1] else { return nil }
        var index = start
        while index < codes.count {
            let code = codes[index]
            if code == quote { return index > start && codes[index - 1] != 0x20 ? index : nil }
            if taken[index] || code == UInt8(ascii: ":") || (code != 0x20 && Self.isSpace(code)) { return nil }
            index += 1
        }
        return nil
    }

    // MARK: Bare paths

    /// Runs of characters up to a space or a stop; in each, the path runs to the first ":" (or a "#"
    /// before a digit), and a line and column may follow. When what comes before a ":" is no path
    /// ("error:src/x.ts"), the search goes on after it.
    mutating func findPaths() {
        var index = 0
        while index < codes.count {
            guard isPathCharacter(index) else {
                index += 1
                continue
            }
            var end = index
            while end < codes.count, isPathCharacter(end) { end += 1 }
            index = max(end, pathsIn(index..<end))
        }
    }

    func isPathCharacter(_ index: Int) -> Bool {
        !taken[index] && !Self.isSpace(codes[index]) && (!Self.isStop(codes[index]) || nameBrackets[index])
    }

    /// Adds the paths in one run of path characters; returns where the last one (with its line) ends.
    mutating func pathsIn(_ run: Range<Int>) -> Int {
        let colon = UInt8(ascii: ":"), hash = UInt8(ascii: "#")
        var start = run.lowerBound, reached = run.upperBound
        while start < run.upperBound {
            // "file://" belongs to the path; the path's own text starts after it.
            let bare = hasFileScheme(at: start, before: run.upperBound) ? start + 7 : start
            var pathEnd = bare
            while pathEnd < run.upperBound, codes[pathEnd] != colon,
                  !(codes[pathEnd] == hash && pathEnd + 1 < codes.count && Self.isDigit(codes[pathEnd + 1])) { pathEnd += 1 }
            var trimmed = pathEnd
            while trimmed > bare, Self.isPathTrailing(codes[trimmed - 1]) { trimmed -= 1 }
            guard trimmed > bare, looksLikePath(bare..<trimmed) else {
                start = pathEnd + 1
                continue
            }
            let suffix = trimmed == pathEnd ? LineSuffix(codes, at: pathEnd) : nil
            let end = suffix?.end ?? trimmed
            add(.file(path: text(start..<trimmed), line: suffix?.line, column: suffix?.column), start..<end)
            reached = max(reached, end)
            start = end
        }
        return reached
    }

    /// A "/" with a letter or digit somewhere, or a last part with an extension that starts with a
    /// letter ("README.md", not "1.2.3"). Spaces (only in quotes) need the extension too, so a quoted
    /// sentence with a "/" in it is not a path.
    func looksLikePath(_ range: Range<Int>) -> Bool {
        var slash = false, alphanumeric = false, space = false, nameStart = range.lowerBound
        for index in range {
            let code = codes[index]
            if code == UInt8(ascii: "/") {
                slash = true
                nameStart = index + 1
            } else if code == 0x20 {
                space = true
            } else if Self.isAlphanumeric(code) {
                alphanumeric = true
            }
        }
        guard alphanumeric else { return false }
        if slash && !space { return true }
        // The extension: letters, digits, "_" and "-" back to a "." inside the name, the first a letter.
        var dot = range.upperBound - 1
        while dot > nameStart {
            let code = codes[dot]
            if code == UInt8(ascii: ".") { break }
            guard Self.isDigit(code) || Self.isASCIILetter(code) || code == UInt8(ascii: "_") || code == UInt8(ascii: "-") else { return false }
            dot -= 1
        }
        return dot > nameStart && dot + 1 < range.upperBound && Self.isASCIILetter(codes[dot + 1])
    }

    func hasFileScheme(at index: Int, before end: Int) -> Bool {
        guard index + 7 <= end else { return false }
        return zip(codes[index..<(index + 7)], "file://".utf8).allSatisfy { code, wanted in
            (Self.isASCIILetter(code) ? code | 0x20 : code) == wanted
        }
    }
}

/// The line, and maybe column, written right after a path, and where that writing ends.
private struct LineSuffix {
    let line: Int
    let column: Int?
    let end: Int

    private static let lineLeads = [", ", ": ", ":", " on ", " "].map { Array($0.utf8) }
    private static let lineWord = Array("line ".utf8)
    private static let columnLeads = [", ", " "].map { Array($0.utf8) }
    private static let columnWords = ["column ", "col ", "character "].map { Array($0.utf8) }

    /// ":12", ":12:3", ":12.3", "#12", "#12:3"; "(12)", "(12,3)", "(12, 3)", "(12:3)" and the same in
    /// square brackets; ", line 12", ":line 12", ": line 12", " on line 12", " line 12", each perhaps
    /// with ", column 3", ", col 3" or ", character 3" (or the same after a space). nil when none of these
    /// is at `index` of the line's `codes`.
    init?(_ codes: [UInt8], at index: Int) {
        func number(at index: Int) -> (value: Int, end: Int)? {
            var value = 0, end = index
            // Nine digits at most: no line is longer, and the value cannot overflow.
            while end < codes.count, end - index < 9, (0x30...0x39).contains(codes[end]) {
                value = value * 10 + Int(codes[end] - 0x30)
                end += 1
            }
            return end > index ? (value, end) : nil
        }
        func has(_ text: [UInt8], at index: Int) -> Bool {
            guard index + text.count <= codes.count else { return false }
            var offset = 0
            while offset < text.count, codes[index + offset] == text[offset] { offset += 1 }
            return offset == text.count
        }
        func code(_ index: Int) -> UInt8? { index < codes.count ? codes[index] : nil }
        guard let first = code(index) else { return nil }

        if first == UInt8(ascii: ":") || first == UInt8(ascii: "#"), let line = number(at: index + 1) {
            if let next = code(line.end), next == UInt8(ascii: ":") || next == UInt8(ascii: "."), let column = number(at: line.end + 1) {
                self.init(line: line.value, column: column.value, end: column.end)
            } else {
                self.init(line: line.value, column: nil, end: line.end)
            }
            return
        }

        if first == UInt8(ascii: "(") || first == UInt8(ascii: "[") {
            let close = first == UInt8(ascii: "(") ? UInt8(ascii: ")") : UInt8(ascii: "]")
            guard let line = number(at: index + 1), let next = code(line.end) else { return nil }
            if next == close {
                self.init(line: line.value, column: nil, end: line.end + 1)
                return
            }
            var position = line.end + 1
            if next == UInt8(ascii: ",") {
                if code(position) == 0x20 { position += 1 }
            } else if next != UInt8(ascii: ":") {
                return nil
            }
            guard let column = number(at: position), code(column.end) == close else { return nil }
            self.init(line: line.value, column: column.value, end: column.end + 1)
            return
        }

        for lead in Self.lineLeads where has(lead, at: index) && has(Self.lineWord, at: index + lead.count) {
            guard let line = number(at: index + lead.count + Self.lineWord.count) else { continue }
            for columnLead in Self.columnLeads where has(columnLead, at: line.end) {
                for word in Self.columnWords where has(word, at: line.end + columnLead.count) {
                    if let column = number(at: line.end + columnLead.count + word.count) {
                        self.init(line: line.value, column: column.value, end: column.end)
                        return
                    }
                }
            }
            self.init(line: line.value, column: nil, end: line.end)
            return
        }
        return nil
    }

    private init(line: Int, column: Int?, end: Int) {
        self.line = line
        self.column = column
        self.end = end
    }
}
