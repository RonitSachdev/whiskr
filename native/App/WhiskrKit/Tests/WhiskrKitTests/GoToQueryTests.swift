import Testing
@testable import WhiskrKit

@Suite("What is typed into Go to")
struct GoToQueryTests {
    @Test("search text, commands, a line of the open file, a file at a line")
    func kinds() {
        #expect(GoToQuery("  workbench ") == .search("workbench"))
        #expect(GoToQuery("shop web") == .search("shop web"))
        #expect(GoToQuery(">") == .commands(""))
        #expect(GoToQuery("  >  new tab ") == .commands("new tab"))
        #expect(GoToQuery(":42") == .line(42, column: nil))
        #expect(GoToQuery(":42:3") == .line(42, column: 3))
        #expect(GoToQuery("name:42") == .fileAtLine("name", line: 42, column: nil))
        #expect(GoToQuery("name:42:3") == .fileAtLine("name", line: 42, column: 3))
        #expect(GoToQuery("src/x.ts:42") == .fileAtLine("src/x.ts", line: 42, column: nil))
        #expect(GoToQuery("my file.ts:3") == .fileAtLine("my file.ts", line: 3, column: nil))
    }

    @Test("a colon with no number after it is still a search")
    func colons() {
        #expect(GoToQuery(":") == .search(":"))
        #expect(GoToQuery(":abc") == .search(":abc"))
        #expect(GoToQuery("name:") == .search("name"))
        #expect(GoToQuery("name:abc") == .search("name:abc"))
        #expect(GoToQuery("name:-3") == .search("name:-3"))
        // As compilers print it.
        #expect(GoToQuery("x.go:4:5:") == .fileAtLine("x.go", line: 4, column: 5))
        #expect(GoToQuery(":7:") == .line(7, column: nil))
        // Text before a line is always a name, even a number.
        #expect(GoToQuery("12:30") == .fileAtLine("12", line: 30, column: nil))
    }
}
