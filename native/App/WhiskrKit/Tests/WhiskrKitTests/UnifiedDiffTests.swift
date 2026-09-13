import Foundation
import Testing
@testable import WhiskrKit

@Suite("Unified diff")
struct UnifiedDiffTests {
    /// Real `git diff` output from a scratch repository (the space in the name makes git add a tab after the path).
    static let worktree = """
    diff --git a/keep.txt b/keep.txt
    index 7be73ce..a7bc997 100644
    --- a/keep.txt
    +++ b/keep.txt
    @@ -1,3 +1,4 @@
     a
     B
     c
    +d
    diff --git a/with space.txt b/with space.txt
    index 5626abf..814f4a4 100644
    --- a/with space.txt\t
    +++ b/with space.txt\t
    @@ -1 +1,2 @@
     one
    +two

    """

    /// Real `git diff --cached`: an edit, then a pure rename (no hunks), then a new file with a quoted name.
    static let cached = """
    diff --git a/keep.txt b/keep.txt
    index de98044..7be73ce 100644
    --- a/keep.txt
    +++ b/keep.txt
    @@ -1,3 +1,3 @@
     a
    -b
    +B
     c
    diff --git a/old.txt b/new.txt
    similarity index 100%
    rename from old.txt
    rename to new.txt
    diff --git "a/newdir/caf\\303\\251.txt" "b/newdir/caf\\303\\251.txt"
    new file mode 100644
    index 0000000..8ba3a16
    --- /dev/null
    +++ "b/newdir/caf\\303\\251.txt"
    @@ -0,0 +1 @@
    +n

    """

    @Test("several files: paths, hunks, line numbers")
    func multiFile() throws {
        let files = UnifiedDiff.parse(Self.worktree)
        #expect(files.count == 2)
        #expect(files[0].oldPath == "keep.txt" && files[0].newPath == "keep.txt")
        let hunk = try #require(files[0].hunks.first)
        #expect((hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount) == (1, 3, 1, 4))
        #expect(hunk.lines.map(\.kind) == [.context, .context, .context, .added])
        #expect(hunk.lines[3].newNumber == 4 && hunk.lines[3].oldNumber == nil)
        #expect(hunk.lines[2].oldNumber == 3 && hunk.lines[2].newNumber == 3)
        #expect(files[1].oldPath == "with space.txt" && files[1].newPath == "with space.txt")
        // "@@ -1 +1,2 @@": an omitted count is one.
        #expect(files[1].hunks[0].oldCount == 1 && files[1].hunks[0].newCount == 2)
        #expect(files[1].hunks[0].header == "@@ -1 +1,2 @@")
    }

    @Test("renames without hunks, new files and quoted paths")
    func cached() {
        let files = UnifiedDiff.parse(Self.cached)
        #expect(files.count == 3)
        #expect(files[0].hunks[0].lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(files[1].oldPath == "old.txt" && files[1].newPath == "new.txt" && files[1].hunks.isEmpty)
        #expect(files[2].oldPath == nil && files[2].newPath == "newdir/café.txt")
        #expect(files[2].hunks[0].lines == [DiffLine(kind: .added, text: "n", oldNumber: nil, newNumber: 1)])
    }

    @Test("deleted and binary files, the no-newline marker, and a section after the header")
    func kinds() {
        let text = """
        diff --git a/gone.swift b/gone.swift
        deleted file mode 100644
        index 1234567..0000000
        --- a/gone.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@ struct Gone {
        -let a = 1
        -let b = 2
        \\ No newline at end of file
        diff --git a/bin.dat b/bin.dat
        new file mode 100644
        index 0000000..bdc955b
        Binary files /dev/null and b/bin.dat differ
        diff --git a/img.png b/img.png
        index 1..2 100644
        GIT binary patch
        literal 5
        Mc${NkU|?VZ00D{tN&o-=
        """
        let files = UnifiedDiff.parse(text)
        #expect(files.count == 3)
        #expect(files[0].oldPath == "gone.swift" && files[0].newPath == nil)
        #expect(files[0].hunks[0].section == "struct Gone {")
        #expect(files[0].hunks[0].lines.map(\.noNewlineAtEnd) == [false, true])
        #expect(files[1].isBinary && files[1].oldPath == nil && files[1].newPath == "bin.dat" && files[1].hunks.isEmpty)
        #expect(files[2].isBinary && files[2].oldPath == "img.png")
    }

    @Test("without diff --git lines; lines that look like headers inside a hunk; an empty context line")
    func plain() {
        let text = """
        --- a/x.md
        +++ b/x.md
        @@ -1,3 +1,3 @@
        --- old rule
        +++ new rule
        \u{20}keep

        --- a/y.md
        +++ b/y.md
        @@ -5,2 +5,2 @@
        -a
        +b
        """
        let files = UnifiedDiff.parse(text)
        #expect(files.count == 2)
        #expect(files[0].hunks[0].lines.map(\.text) == ["-- old rule", "++ new rule", "keep", ""])
        #expect(files[0].hunks[0].lines.map(\.kind) == [.removed, .added, .context, .context])
        #expect(files[1].newPath == "y.md" && files[1].hunks[0].oldStart == 5)
    }

    @Test("garbage and combined diffs never crash")
    func garbage() {
        for text in ["", "@@ -x +y @@", "diff --git", "+++ b/x\n@@ -1,1000 +1,1000 @@\n+a", "--- \n+++ \n@@ @@", "diff --cc c.txt\n--- a/c.txt\n+++ b/c.txt\n@@@ -1,1 -1,1 +1,5 @@@\n++<<<<<<< HEAD\n"] {
            _ = UnifiedDiff.parse(text)
        }
        #expect(UnifiedDiff.parse("hello\nworld").isEmpty)
    }

    @Test("a file in conflict (diff --cc) reads against your side: markers and their lines added")
    func combined() {
        // As git prints it for a file both branches changed.
        let text = """
        diff --cc cart.ts
        index 41848d2,3814e08..0000000
        --- a/cart.ts
        +++ b/cart.ts
        @@@ -1,5 -1,4 +1,9 @@@ export
          one
        ++<<<<<<< HEAD
         +two ours
        ++=======
        + TWO theirs
        ++>>>>>>> other
          three
          four
         +five
        diff --git a/next.ts b/next.ts
        --- a/next.ts
        +++ b/next.ts
        @@ -1 +1 @@
        -a
        +b
        """
        let files = UnifiedDiff.parse(text)
        #expect(files.count == 2)
        let diff = files[0]
        #expect(diff.isCombined && diff.oldPath == "cart.ts" && diff.newPath == "cart.ts")
        #expect(diff.hunks.count == 1 && diff.hunks[0].oldStart == 1 && diff.hunks[0].oldCount == 5 && diff.hunks[0].newCount == 9 && diff.hunks[0].section == "export")
        let lines = diff.hunks[0].lines
        #expect(lines.map(\.text) == ["one", "<<<<<<< HEAD", "two ours", "=======", "TWO theirs", ">>>>>>> other", "three", "four", "five"])
        #expect(lines.map(\.kind) == [.context, .added, .context, .added, .added, .added, .context, .context, .context])
        #expect(lines.compactMap(\.oldNumber) == [1, 2, 3, 4, 5])
        #expect(lines.compactMap(\.newNumber) == Array(1...9))
        #expect(!files[1].isCombined && files[1].hunks[0].lines.map(\.kind) == [.removed, .added])
    }

    @Test("a merge's combined diff: lines only on the other side are left out, ones taken from yours are removed")
    func combinedRemovals() {
        let text = "diff --cc m.txt\n--- a/m.txt\n+++ b/m.txt\n@@@ -1,2 -1,2 +1,2 @@@\n  keep\n- mine\n -theirs\n++both\n"
        let lines = UnifiedDiff.parse(text)[0].hunks[0].lines
        #expect(lines.map(\.text) == ["keep", "mine", "both"])
        #expect(lines.map(\.kind) == [.context, .removed, .added])
        #expect(UnifiedDiff.combinedHunkHeader("@@@@ -1 -2,3 -4,0 +5,6 @@@@ f")?.1 == [1, 3, 0])
        #expect(UnifiedDiff.combinedHunkHeader("@@@ -1 +2 @@@") == nil)
    }

    @Test("quoted paths: octal escapes decode as UTF-8")
    func unquote() {
        #expect(UnifiedDiff.unquote("\"a/caf\\303\\251 \\\"x\\\".txt\"") == "a/café \"x\".txt")
        #expect(UnifiedDiff.unquote("plain") == "plain")
        #expect(UnifiedDiff.gitHeaderPaths("a/sp ace.txt b/sp ace.txt") == ("sp ace.txt", "sp ace.txt"))
        #expect(UnifiedDiff.gitHeaderPaths("a/one.txt b/two.txt") == ("one.txt", "two.txt"))
    }

    @Test("an untracked file as an all-added diff")
    func addedFile() {
        let diff = UnifiedDiff.addedFile(path: "new.txt", text: "a\nb\n")
        #expect(diff.oldPath == nil && diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.map(\.text) == ["a", "b"])
        #expect(diff.hunks[0].lines.map(\.newNumber) == [1, 2])
        #expect(UnifiedDiff.addedFile(path: "n", text: "a").hunks[0].lines[0].noNewlineAtEnd)
        #expect(UnifiedDiff.addedFile(path: "n", text: "").hunks.isEmpty)
    }
}

@Suite("Diff layout")
struct DiffLayoutTests {
    static let diff = UnifiedDiff.parse("""
    --- a/f.txt
    +++ b/f.txt
    @@ -1,6 +1,6 @@
     keep
    -let name = "café"
    -gone entirely
    +let name = "cafés"
    +something completely different here
    +extra
     middle
    -tail one
    +tail two
     end
    """)[0]

    @Test("side by side pairs removed and added lines in order; leftovers have one side")
    func sideBySide() {
        let rows = DiffLayout.sideBySide(Self.diff)
        #expect(rows.map(\.kind) == [.hunk, .context, .changed, .changed, .added, .context, .changed, .context])
        #expect(rows[0].header == "@@ -1,6 +1,6 @@")
        #expect(rows[2].old?.number == 2 && rows[2].new?.number == 2)
        #expect(rows[4].old == nil && rows[4].new?.text == "extra" && rows[4].new?.number == 4)
        #expect(rows[1].old?.text == "keep" && rows[1].new?.number == 1)
    }

    @Test("changed ranges are the middle after the common start and end, in UTF-16; unrelated lines get none")
    func changedRanges() {
        let rows = DiffLayout.sideBySide(Self.diff)
        // let name = "café" → "cafés": é is one UTF-16 unit, at offset 15; the inserted "s" at 16.
        #expect(rows[2].old?.changed == nil)
        #expect(rows[2].new?.changed == 16..<17)
        #expect(rows[3].old?.changed == nil && rows[3].new?.changed == nil)
        #expect(rows[6].old?.changed == 5..<8 && rows[6].new?.changed == 5..<8)
        let emoji = DiffLayout.changedRanges("a 👍 b", "a 👎 b")
        #expect(emoji.0 == 2..<4 && emoji.1 == 2..<4)
    }

    @Test("inline keeps the diff's order, with changed ranges on paired lines")
    func inline() {
        let rows = DiffLayout.inline(Self.diff)
        #expect(rows.map(\.kind) == [.hunk, .context, .removed, .removed, .added, .added, .added, .context, .removed, .added, .context])
        #expect(rows[2].new == nil && rows[4].old == nil)
        #expect(rows[4].new?.changed == 16..<17)
        #expect(rows[9].new?.changed == 5..<8)
    }

    @Test("change starts: one per block of changes")
    func starts() {
        #expect(DiffLayout.changeStarts(DiffLayout.sideBySide(Self.diff)) == [2, 6])
        #expect(DiffLayout.changeStarts(DiffLayout.inline(Self.diff)) == [2, 8])
        #expect(DiffLayout.changeStarts([]) == [])
    }
}
