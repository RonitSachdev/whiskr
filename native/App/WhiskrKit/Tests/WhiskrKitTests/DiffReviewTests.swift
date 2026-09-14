import Foundation
import Testing
@testable import WhiskrKit

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

    /// `git diff --no-index` of the two texts, in a scratch folder.
    func gitDiff(_ before: [String], _ after: [String]) throws -> FileDiff {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try (before.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try (after.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let text = try? GitRunner().run(["diff", "--no-index", "--no-color", "a.txt", "b.txt"], in: folder.path)
        let output: String
        if let text { output = text } else {
            // `git diff --no-index` exits 1 when the files differ: read its output directly.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["diff", "--no-index", "--no-color", "a.txt", "b.txt"]
            process.currentDirectoryURL = folder
            // Close-on-exec, so no process another test starts meanwhile holds it open.
            let pipe = ProcessPipe.make()
            process.standardOutput = pipe
            let reader = PipeReader([pipe])
            try process.run()
            process.waitUntilExit()
            output = String(decoding: reader.finish(by: Date().addingTimeInterval(10))[0], as: UTF8.self)
        }
        return try #require(UnifiedDiff.parse(output).first)
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

    /// Applies `patch` with git to `text` (`reverse`: -R) and returns the result.
    func apply(_ patch: String, to text: [String], reverse: Bool) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The patch names a.txt → b.txt; the file it applies to is called by the target's name.
        let name = reverse ? "b.txt" : "a.txt"
        try (text.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let patchFile = folder.appendingPathComponent("change.patch")
        try patch.write(to: patchFile, atomically: true, encoding: .utf8)
        _ = try GitRunner().run(["apply"] + (reverse ? ["-R"] : []) + [patchFile.path], in: folder.path)
        // The patch names two files, so git renames as it applies: the result is whichever is there.
        let out = ["b.txt", "a.txt"].map { folder.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }!
        let result = try String(contentsOf: out, encoding: .utf8)
        return result.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    @Test("one change applied to the old side, the others left out (staging it)")
    func stageOne() throws {
        let diff = try gitDiff(Self.old, Self.new)
        let rows = DiffLayout.folded(DiffLayout.inline(diff), diff: diff, newText: Self.new, expanded: [])
        let block = DiffLayout.changeBlocks(rows)[1]
        let lines = DiffLayout.changedLines(rows[block])
        let patch = try #require(DiffPatch.patch(diff, old: lines.old, new: lines.new, direction: .toOld))
        var expected = Self.old
        expected[19] = "line 20 changed"
        #expect(try apply(patch, to: Self.old, reverse: false) == expected)
    }

    @Test("one change reverted on the new side, the others kept (Revert Change), even inside one hunk")
    func revertOne() throws {
        // Two changes close enough to share a hunk.
        var after = Self.old
        after[9] = "line 10 changed"
        after[11] = "line 12 changed"
        let diff = try gitDiff(Self.old, after)
        #expect(diff.hunks.count == 1)
        let rows = DiffLayout.inline(diff)
        let blocks = DiffLayout.changeBlocks(rows)
        #expect(blocks.count == 2)
        let lines = DiffLayout.changedLines(rows[blocks[0]])
        let patch = try #require(DiffPatch.patch(diff, old: lines.old, new: lines.new, direction: .fromNew))
        var expected = after
        expected[9] = "line 10"
        #expect(try apply(patch, to: after, reverse: true) == expected)
        // And applied forward again it comes back (Undo Revert).
        #expect(try apply(patch.replacingOccurrences(of: "b.txt", with: "a.txt"), to: expected, reverse: false) == after)
    }

    @Test("paths git must quote are quoted")
    func quoting() {
        #expect(DiffPatch.quoted("a/src/x.ts") == "a/src/x.ts")
        #expect(DiffPatch.quoted("a/my file.ts") == "\"a/my file.ts\"")
        #expect(DiffPatch.quoted("a/café") == "\"a/caf\\303\\251\"")
        #expect(DiffPatch.patch(FileDiff(oldPath: "x", newPath: "x"), old: [1], new: [], direction: .toOld) == nil)
    }
}
