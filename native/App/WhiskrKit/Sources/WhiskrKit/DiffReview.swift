import Foundation

// Reviewing what Claude changed, one change at a time: the unchanged stretches between changes folded
// away behind a row that says how many lines they hold, and a patch of a single change, for git to stage,
// unstage or revert it alone.

/// A stretch of unchanged lines a diff leaves out, between two hunks or before the first or after the
/// last: shown folded, as "⋯ 120 unchanged lines".
public struct DiffGap: Sendable, Equatable, Hashable {
    /// The lines' numbers on the new side (1-based).
    public var newLines: ClosedRange<Int>
    /// The first one's number on the old side (the stretch is the same on both).
    public var oldStart: Int

    public init(newLines: ClosedRange<Int>, oldStart: Int) {
        self.newLines = newLines
        self.oldStart = oldStart
    }

    public var count: Int { newLines.count }
}

extension DiffLayout {
    /// `rows` (from `sideBySide` or `inline`) with each hunk's header replaced by the unchanged lines
    /// before it: folded into one `.gap` row, or, for a gap in `expanded`, those lines themselves, read
    /// from `newText` (the new side's lines). A gap of no lines leaves nothing; the gap after the last
    /// hunk is known only when `newText` is. Without `newText` nothing can be unfolded, and the gaps
    /// still say how much they hide.
    public static func folded(_ rows: [DiffRow], diff: FileDiff, newText: [String]?, expanded: Set<DiffGap>) -> [DiffRow] {
        var result: [DiffRow] = []
        result.reserveCapacity(rows.count + diff.hunks.count)
        var hunk = 0
        // Where the last hunk ended, on each side (the next unchanged line).
        var nextNew = 1, nextOld = 1
        func gap(until newEnd: Int) {
            guard newEnd >= nextNew else { return }
            let gap = DiffGap(newLines: nextNew...newEnd, oldStart: nextOld)
            if expanded.contains(gap), let newText, newEnd <= newText.count {
                for (offset, number) in gap.newLines.enumerated() {
                    let text = newText[number - 1]
                    result.append(DiffRow(kind: .context, old: DiffCell(number: gap.oldStart + offset, text: text), new: DiffCell(number: number, text: text)))
                }
            } else {
                result.append(DiffRow(kind: .gap, gap: gap))
            }
        }
        for row in rows {
            guard row.kind == .hunk else {
                result.append(row)
                continue
            }
            guard hunk < diff.hunks.count else { continue }
            let current = diff.hunks[hunk]
            hunk += 1
            // A hunk of no new lines (all removed) sits after `newStart`; otherwise it begins at it.
            let firstNew = current.newCount == 0 ? current.newStart + 1 : current.newStart
            gap(until: firstNew - 1)
            nextNew = firstNew + current.newCount
            nextOld = (current.oldCount == 0 ? current.oldStart + 1 : current.oldStart) + current.oldCount
        }
        if let newText, !diff.hunks.isEmpty { gap(until: newText.count) }
        return result
    }

    /// The change blocks: each run of removed, added or changed rows, by its first and last row.
    public static func changeBlocks(_ rows: [DiffRow]) -> [ClosedRange<Int>] {
        var blocks: [ClosedRange<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            let changed = row.kind == .removed || row.kind == .added || row.kind == .changed
            if changed, start == nil { start = index }
            if !changed, let first = start {
                blocks.append(first...(index - 1))
                start = nil
            }
        }
        if let first = start { blocks.append(first...(rows.count - 1)) }
        return blocks
    }

    /// The line numbers a block of rows changes: its removed lines' (old side) and added lines' (new side).
    public static func changedLines(_ rows: ArraySlice<DiffRow>) -> (old: Set<Int>, new: Set<Int>) {
        var old = Set<Int>(), new = Set<Int>()
        for row in rows {
            switch row.kind {
            case .removed: if let cell = row.old { old.insert(cell.number) }
            case .added: if let cell = row.new { new.insert(cell.number) }
            case .changed:
                if let cell = row.old { old.insert(cell.number) }
                if let cell = row.new { new.insert(cell.number) }
            default: break
            }
        }
        return (old, new)
    }
}

/// A patch of one change of a file's diff, the other changes beside it left as they are, as `git apply`
/// takes it (git's own "stage this hunk", made exact to the change).
public enum DiffPatch {
    public enum Direction: Sendable {
        /// Applied to the old side: `git apply --cached` stages an unstaged change.
        case toOld
        /// Reverse-applied to the new side: `git apply -R` reverts the working file's change, and
        /// `git apply -R --cached` unstages a staged one.
        case fromNew
    }

    /// The patch for the lines `old` (removed, old-side numbers) and `new` (added, new-side numbers), or
    /// nil when no hunk holds them. Every other change in their hunk is turned into what the side the patch
    /// is applied to already has: unchosen lines that side holds become context, the rest are left out.
    public static func patch(_ diff: FileDiff, old: Set<Int>, new: Set<Int>, direction: Direction) -> String? {
        guard diff.acceptsChangePatches, !old.isEmpty || !new.isEmpty else { return nil }
        guard let hunk = diff.hunks.first(where: { hunk in
            hunk.lines.contains { line in
                (line.kind == .removed && line.oldNumber.map(old.contains) == true) || (line.kind == .added && line.newNumber.map(new.contains) == true)
            }
        }) else { return nil }
        var body: [String] = []
        var oldCount = 0, newCount = 0
        func add(_ marker: Character, _ line: DiffLine) {
            body.append(String(marker) + line.text + (line.carriageReturn ? "\r" : ""))
            if line.noNewlineAtEnd { body.append("\\ No newline at end of file") }
            if marker != "+" { oldCount += 1 }
            if marker != "-" { newCount += 1 }
        }
        for line in hunk.lines {
            switch line.kind {
            case .context:
                add(" ", line)
            case .removed:
                if line.oldNumber.map(old.contains) == true { add("-", line) } else if direction == .toOld { add(" ", line) }
            case .added:
                if line.newNumber.map(new.contains) == true { add("+", line) } else if direction == .fromNew { add(" ", line) }
            }
        }
        // Each side's start: the side the patch is applied to is the hunk's own; the other follows it.
        let start = direction == .toOld ? hunk.oldStart : hunk.newStart
        let oldPath = diff.oldPath ?? "", newPath = diff.newPath ?? ""
        var lines = [
            "diff --git \(quoted("a/" + oldPath)) \(quoted("b/" + newPath))",
            "--- \(quoted("a/" + oldPath))",
            "+++ \(quoted("b/" + newPath))",
            "@@ -\(start),\(oldCount) +\(start),\(newCount) @@",
        ]
        lines += body
        return lines.joined(separator: "\n") + "\n"
    }

    /// `git diff`'s arguments for a diff whose changes `patch` can take one by one, whatever the user's git
    /// configuration: three lines of context (with `diff.context=0` a hunk has none, and `git apply` then
    /// puts it at the end of the file and says it worked), and the "a/" and "b/" a patch names its sides
    /// with (`diff.mnemonicPrefix` makes them "i/" and "w/", `diff.noprefix` drops them, and `apply`
    /// fails). The file's path goes after these, as a pathspec.
    public static func diffArguments(staged: Bool) -> [String] {
        ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "-M", "-U3", "--src-prefix=a/", "--dst-prefix=b/"] + (staged ? ["--cached"] : [])
    }

    /// A path as git writes it in a patch: in double quotes, with C escapes, when it holds a space, a quote,
    /// a backslash, a control character or anything beyond ASCII.
    static func quoted(_ path: String) -> String {
        let plain = path.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }
        guard !plain else { return path }
        var text = "\""
        for byte in path.utf8 {
            switch byte {
            case UInt8(ascii: "\""): text += "\\\""
            case UInt8(ascii: "\\"): text += "\\\\"
            case 0x09: text += "\\t"
            case 0x0A: text += "\\n"
            case 0x20..<0x7F: text.append(Character(UnicodeScalar(byte)))
            default: text += String(format: "\\%03o", byte)
            }
        }
        return text + "\""
    }
}
