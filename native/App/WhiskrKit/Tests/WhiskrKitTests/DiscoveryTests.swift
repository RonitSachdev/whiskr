import Foundation
import Testing
@testable import WhiskrKit

/// A throwaway home folder laid out as Claude Code lays out its accounts.
private struct FakeHome: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-home-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func folder(_ path: String) throws -> URL {
        let folder = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func file(_ path: String, _ contents: String, modified: Date? = nil) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
    }
}

@Suite("Accounts and folders")
struct DiscoveryTests {
    @Test("accounts are the ~/.claude and ~/.claude-<name> folders, default first, with their address")
    func accounts() throws {
        let home = try FakeHome()
        _ = try home.folder(".claude")
        _ = try home.folder(".claude-work")
        _ = try home.folder(".claude-alpha")
        _ = try home.folder(".claudette")
        _ = try home.folder(".claude-")
        try home.file(".claude.json", #"{"oauthAccount":{"emailAddress":"me@example.com"},"projects":{}}"#)
        try home.file(".claude-work/.claude.json", #"{"oauthAccount":{"emailAddress":"me@work.example"}}"#)
        try home.file(".claude-notes", "a file, not an account")

        let found = Discovery.accounts(home: home.url)
        #expect(found.map(\.name) == ["default", "alpha", "work"])
        #expect(found.map(\.email) == ["me@example.com", nil, "me@work.example"])
        #expect(found[0].configDirEnvironment == nil)
        #expect(found[2].configDirEnvironment == home.url.appendingPathComponent(".claude-work").path)
    }

    @Test("recent folders come from each account's projects, newest first, without touching the folders")
    func recentFolders() throws {
        let home = try FakeHome()
        let shop = try home.folder("code/shop")
        let blog = try home.folder("code/my blog")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        func transcript(_ cwd: String) -> String {
            #"{"type":"last-prompt","leafUuid":"x"}"# + "\n" + #"{"type":"user","cwd":"\#(cwd)","message":{"content":"hi"}}"# + "\n"
        }
        try home.file(".claude/projects/-code-shop/a.jsonl", transcript(shop.path), modified: old)
        try home.file(".claude-work/projects/-code-my-blog/b.jsonl", transcript(blog.path), modified: new)
        try home.file(".claude-work/projects/-code-shop/c.jsonl", transcript(shop.path), modified: old.addingTimeInterval(60))
        try home.file(".claude-work/projects/-code-gone/d.jsonl", transcript(home.url.appendingPathComponent("code/gone").path), modified: new)
        try home.file(".claude-work/projects/-broken/e.jsonl", "not json\n", modified: new)

        let accounts = Discovery.accounts(home: home.url)
        let folders = Discovery.recentFolders(accounts: accounts)
        // A folder that is gone is still offered (it is only checked once picked).
        let gone = home.url.appendingPathComponent("code/gone").path
        #expect(folders.map(\.path) == [gone, blog.path, shop.path])
        #expect(folders.map(\.lastUsed) == [new, new, old.addingTimeInterval(60)])

        // The app's own history joins in, the newest use of each folder winning.
        let merged = Discovery.merge(folders, [RecentFolder(path: shop.path, lastUsed: new.addingTimeInterval(1))])
        #expect(merged.map(\.path) == [shop.path, gone, blog.path])
    }

    @Test("a typed folder is expanded, standardised and checked")
    func validate() throws {
        let home = try FakeHome()
        let code = try home.folder("code")
        try home.file("notes.txt", "x")
        #expect(Discovery.validateFolder("~/code", home: home.url) == .success(code.path))
        #expect(Discovery.validateFolder("  \(code.path)/../code/  ", home: home.url) == .success(code.path))
        #expect(Discovery.validateFolder("~", home: home.url) == .success(home.url.path))
        #expect(Discovery.validateFolder("", home: home.url) == .failure(.empty))
        #expect(Discovery.validateFolder("code", home: home.url) == .failure(.notAbsolute))
        #expect(Discovery.validateFolder("~/nope", home: home.url) == .failure(.missing))
        #expect(Discovery.validateFolder("~/notes.txt", home: home.url) == .failure(.notAFolder))
    }
}

@Suite("Claude Code's own files")
struct TranscriptTests {
    @Test("the chat's name is the latest one, a chosen name winning over a generated one")
    func title() throws {
        let home = try FakeHome()
        let lines = [
            #"{"type":"ai-title","aiTitle":"First idea"}"#,
            #"{"type":"assistant","message":{"model":"claude-haiku-4-5","content":[]}}"#,
            #"{"type":"ai-title","aiTitle":"Fix the cart total"}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[]}}"#,
        ]
        try home.file("t/s1.jsonl", lines.joined(separator: "\n") + "\n")
        let path = home.url.appendingPathComponent("t/s1.jsonl").path
        #expect(Transcripts.facts(transcriptPath: path) == TranscriptFacts(title: "Fix the cart total", model: "claude-haiku-4-5"))

        try home.file("t/s1.jsonl", (lines + [#"{"type":"custom-title","customTitle":"Checkout"}"#, #"{"type":"ai-title","aiTitle":"Later"}"#]).joined(separator: "\n"))
        #expect(Transcripts.facts(transcriptPath: path).title == "Checkout")
        #expect(Transcripts.facts(transcriptPath: "/nowhere/x.jsonl") == TranscriptFacts())
        #expect(Transcripts.facts(transcriptPath: path.replacingOccurrences(of: ".jsonl", with: ".txt")) == TranscriptFacts())
    }

    @Test("only the end of a long transcript is read, and a record cut in half is skipped")
    func tail() throws {
        let home = try FakeHome()
        let filler = String(repeating: #"{"type":"user","message":{"content":"x"}}"# + "\n", count: 10_000)
        try home.file("t/long.jsonl", #"{"type":"ai-title","aiTitle":"Too early"}"# + "\n" + filler + #"{"type":"ai-title","aiTitle":"Recent"}"# + "\n")
        #expect(Transcripts.facts(transcriptPath: home.url.appendingPathComponent("t/long.jsonl").path).title == "Recent")
    }

    @Test("a helper's meta file names the call that launched it")
    func meta() throws {
        let home = try FakeHome()
        try home.file("t/s1/subagents/agent-a1.meta.json", #"{"toolUseId":"toolu_1","description":"Map the code","agentType":"Explore"}"#)
        let transcript = home.url.appendingPathComponent("t/s1.jsonl").path
        #expect(Transcripts.spawnMeta(transcriptPath: transcript, agentID: "a1") == SpawnMeta(toolUseID: "toolu_1", description: "Map the code", agentType: "Explore"))
        #expect(Transcripts.spawnMeta(transcriptPath: transcript, agentID: "missing") == nil)
    }

    @Test("an agent id that is not plainly an id never becomes a path")
    func unsafeIDs() throws {
        let home = try FakeHome()
        try home.file("t/outside.meta.json", #"{"toolUseId":"SHOULD-NOT-BE-READ"}"#)
        let transcript = home.url.appendingPathComponent("t/s1.jsonl").path
        for id in ["../../outside", "a/b", "", String(repeating: "x", count: 200), "..", "é"] {
            #expect(Transcripts.helperFile(transcriptPath: transcript, agentID: id, ending: ".meta.json") == nil, "\(id)")
            #expect(Transcripts.spawnMeta(transcriptPath: transcript, agentID: id) == nil)
        }
        #expect(Transcripts.helperFile(transcriptPath: transcript, agentID: "a-1_b", ending: ".jsonl") == home.url.appendingPathComponent("t/s1/subagents/agent-a-1_b.jsonl").path)
    }
}
