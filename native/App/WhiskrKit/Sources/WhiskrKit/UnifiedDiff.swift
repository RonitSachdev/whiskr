import Foundation

/// One file's changes in a unified diff (`git diff`, `git diff --cached`, `git diff --no-index`).
public struct FileDiff: Sendable, Equatable {
    /// The path before, without git's "a/"; nil for a file that was added.
    public var oldPath: String?
    /// The path after, without git's "b/"; nil for a file that was deleted.
    public var newPath: String?
    /// Git only says the file differs ("Binary files … differ", or a binary patch).
    public var isBinary: Bool
    /// A combined diff (`diff --cc`): a file in conflict, or a merge. Its hunks are read against the first
    /// side (yours, during a merge), so the conflict markers and the other side's lines show as added.
    public var isCombined: Bool
    /// A submodule's commit (mode 160000): its "lines" are commit ids, not a file's.
    public var isSubmodule: Bool
    public var hunks: [DiffHunk]

    public init(oldPath: String?, newPath: String?, isBinary: Bool = false, isCombined: Bool = false, isSubmodule: Bool = false, hunks: [DiffHunk] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.isBinary = isBinary
        self.isCombined = isCombined
        self.isSubmodule = isSubmodule
        self.hunks = hunks
    }

    /// One change of it can be staged, unstaged or reverted on its own (`DiffPatch`): a text file, the
    /// same path on both sides. A patch of part of an added or deleted file, or of a rename, needs headers
    /// a single change cannot carry (applied without them it leaves an empty file in the index, or fails);
    /// the whole file is staged or reverted from the Changes list instead.
    public var acceptsChangePatches: Bool {
        oldPath != nil && oldPath == newPath && !isBinary && !isCombined && !isSubmodule
    }
}

/// A run of changed lines with the unchanged lines around them ("@@ -12,7 +12,9 @@ func foo()").
public struct DiffHunk: Sendable, Equatable {
    public var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    /// What git prints after the second "@@": usually the function the change is in.
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "", lines: [DiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    /// The header line as git prints it.
    public var header: String {
        let old = oldCount == 1 ? "\(oldStart)" : "\(oldStart),\(oldCount)"
        let new = newCount == 1 ? "\(newStart)" : "\(newStart),\(newCount)"
        return "@@ -\(old) +\(new) @@" + (section.isEmpty ? "" : " \(section)")
    }
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, added, removed }

    public var kind: Kind
    /// The line without its marker and line break.
    public var text: String
    /// 1-based; nil for an added line.
    public var oldNumber: Int?
    /// 1-based; nil for a removed line.
    public var newNumber: Int?
    /// "\ No newline at end of file" followed this line.
    public var noNewlineAtEnd: Bool
    /// The line ends in "\r\n" (a Windows file): kept out of `text`, and put back in a patch, which must
    /// match the file byte for byte.
    public var carriageReturn: Bool

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, noNewlineAtEnd: Bool = false, carriageReturn: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.noNewlineAtEnd = noNewlineAtEnd
        self.carriageReturn = carriageReturn
    }
}

public enum UnifiedDiff {
    /// Every file in a diff. Header lines git adds (index, modes, renames, similarity) are read where they
    /// say something and passed over otherwise; anything else not understood is ignored, never fatal.
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        /// The file has had its "---" / "+++" lines or hunks, so a new "---" starts another file.
        var inHunks = false
        var hunk: DiffHunk?
        var oldLine = 0, newLine = 0
        var oldLeft = 0, newLeft = 0
        /// In a combined diff: each side's lines still to come in the hunk (the first is `oldLeft`'s).
        var parentsLeft: [Int] = []

        func finishHunk() {
            if let done = hunk { current?.hunks.append(done) }
            hunk = nil
        }
        func finishFile() {
            finishHunk()
            if let done = current { files.append(done) }
            current = nil
            inHunks = false
        }

        for raw in lineSlices(text) {
            let carriageReturn = raw.hasSuffix("\r")
            let line = carriageReturn ? raw.dropLast() : raw
            // A combined diff's hunk: a column per side before each line.
            if hunk != nil, !parentsLeft.isEmpty, parentsLeft.contains(where: { $0 > 0 }) || newLeft > 0 || line.hasPrefix("\\") {
                if line.hasPrefix("\\") {
                    if let last = hunk?.lines.indices.last { hunk?.lines[last].noNewlineAtEnd = true }
                    continue
                }
                let columns = Array(line.prefix(parentsLeft.count))
                let body = String(line.dropFirst(parentsLeft.count))
                // An empty line is a context line whose spaces were trimmed away.
                let marks = columns.count == parentsLeft.count ? columns : Array(repeating: " ", count: parentsLeft.count)
                guard marks.allSatisfy({ $0 == " " || $0 == "-" || $0 == "+" }) else { continue }
                let inResult = !marks.contains("-")
                for (side, mark) in marks.enumerated() where mark == "-" || (inResult && mark == " ") { parentsLeft[side] -= 1 }
                if inResult { newLeft -= 1 }
                if marks[0] == "-" {
                    hunk?.lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldLine, newNumber: nil, carriageReturn: carriageReturn))
                    oldLine += 1
                } else if inResult, marks[0] == "+" {
                    hunk?.lines.append(DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newLine, carriageReturn: carriageReturn))
                    newLine += 1
                } else if inResult {
                    hunk?.lines.append(DiffLine(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine, carriageReturn: carriageReturn))
                    oldLine += 1; newLine += 1
                }
                // Otherwise the line is only on another side: not shown against the first.
                continue
            }
            // Inside a hunk, lines belong to it while its counts last.
            if hunk != nil, parentsLeft.isEmpty, oldLeft > 0 || newLeft > 0 || line.hasPrefix("\\") {
                if let marker = line.first {
                    let body = String(line.dropFirst())
                    switch marker {
                    case " ":
                        hunk?.lines.append(DiffLine(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine, carriageReturn: carriageReturn))
                        oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                        continue
                    case "-":
                        hunk?.lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldLine, newNumber: nil, carriageReturn: carriageReturn))
                        oldLine += 1; oldLeft -= 1
                        continue
                    case "+":
                        hunk?.lines.append(DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newLine, carriageReturn: carriageReturn))
                        newLine += 1; newLeft -= 1
                        continue
                    case "\\":
                        if let last = hunk?.lines.indices.last { hunk?.lines[last].noNewlineAtEnd = true }
                        continue
                    default:
                        break
                    }
                } else {
                    // An empty line inside a hunk is an empty context line whose space was trimmed away.
                    hunk?.lines.append(DiffLine(kind: .context, text: "", oldNumber: oldLine, newNumber: newLine, carriageReturn: carriageReturn))
                    oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                    continue
                }
            }

            if line.hasPrefix("diff --git ") {
                finishFile()
                let (old, new) = gitHeaderPaths(String(line.dropFirst("diff --git ".count)))
                current = FileDiff(oldPath: old, newPath: new)
            } else if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                finishFile()
                let name = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst()))
                current = FileDiff(oldPath: name, newPath: name, isCombined: true)
            } else if line.hasPrefix("--- ") {
                // Without "diff --git" lines, a "---" after a file's hunks begins the next file.
                if current == nil || hunk != nil || current?.hunks.isEmpty == false {
                    finishFile()
                    current = FileDiff(oldPath: nil, newPath: nil)
                }
                current?.oldPath = path(String(line.dropFirst(4)), prefix: "a/")
                inHunks = true
            } else if line.hasPrefix("+++ "), current != nil {
                current?.newPath = path(String(line.dropFirst(4)), prefix: "b/")
                inHunks = true
            } else if line.hasPrefix("@@ "), current != nil, let header = hunkHeader(line) {
                finishHunk()
                hunk = header
                inHunks = true
                parentsLeft = []
                oldLine = header.oldStart; newLine = header.newStart
                oldLeft = header.oldCount; newLeft = header.newCount
            } else if line.hasPrefix("@@@"), current != nil, let (header, sides) = combinedHunkHeader(line) {
                finishHunk()
                hunk = header
                inHunks = true
                parentsLeft = sides
                oldLine = header.oldStart; newLine = header.newStart
                oldLeft = 0; newLeft = header.newCount
            } else if current != nil, !inHunks {
                if line.hasSuffix(" 160000"), line.hasPrefix("index ") || line.hasSuffix("mode 160000") {
                    current?.isSubmodule = true
                }
                if line.hasPrefix("new file mode") {
                    current?.oldPath = nil
                } else if line.hasPrefix("deleted file mode") {
                    current?.newPath = nil
                } else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                    current?.oldPath = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst()))
                } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                    current?.newPath = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst()))
                }
            }
            if current != nil, line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
            }
        }
        finishFile()
        return files
    }

    /// A diff showing every line of a file as added: an untracked file has nothing to compare against.
    public static func addedFile(path: String, text: String) -> FileDiff {
        guard !text.isEmpty else { return FileDiff(oldPath: nil, newPath: path) }
        var lines = lineSlices(text)
        let endsWithNewline = text.unicodeScalars.last == "\n"
        if endsWithNewline { lines.removeLast() }
        guard !lines.isEmpty else { return FileDiff(oldPath: nil, newPath: path) }
        var diffLines = lines.enumerated().map { number, line in
            let carriageReturn = line.hasSuffix("\r")
            return DiffLine(kind: .added, text: String(carriageReturn ? line.dropLast() : line), oldNumber: nil, newNumber: number + 1, carriageReturn: carriageReturn)
        }
        if !endsWithNewline { diffLines[diffLines.count - 1].noNewlineAtEnd = true }
        return FileDiff(oldPath: nil, newPath: path, hunks: [DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count, lines: diffLines)])
    }

    // MARK: Pieces

    /// A text's lines, split at each "\n" with any "\r" before it left on the line. Not `split(separator:)`
    /// on the text's characters: to Swift "\r\n" is one character, not a "\n", so a Windows file's lines
    /// would never come apart.
    public static func lineSlices(_ text: String) -> [Substring] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
    }

    /// "@@ -12,7 +12,9 @@ func foo()": the counts default to 1 when left out. Combined diffs' "@@@" are `combinedHunkHeader`'s.
    static func hunkHeader(_ line: Substring) -> DiffHunk? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "@@",
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ text: Substring) -> (Int, Int)? {
            let numbers = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            guard numbers.count > 1 else { return (start, 1) }
            guard let count = Int(numbers[1]) else { return nil }
            return (start, count)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        var section = ""
        if parts.count == 4 {
            let rest = parts[3]
            guard rest.hasPrefix("@@") else { return nil }
            section = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        return DiffHunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section)
    }

    /// "@@@ -12,7 -12,8 +12,11 @@@ func foo()": one range per side, then the result's. Gives the hunk
    /// against the first side, and every side's line count.
    static func combinedHunkHeader(_ line: Substring) -> (DiffHunk, [Int])? {
        let marker = line.prefix { $0 == "@" }
        let sides = marker.count - 1
        guard sides >= 2 else { return nil }
        let parts = line.split(separator: " ", maxSplits: sides + 2, omittingEmptySubsequences: false)
        guard parts.count >= sides + 2, parts[0] == marker else { return nil }
        var ranges: [(Int, Int)] = []
        for (index, part) in parts[1...(sides + 1)].enumerated() {
            guard part.hasPrefix(index < sides ? "-" : "+") else { return nil }
            let numbers = part.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) : 1
            guard let count else { return nil }
            ranges.append((start, count))
        }
        var section = ""
        if parts.count == sides + 3 {
            let rest = parts[sides + 2]
            guard rest.hasPrefix(marker) else { return nil }
            section = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        }
        let first = ranges[0], result = ranges[sides]
        let hunk = DiffHunk(oldStart: first.0, oldCount: first.1, newStart: result.0, newCount: result.1, section: section)
        return (hunk, ranges.prefix(sides).map(\.1))
    }

    /// A "---" or "+++" path: nil for /dev/null; git's prefix, its quoting and the tab it adds after a
    /// path with spaces are removed.
    static func path(_ text: String, prefix: String) -> String? {
        var text = text
        if let tab = text.firstIndex(of: "\t") { text = String(text[..<tab]) }
        text = unquote(text)
        if text == "/dev/null" { return nil }
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// The two paths in "diff --git a/x b/y": quoted ones are read as quoted; otherwise, as git only
    /// writes this line ambiguously for paths with spaces, the line is split where both halves name the
    /// same file (the usual case), else at the last " b/".
    static func gitHeaderPaths(_ rest: String) -> (String?, String?) {
        func strip(_ path: String, _ prefix: String) -> String { path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path }
        if rest.hasPrefix("\"") || rest.hasSuffix("\"") {
            let tokens = quotedTokens(rest)
            if tokens.count == 2 { return (strip(tokens[0], "a/"), strip(tokens[1], "b/")) }
        }
        let characters = Array(rest)
        if characters.count % 2 == 1 {
            let half = characters.count / 2
            let a = String(characters[..<half]), b = String(characters[(half + 1)...])
            if characters[half] == " ", a.hasPrefix("a/"), b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2) {
                return (String(a.dropFirst(2)), String(b.dropFirst(2)))
            }
        }
        if let split = rest.range(of: " b/", options: .backwards) {
            return (strip(String(rest[..<split.lowerBound]), "a/"), String(rest[split.upperBound...]))
        }
        return (nil, nil)
    }

    /// Splits on spaces outside quotes, unquoting each token.
    private static func quotedTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false, escaped = false
        for character in text {
            if escaped {
                current.append("\\"); current.append(character); escaped = false
            } else if character == "\\" && quoted {
                escaped = true
            } else if character == "\"" {
                current.append(character); quoted.toggle()
            } else if character == " " && !quoted {
                if !current.isEmpty { tokens.append(unquote(current)) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(unquote(current)) }
        return tokens
    }

    /// Git quotes a path holding unusual characters: "caf\303\251.txt", with C escapes and octal bytes
    /// that together are UTF-8.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var bytes: [UInt8] = []
        var characters = Array(text.utf8.dropFirst().dropLast())[...]
        while let byte = characters.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = characters.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = characters.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                    characters.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: Rows to show

/// One side of a row: a line's number and text, and the part that changed against its partner.
public struct DiffCell: Sendable, Equatable {
    public var number: Int
    public var text: String
    /// The span (UTF-16 offsets into `text`) that differs from the paired line on the other side; nil
    /// when there is no partner or nothing worth tinting.
    public var changed: Range<Int>?

    public init(number: Int, text: String, changed: Range<Int>? = nil) {
        self.number = number
        self.text = text
        self.changed = changed
    }
}

public struct DiffRow: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case hunk, context, removed, added, changed, gap }

    public var kind: Kind
    /// For a hunk row: its header line ("@@ -12,7 +12,9 @@ func foo()").
    public var header: String?
    /// The left side, or the removed line.
    public var old: DiffCell?
    /// The right side, or the added line.
    public var new: DiffCell?
    /// For a gap row: the unchanged lines it folds away (`DiffLayout.folded`).
    public var gap: DiffGap?

    public init(kind: Kind, header: String? = nil, old: DiffCell? = nil, new: DiffCell? = nil, gap: DiffGap? = nil) {
        self.kind = kind
        self.header = header
        self.old = old
        self.new = new
        self.gap = gap
    }
}

/// A file's diff as rows for the diff view: side by side or inline.
public enum DiffLayout {
    /// Side by side: in each run of removed lines followed by added ones, the two are paired in order
    /// (with the words that changed marked); what is left over has one side only.
    public static func sideBySide(_ diff: FileDiff) -> [DiffRow] {
        var rows: [DiffRow] = []
        for hunk in diff.hunks {
            rows.append(DiffRow(kind: .hunk, header: hunk.header))
            for run in runs(hunk.lines) {
                switch run {
                case .context(let line):
                    rows.append(contextRow(line))
                case .change(let removed, let added):
                    for index in 0..<max(removed.count, added.count) {
                        let old = index < removed.count ? removed[index] : nil
                        let new = index < added.count ? added[index] : nil
                        if let old, let new {
                            let (left, right) = changedRanges(old.text, new.text)
                            rows.append(DiffRow(kind: .changed, old: DiffCell(number: old.oldNumber ?? 0, text: old.text, changed: left),
                                                new: DiffCell(number: new.newNumber ?? 0, text: new.text, changed: right)))
                        } else if let old {
                            rows.append(DiffRow(kind: .removed, old: DiffCell(number: old.oldNumber ?? 0, text: old.text)))
                        } else if let new {
                            rows.append(DiffRow(kind: .added, new: DiffCell(number: new.newNumber ?? 0, text: new.text)))
                        }
                    }
                }
            }
        }
        return rows
    }

    /// Inline: the lines in the diff's own order, removed above added, the changed words marked on lines
    /// that pair up.
    public static func inline(_ diff: FileDiff) -> [DiffRow] {
        var rows: [DiffRow] = []
        for hunk in diff.hunks {
            rows.append(DiffRow(kind: .hunk, header: hunk.header))
            for run in runs(hunk.lines) {
                switch run {
                case .context(let line):
                    rows.append(contextRow(line))
                case .change(let removed, let added):
                    var lefts: [Range<Int>?] = Array(repeating: nil, count: removed.count)
                    var rights: [Range<Int>?] = Array(repeating: nil, count: added.count)
                    for index in 0..<min(removed.count, added.count) {
                        (lefts[index], rights[index]) = changedRanges(removed[index].text, added[index].text)
                    }
                    for (index, line) in removed.enumerated() {
                        rows.append(DiffRow(kind: .removed, old: DiffCell(number: line.oldNumber ?? 0, text: line.text, changed: lefts[index])))
                    }
                    for (index, line) in added.enumerated() {
                        rows.append(DiffRow(kind: .added, new: DiffCell(number: line.newNumber ?? 0, text: line.text, changed: rights[index])))
                    }
                }
            }
        }
        return rows
    }

    /// Where each change block starts, for next and previous change.
    public static func changeStarts(_ rows: [DiffRow]) -> [Int] {
        var starts: [Int] = []
        var inChange = false
        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .hunk, .context, .gap:
                inChange = false
            case .removed, .added, .changed:
                if !inChange { starts.append(index) }
                inChange = true
            }
        }
        return starts
    }

    // MARK: Pieces

    private enum Run {
        case context(DiffLine)
        case change(removed: [DiffLine], added: [DiffLine])
    }

    /// A hunk's lines as context lines and change blocks (removed lines, then added lines).
    private static func runs(_ lines: [DiffLine]) -> [Run] {
        var runs: [Run] = []
        var removed: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            if !removed.isEmpty || !added.isEmpty { runs.append(.change(removed: removed, added: added)) }
            removed = []; added = []
        }
        for line in lines {
            switch line.kind {
            case .context:
                flush()
                runs.append(.context(line))
            case .removed:
                // A removed line after added ones starts a new block.
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            }
        }
        flush()
        return runs
    }

    private static func contextRow(_ line: DiffLine) -> DiffRow {
        DiffRow(kind: .context, old: DiffCell(number: line.oldNumber ?? 0, text: line.text), new: DiffCell(number: line.newNumber ?? 0, text: line.text))
    }

    /// The differing middle of two lines, after their common start and end (in UTF-16 offsets); nil for
    /// both when the lines share too little for the marking to help, or are the same.
    static func changedRanges(_ old: String, _ new: String) -> (Range<Int>?, Range<Int>?) {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return (nil, nil) }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Never split a surrogate pair.
        if prefix > 0, prefix < a.count, UTF16.isTrailSurrogate(a[prefix]) { prefix -= 1 }
        if suffix > 0, a.count - suffix < a.count, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let shared = prefix + suffix
        guard Double(shared) >= Double(max(a.count, b.count)) / 4 else { return (nil, nil) }
        let left = prefix..<(a.count - suffix), right = prefix..<(b.count - suffix)
        return (left.isEmpty ? nil : left, right.isEmpty ? nil : right)
    }
}
