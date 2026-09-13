import Foundation
import Testing
@testable import WhiskrKit

@Suite("Git status")
struct GitStatusTests {
    /// Real output of `git -c core.quotepath=false status --porcelain=v2 -z --branch --untracked-files=all
    /// --ignored=matching` in a scratch repository: a merge conflict, a staged and further edited file, a
    /// staged rename, an edit in a file with a space, an untracked file with an accent, ignored folder and file.
    static let real = "# branch.oid 1768d6de2b12cf3c11a4d6d3e1688c701418e068\u{0}# branch.head main\u{0}"
        + "1 MM N... 100644 100644 100644 de980441c3ab03a8c07dda1ad27b8a11f39deb1e 7be73ce3c1b1cdaea86e8168dfee8575175953bf keep.txt\u{0}"
        + "2 R. N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba5596147a26cb 587be6b4c3f93f93c489c0111bba5596147a26cb R100 new.txt\u{0}old.txt\u{0}"
        + "1 .M N... 100644 100644 100644 5626abf0f72e58d7a153368ba57db4c673c0e171 5626abf0f72e58d7a153368ba57db4c673c0e171 with space.txt\u{0}"
        + "u UU N... 100644 100644 100644 100644 f2ad6c76f0115a6ba5b00456a849810e7ec0af20 b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd conflict.txt\u{0}"
        + "? newdir/café.txt\u{0}! build/\u{0}! debug.log\u{0}"

    @Test("a real repository's status: branch, entries and the lists")
    func real() {
        let status = GitStatus.parse(Data(Self.real.utf8))
        #expect(status.branch == "main")
        #expect(status.commit == "1768d6d")
        #expect(status.upstream == nil && status.ahead == 0 && status.behind == 0)
        #expect(status.entries.count == 7)
        #expect(status.staged.map(\.path) == ["keep.txt", "new.txt"])
        #expect(status.staged[1].originalPath == "old.txt" && status.staged[1].index == .renamed)
        #expect(status.unstaged.map(\.path) == ["conflict.txt", "keep.txt", "with space.txt"])
        #expect(status.unstaged[0].isConflicted)
        #expect(status.untracked.map(\.path) == ["newdir/café.txt"])
        #expect(status.ignored == ["build/", "debug.log"])
        // keep.txt is in both lists but counted once.
        #expect(status.changeCount == 5)
    }

    @Test("decorations: the working tree first, then the index; folders take the strongest state inside")
    func decorations() {
        let status = GitStatus.parse(Data(Self.real.utf8))
        #expect(status.decorations["keep.txt"] == .modified)
        #expect(status.decorations["new.txt"] == .renamed)
        #expect(status.decorations["conflict.txt"] == .conflicted)
        #expect(status.decorations["newdir/café.txt"] == .untracked)
        #expect(status.decorations["build"] == nil)
        #expect(status.folderDecorations == ["newdir": .untracked])

        let nested = GitStatus.parse(Data("1 .M N... 1 1 1 a b src/app/a.swift\u{0}? src/new.swift\u{0}1 D. N... 1 1 1 a b src/app/gone.swift\u{0}".utf8))
        #expect(nested.folderDecorations["src/app"] == .deleted)
        #expect(nested.folderDecorations["src"] == .deleted)
        #expect(nested.decorations["src/app/gone.swift"] == .deleted)
    }

    @Test("ignored: listed paths, and everything inside an ignored folder")
    func ignored() {
        let status = GitStatus.parse(Data(Self.real.utf8))
        #expect(status.isIgnored("build"))
        #expect(status.isIgnored("build/"))
        #expect(status.isIgnored("build/out/deep.o"))
        #expect(status.isIgnored("debug.log"))
        #expect(!status.isIgnored("builder"))
        #expect(!status.isIgnored("keep.txt"))
    }

    @Test("detached head, initial commit, upstream and ahead/behind")
    func header() {
        let detached = GitStatus.parse(Data("# branch.oid abcdef1234567\u{0}# branch.head (detached)\u{0}".utf8))
        #expect(detached.branch == nil && detached.commit == "abcdef1")
        let initial = GitStatus.parse(Data("# branch.oid (initial)\u{0}# branch.head main\u{0}".utf8))
        #expect(initial.commit == nil && initial.branch == "main")
        let tracking = GitStatus.parse(Data("# branch.head feature/x\u{0}# branch.upstream origin/feature/x\u{0}# branch.ab +3 -12\u{0}".utf8))
        #expect(tracking.upstream == "origin/feature/x" && tracking.ahead == 3 && tracking.behind == 12)
    }

    @Test("states, letters, unmerged pairs and paths with spaces")
    func states() {
        let output = "1 A. N... 0 1 1 a b added file.txt\u{0}1 .D N... 1 1 0 a b gone.txt\u{0}1 T. N... 1 1 1 a b link\u{0}"
            + "u AA N... 1 1 1 1 a b c both added.txt\u{0}u DU N... 1 1 1 1 a b c deleted by us.txt"
        let status = GitStatus.parse(Data(output.utf8))
        #expect(status.entries.map(\.path) == ["added file.txt", "gone.txt", "link", "both added.txt", "deleted by us.txt"])
        #expect(status.staged.map(\.path) == ["added file.txt", "link"])
        #expect(status.entries[2].index == .typeChanged)
        #expect(status.unstaged.map(\.path) == ["both added.txt", "deleted by us.txt", "gone.txt"])
        #expect(GitFileState.modified.letter == "M" && GitFileState.untracked.letter == "?" && GitFileState.conflicted.letter == "U")
        #expect(GitFileState.unmodified.letter == "")
    }

    @Test("garbage and truncated records never crash")
    func garbage() {
        for text in ["", "\u{0}", "1 MM", "2 R. N... 1 1 1 a b R100 renamed.txt", "x y z\u{0}?\u{0}!", "# branch.ab nonsense"] {
            _ = GitStatus.parse(Data(text.utf8))
        }
        let renamed = GitStatus.parse(Data("2 R. N... 1 1 1 a b R100 renamed.txt".utf8))
        #expect(renamed.entries.first?.path == "renamed.txt" && renamed.entries.first?.originalPath == nil)
        #expect(GitStatus.parse(Data([0xff, 0xfe, 0])).entries.isEmpty)
    }
}
