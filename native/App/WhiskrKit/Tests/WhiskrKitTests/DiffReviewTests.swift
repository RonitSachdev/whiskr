import Foundation
import Testing
@testable import WhiskrKit

/// A throwaway repository with one file, `f.txt`, committed: diffs made and patches applied as the app
/// makes and applies them (`DiffPatch.diffArguments`, `git apply`), against the index and the working file.
struct ScratchRepository {
    let folder: URL
    let git = GitRunner()

    /// `committed` as f.txt's commit; `config` set in the repository (the user's own git settings).
    init(committing committed: Data, config: [String: String] = [:]) throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        folder = made.resolvingSymlinksInPath()
        try git.run(["init", "--quiet", "--initial-branch=main"], in: folder.path)
        // Line breaks exactly as written, whatever the global settings say.
        try git.run(["config", "core.autocrlf", "false"], in: folder.path)
        try write(committed)
        try git.run(["add", "f.txt"], in: folder.path)
        try git.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "first"],
                    in: folder.path)
        for (name, value) in config { try git.run(["config", name, value], in: folder.path) }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func write(_ data: Data, to name: String = "f.txt") throws {
        try data.write(to: folder.appendingPathComponent(name))
    }

    var working: Data { (try? Data(contentsOf: folder.appendingPathComponent("f.txt"))) ?? Data() }

    func indexed(_ name: String = "f.txt") throws -> String {
        try git.run(["show", ":0:" + name], in: folder.path)
    }

    /// The file's unstaged (or staged) diff, as the diff page reads it.
    func diff(_ name: String = "f.txt", staged: Bool = false) throws -> FileDiff {
        try #require(UnifiedDiff.parse(try git.run(DiffPatch.diffArguments(staged: staged), paths: [name], in: folder.path)).first)
    }

    /// Stage Change (`cached`), Unstage Change (`cached`, `reverse`) or Revert Change (`reverse`).
    func apply(_ patch: String, cached: Bool, reverse: Bool) throws {
        let file = folder.appendingPathComponent(".git/change.patch")
        try Data(patch.utf8).write(to: file)
        try git.run(["apply", "--whitespace=nowarn"] + (cached ? ["--cached"] : []) + (reverse ? ["-R"] : []) + [file.path], in: folder.path)
    }
}

@Suite("Reviewing a diff: folded stretches, and one change at a time")
struct DiffReviewTests {
    /// A diff of a 30-line file with lines 5 and 20 changed and one line added after 25.
    static let old = (1...30).map { "line \($0)" }
    static var new: [String] {
        var lines = old
        lines[4] = "line 5 changed"
        lines[19] = "line 20 changed"
        lines.insert("added after 25", at: 25)
        return lines
    }

    static func text(_ lines: [String], lineBreak: String = "\n") -> Data {
        Data((lines.joined(separator: lineBreak) + lineBreak).utf8)
    }

    /// The diff of `before` (committed) to `after` (the working file).
    func gitDiff(_ before: [String], _ after: [String]) throws -> FileDiff {
        let repository = try ScratchRepository(committing: Self.text(before))
        defer { repository.remove() }
        try repository.write(Self.text(after))
        return try repository.diff()
    }

    @Test("unchanged stretches fold into rows that count them; the one after the last hunk too")
    func folds() throws {
        let diff = try gitDiff(Self.old, Self.new)
        let rows = DiffLayout.folded(DiffLayout.inline(diff), diff: diff, newText: Self.new, expanded: [])
        let gaps = rows.compactMap(\.gap)
        #expect(!rows.contains { $0.kind == .hunk })
        // Lines 1 (before the first hunk at 2) … and the end of the file after the last hunk.
        #expect(gaps.first?.newLines.lowerBound == 1)
        #expect(gaps.last?.newLines.upperBound == Self.new.count)
        // Every new line is either in a gap or in a row.
        let shown = Set(rows.compactMap { $0.kind == .removed ? nil : $0.new?.number })
        let folded = Set(gaps.flatMap { Array($0.newLines) })
        #expect(shown.union(folded) == Set(1...Self.new.count))
        #expect(shown.isDisjoint(with: folded))
        // Next change skips the folds: three changes.
        #expect(DiffLayout.changeStarts(rows).count == 3)
        #expect(DiffLayout.changeBlocks(rows).count == 3)
    }

    @Test("an unfolded stretch shows its lines, numbered on both sides")
    func unfolds() throws {
        let diff = try gitDiff(Self.old, Self.new)
        let gaps = DiffLayout.folded(DiffLayout.sideBySide(diff), diff: diff, newText: Self.new, expanded: []).compactMap(\.gap)
        let middle = gaps[1]
        let rows = DiffLayout.folded(DiffLayout.sideBySide(diff), diff: diff, newText: Self.new, expanded: [middle])
        #expect(!rows.compactMap(\.gap).contains(middle))
        let first = try #require(rows.first { $0.new?.number == middle.newLines.lowerBound && $0.kind == .context })
        #expect(first.old?.number == middle.oldStart)
        #expect(first.new?.text == Self.new[middle.newLines.lowerBound - 1])
        // Without the new side's text, folds stay folded.
        #expect(DiffLayout.folded(DiffLayout.inline(diff), diff: diff, newText: nil, expanded: [middle]).contains { $0.gap == middle })
    }

    @Test("one change staged alone, the others left out of the index")
    func stageOne() throws {
        let repository = try ScratchRepository(committing: Self.text(Self.old))
        defer { repository.remove() }
        try repository.write(Self.text(Self.new))
        let diff = try repository.diff()
        let rows = DiffLayout.folded(DiffLayout.inline(diff), diff: diff, newText: Self.new, expanded: [])
        let lines = DiffLayout.changedLines(rows[DiffLayout.changeBlocks(rows)[1]])
        let patch = try #require(DiffPatch.patch(diff, old: lines.old, new: lines.new, direction: .toOld))
        try repository.apply(patch, cached: true, reverse: false)
        var expected = Self.old
        expected[19] = "line 20 changed"
        #expect(try repository.indexed() == String(decoding: Self.text(expected), as: UTF8.self))
        // Unstaged again from the staged diff, the index is back to the commit.
        let staged = try repository.diff(staged: true)
        let stagedRows = DiffLayout.inline(staged)
        let back = DiffLayout.changedLines(stagedRows[DiffLayout.changeBlocks(stagedRows)[0]])
        try repository.apply(try #require(DiffPatch.patch(staged, old: back.old, new: back.new, direction: .fromNew)), cached: true, reverse: true)
        #expect(try repository.indexed() == String(decoding: Self.text(Self.old), as: UTF8.self))
    }

    @Test("one change reverted in the working file, the others kept (Revert Change), even inside one hunk")
    func revertOne() throws {
        // Two changes close enough to share a hunk.
        var after = Self.old
        after[9] = "line 10 changed"
        after[11] = "line 12 changed"
        let repository = try ScratchRepository(committing: Self.text(Self.old))
        defer { repository.remove() }
        try repository.write(Self.text(after))
        let diff = try repository.diff()
        #expect(diff.hunks.count == 1)
        let rows = DiffLayout.inline(diff)
        let blocks = DiffLayout.changeBlocks(rows)
        #expect(blocks.count == 2)
        let lines = DiffLayout.changedLines(rows[blocks[0]])
        let patch = try #require(DiffPatch.patch(diff, old: lines.old, new: lines.new, direction: .fromNew))
        try repository.apply(patch, cached: false, reverse: true)
        var expected = after
        expected[9] = "line 10"
        #expect(repository.working == Self.text(expected))
        // And applied forward again it comes back (Undo Revert).
        try repository.apply(patch, cached: false, reverse: false)
        #expect(repository.working == Self.text(after))
    }

    @Test("a Windows file's lines come apart, and one change of it stages and reverts byte for byte")
    func windowsLineEndings() throws {
        var lines = Self.old
        lines[4] = "line 5 changed"
        lines[19] = "line 20 changed"
        let before = Self.text(Self.old, lineBreak: "\r\n"), after = Self.text(lines, lineBreak: "\r\n")
        let repository = try ScratchRepository(committing: before)
        defer { repository.remove() }
        try repository.write(after)
        let diff = try repository.diff()
        #expect(diff.hunks.count == 2)
        let changed = try #require(diff.hunks.first?.lines.first { $0.kind == .added })
        #expect(changed.text == "line 5 changed" && changed.carriageReturn)
        let rows = DiffLayout.inline(diff)
        let blocks = DiffLayout.changeBlocks(rows)
        #expect(blocks.count == 2)
        // Staging the second change: the index takes it alone, its line breaks untouched.
        let second = DiffLayout.changedLines(rows[blocks[1]])
        try repository.apply(try #require(DiffPatch.patch(diff, old: second.old, new: second.new, direction: .toOld)), cached: true, reverse: false)
        var staged = Self.old
        staged[19] = "line 20 changed"
        #expect(try repository.indexed() == String(decoding: Self.text(staged, lineBreak: "\r\n"), as: UTF8.self))
        // Reverting the first: the working file loses it alone.
        let first = DiffLayout.changedLines(rows[blocks[0]])
        try repository.apply(try #require(DiffPatch.patch(diff, old: first.old, new: first.new, direction: .fromNew)), cached: false, reverse: true)
        var reverted = lines
        reverted[4] = "line 5"
        #expect(repository.working == Self.text(reverted, lineBreak: "\r\n"))
        // An untracked Windows file reads as its lines too.
        let added = UnifiedDiff.addedFile(path: "w.txt", text: "one\r\ntwo\r\n")
        #expect(added.hunks.first?.lines.map(\.text) == ["one", "two"])
        #expect(added.hunks.first?.lines.allSatisfy(\.carriageReturn) == true)
    }

    @Test("the user's diff.context=0, mnemonicPrefix and noprefix change nothing: the change lands on its own line")
    func userGitSettings() throws {
        let old = (1...20).map(String.init)
        let repository = try ScratchRepository(committing: Self.text(old),
                                               config: ["diff.context": "0", "diff.mnemonicPrefix": "true", "diff.noprefix": "true"])
        defer { repository.remove() }
        var new = old
        new.insert("after 12", at: 12)
        new.remove(at: 3)
        try repository.write(Self.text(new))
        let diff = try repository.diff()
        let rows = DiffLayout.inline(diff)
        let blocks = DiffLayout.changeBlocks(rows)
        #expect(blocks.count == 2)
        // Staging the insertion alone puts it after line 12, not at the end of the file.
        let insertion = DiffLayout.changedLines(rows[blocks[1]])
        try repository.apply(try #require(DiffPatch.patch(diff, old: insertion.old, new: insertion.new, direction: .toOld)), cached: true, reverse: false)
        var expected = old
        expected.insert("after 12", at: 12)
        #expect(try repository.indexed() == String(decoding: Self.text(expected), as: UTF8.self))
        // Reverting the deletion of line 4 puts it back in its place.
        let deletion = DiffLayout.changedLines(rows[blocks[0]])
        try repository.apply(try #require(DiffPatch.patch(diff, old: deletion.old, new: deletion.new, direction: .fromNew)), cached: false, reverse: true)
        var restored = new
        restored.insert("4", at: 3)
        #expect(repository.working == Self.text(restored))
    }

    @Test("added, deleted, renamed and submodule diffs take no single-change patch")
    func wholeFilesOnly() throws {
        let repository = try ScratchRepository(committing: Self.text(Self.old))
        defer { repository.remove() }
        // Deleted in the working tree.
        try FileManager.default.removeItem(at: repository.folder.appendingPathComponent("f.txt"))
        let deleted = try repository.diff()
        #expect(deleted.newPath == nil && !deleted.acceptsChangePatches)
        #expect(DiffPatch.patch(deleted, old: [1], new: [], direction: .toOld) == nil)
        // Renamed in the index.
        try repository.write(Self.text(Self.old), to: "g.txt")
        try repository.git.run(["add", "-A"], in: repository.folder.path)
        let renamed = try repository.git.run(DiffPatch.diffArguments(staged: true), in: repository.folder.path)
        let rename = try #require(UnifiedDiff.parse(renamed).first)
        #expect(rename.oldPath == "f.txt" && rename.newPath == "g.txt" && !rename.acceptsChangePatches)
        // A new file in the index.
        try repository.write(Self.text(["new"]), to: "n.txt")
        try repository.git.run(["add", "n.txt"], in: repository.folder.path)
        let added = try repository.diff("n.txt", staged: true)
        #expect(added.oldPath == nil && !added.acceptsChangePatches)
        #expect(DiffPatch.patch(added, old: [], new: [1], direction: .fromNew) == nil)
        // A submodule's commit.
        let submodule = try #require(UnifiedDiff.parse("""
        diff --git a/sub b/sub
        index 1111111..2222222 160000
        --- a/sub
        +++ b/sub
        @@ -1 +1 @@
        -Subproject commit 1111111111111111111111111111111111111111
        +Subproject commit 2222222222222222222222222222222222222222

        """).first)
        #expect(submodule.isSubmodule && !submodule.acceptsChangePatches)
    }

    @Test("paths git must quote are quoted")
    func quoting() {
        #expect(DiffPatch.quoted("a/src/x.ts") == "a/src/x.ts")
        #expect(DiffPatch.quoted("a/my file.ts") == "\"a/my file.ts\"")
        #expect(DiffPatch.quoted("a/café") == "\"a/caf\\303\\251\"")
        #expect(DiffPatch.patch(FileDiff(oldPath: "x", newPath: "x"), old: [1], new: [], direction: .toOld) == nil)
    }
}
