import Foundation
import Testing
@testable import WhiskrKit

@Suite("Fuzzy matching")
struct FuzzyMatchTests {
    @Test("letters in order match; out of order or missing do not")
    func order() {
        #expect(FuzzyMatch.match("swb", in: "shop-web") != nil)
        #expect(FuzzyMatch.match("bws", in: "shop-web") == nil)
        #expect(FuzzyMatch.match("shopx", in: "shop-web") == nil)
        #expect(FuzzyMatch.match("", in: "anything")?.isPrefix == true)
    }

    @Test("case, accents and spaces in the query are ignored")
    func folding() {
        #expect(FuzzyMatch.match("CAFE", in: "café-api") != nil)
        #expect(FuzzyMatch.match("shop web", in: "shop-web")?.offsets == [0, 1, 2, 3, 5, 6, 7])
    }

    @Test("word starts and runs beat scattered letters; a prefix beats everything")
    func scoring() throws {
        let starts = try #require(FuzzyMatch.match("nr", in: "Next Request"))
        let scattered = try #require(FuzzyMatch.match("nr", in: "Change Branch"))
        #expect(starts.score > scattered.score)
        #expect(starts.offsets == [0, 5])
        let prefix = try #require(FuzzyMatch.match("new", in: "New Tab"))
        let inside = try #require(FuzzyMatch.match("new", in: "Renew Tab"))
        #expect(prefix.isPrefix && !inside.isPrefix && prefix.score > inside.score)
        // camelCase and punctuation start words too.
        #expect(FuzzyMatch.match("gtn", in: "goToNext")?.offsets == [0, 2, 4])
    }

    @Test("every word must match, in any order; the offsets are all of theirs")
    func words() throws {
        let match = try #require(FuzzyMatch.match("java main", in: "src/main/java/App.java"))
        #expect(match.offsets == [4, 5, 6, 7, 9, 10, 11, 12])
        #expect(FuzzyMatch.match("main kotlin", in: "src/main/java/App.java") == nil)
        #expect(FuzzyMatch.Query("  a \"b c\" d").words.map(\.text) == ["a", "b c", "d"])
        #expect(FuzzyMatch.Query("\"ben").words == [FuzzyMatch.Query.Word(text: "ben", isContiguous: true, letters: ["b", "e", "n"])])
        #expect(FuzzyMatch.Query(" \"\" ").isEmpty)
    }

    @Test("a word in quotes matches only side by side")
    func quoted() {
        #expect(FuzzyMatch.match("\"bench+\"", in: "Workbench+Scene.swift")?.offsets == [4, 5, 6, 7, 8, 9])
        #expect(FuzzyMatch.match("\"bench+\"", in: "bench/x+y") == nil)
        #expect(FuzzyMatch.match("bench+", in: "bench/x+y") != nil)
        #expect(FuzzyMatch.match("\"SCENE\"", in: "Workbench+Scene.swift") != nil)
    }

    @Test("after a slash beats after other punctuation, which beats a capital, which beats mid-word")
    func boundaries() throws {
        let scores = try ["a/b", "a-b", "aB", "ab"].map { try #require(FuzzyMatch.match("b", in: $0)).score }
        #expect(scores == scores.sorted(by: >) && Set(scores).count == 4)
    }

    @Test("of two names a query starts, the shorter wins")
    func shorterPrefix() throws {
        let short = try #require(FuzzyMatch.match("window", in: "window.ts"))
        let long = try #require(FuzzyMatch.match("window", in: "windowActions.ts"))
        #expect(short.isPrefix && long.isPrefix && short.score > long.score)
    }
}

@Suite("Palette ranking")
struct PaletteRankingTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func entry(_ id: String, _ kind: PaletteEntry.Kind, _ title: String, detail: String = "", keywords: [String] = [],
               status: AgentStatus? = nil, pinned: Bool = false, since: Double? = nil, tab: String? = nil) -> PaletteEntry {
        PaletteEntry(id: id, kind: kind, title: title, detail: detail, keywords: keywords, status: status, pinned: pinned,
                     since: since.map { Date(timeIntervalSince1970: $0) }, tab: tab)
    }

    @Test("title prefix, then loose title, then folder or branch, then the state's words")
    func tiers() {
        let entries = [
            entry("k", .claude, "Fix cart", keywords: ["needs you"]),
            entry("d", .workspace, "api", detail: "~/code/shop · main"),
            entry("l", .tab, "the shopping list"),
            entry("p", .workspace, "shop-web"),
        ]
        let ranked = PaletteRanking.rank(entries, query: "shop", usage: PaletteUsage(), now: now).map(\.id)
        #expect(ranked == ["p", "l", "d"])
        #expect(PaletteRanking.rank(entries, query: "needs", usage: PaletteUsage(), now: now).map(\.id) == ["k"])
    }

    @Test("equal matches: pinned first, then the most used lately")
    func ties() {
        var usage = PaletteUsage()
        usage.record("b", now: now)
        let entries = [entry("a", .tab, "tests"), entry("b", .tab, "tests"), entry("c", .tab, "tests", pinned: true)]
        #expect(PaletteRanking.rank(entries, query: "tests", usage: usage, now: now).map(\.id) == ["c", "b", "a"])
    }

    @Test("use counts fade by half each week and survive saving")
    func frecency() {
        var usage = PaletteUsage()
        usage.record("x", now: now)
        usage.record("x", now: now)
        #expect(usage.score("x", now: now) == 2)
        #expect(abs(usage.score("x", now: now.addingTimeInterval(7 * 86_400)) - 1) < 0.0001)
        #expect(PaletteUsage(data: usage.data) == usage)
        #expect(PaletteUsage(data: Data("nonsense".utf8)) == PaletteUsage())
    }

    @Test("empty query: requests oldest first, then finished, then pinned, recent places and used commands")
    func sections() {
        var usage = PaletteUsage()
        usage.record("cmd.split", now: now)
        let entries = [
            entry("late", .claude, "b", status: .blocked, since: 20),
            entry("early", .claude, "a", status: .blocked, since: 10),
            entry("done", .claude, "c", status: .done, since: 5),
            entry("pin", .claude, "d", status: .working, pinned: true),
            entry("tab1", .tab, "e"),
            entry("cmd.split", .command, "Split Right"),
            entry("cmd.never", .command, "Zoom"),
        ]
        let sections = PaletteRanking.sections(entries, recent: ["tab1", "early", "gone"], usage: usage, now: now)
        #expect(sections.waiting.map(\.id) == ["early", "late", "done"])
        #expect(sections.pinned.map(\.id) == ["pin"])
        #expect(sections.recent.map(\.id) == ["tab1"])
        #expect(sections.commands.map(\.id) == ["cmd.split"])
    }

    @Test("a place is listed once: a tab whose Claude waits or is pinned is not under Recent too")
    func onePlaceOnce() {
        let entries = [
            entry("claude:a", .claude, "a", status: .blocked, since: 1, tab: "tab:a"),
            entry("claude:b", .claude, "b", status: .working, pinned: true, tab: "tab:b"),
            entry("tab:a", .tab, "A", tab: "tab:a"),
            entry("tab:b", .tab, "B", tab: "tab:b"),
            entry("tab:c", .tab, "C", tab: "tab:c"),
        ]
        let sections = PaletteRanking.sections(entries, recent: ["tab:a", "tab:b", "tab:c"], usage: PaletteUsage(), now: now)
        #expect(sections.waiting.map(\.id) == ["claude:a"])
        #expect(sections.pinned.map(\.id) == ["claude:b"])
        #expect(sections.recent.map(\.id) == ["tab:c"])
    }
}

@Suite("Git branch")
struct GitHeadTests {
    @Test("HEAD names a branch, or a commit when detached")
    func heads() {
        #expect(GitHead.branch(head: "ref: refs/heads/fix-cart\n") == "fix-cart")
        #expect(GitHead.branch(head: "ref: refs/heads/feature/a/b") == "feature/a/b")
        #expect(GitHead.branch(head: "3f9c2a1d7e8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d\n") == "3f9c2a1")
        #expect(GitHead.branch(head: "garbage") == nil)
    }

    @Test("found from a folder deep inside, through a worktree's .git file too")
    func finding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("githead-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("shop")
        let deep = repo.appendingPathComponent("src/cart")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let head = try #require(GitHead.find(from: deep.path))
        #expect(head.branch == "main" && head.name == "shop" && head.root == repo.standardizedFileURL.path)

        let worktree = root.appendingPathComponent("shop-fix")
        let linked = repo.appendingPathComponent(".git/worktrees/fix")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "ref: refs/heads/fix-cart\n".write(to: linked.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: ../shop/.git/worktrees/fix\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(GitHead.find(from: worktree.path)?.branch == "fix-cart")
        #expect(GitHead.find(from: root.path) == nil)
    }
}

@Suite("Alerts")
struct AlertTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test("the three sounds are short, soft, and start and end in silence")
    func sounds() {
        for sound in AlertSound.allCases {
            let samples = sound.samples
            let seconds = Double(samples.count) / Double(AlertSound.sampleRate)
            #expect(seconds <= 0.4)
            #expect(samples.map(abs).max()! < 0.9)
            #expect(abs(samples.first!) < 0.01 && abs(samples.last!) < 0.01)
            #expect(sound.wav.count == 44 + samples.count * 2)
        }
        #expect(Double(AlertSound.finished.samples.count) / Double(AlertSound.sampleRate) <= 0.16)
    }

    @Test("one at a time, two seconds apart, the most important waiting one first, never twice")
    func spacing() {
        var queue = AlertQueue()
        queue.offer(.finished, key: "a", now: t0)
        queue.offer(.request, key: "b", now: t0)
        #expect(queue.take(now: t0, lastKey: nil, paused: false) == .request)
        queue.offer(.error, key: "c", now: t0.addingTimeInterval(0.5))
        #expect(queue.take(now: t0.addingTimeInterval(1), lastKey: nil, paused: false) == nil)
        #expect(queue.take(now: t0.addingTimeInterval(2), lastKey: nil, paused: false) == .error)
        queue.offer(.request, key: "b", now: t0.addingTimeInterval(5))
        #expect(!queue.isWaiting)
    }

    @Test("waits for a pause in typing, but not longer than five seconds; nothing while paused")
    func typing() {
        var queue = AlertQueue()
        queue.offer(.request, key: "a", now: t0)
        #expect(queue.take(now: t0.addingTimeInterval(0.5), lastKey: t0.addingTimeInterval(0.4), paused: false) == nil)
        #expect(queue.take(now: t0.addingTimeInterval(5), lastKey: t0.addingTimeInterval(4.9), paused: false) == .request)
        queue.offer(.finished, key: "b", now: t0.addingTimeInterval(10))
        #expect(queue.take(now: t0.addingTimeInterval(10), lastKey: nil, paused: true) == nil)
        #expect(!queue.isWaiting)
    }

    @Test("paused until tomorrow means eight in the morning")
    func pause() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 22))!
        let until = AlertPause.untilTomorrow(from: evening, calendar: calendar)
        #expect(calendar.dateComponents([.day, .hour], from: until) == DateComponents(day: 14, hour: 8))
        #expect(AlertPause.isPaused(until: until, now: evening))
        #expect(!AlertPause.isPaused(until: nil, now: evening))
    }
}

@Suite("Places")
struct PlacesTests {
    @Test("paths shortened, folders named")
    func names() {
        #expect(Places.abbreviate("/Users/a/code/shop", home: "/Users/a") == "~/code/shop")
        #expect(Places.abbreviate("/Users/ab", home: "/Users/a") == "/Users/ab")
        #expect(Places.name("/Users/a", home: "/Users/a") == "~")
        #expect(Places.name("/Users/a/shop/.work", home: "/Users/a") == "shop/.work")
    }

    @Test("recent folders: opened here first, then Claude's, each once, without home or open ones")
    func recents() {
        let date = Date(timeIntervalSince1970: 0)
        let opened = [RecentFolder(path: "/p/shop", lastUsed: date), RecentFolder(path: "/h", lastUsed: date)]
        let claude = [RecentFolder(path: "/p/api", lastUsed: date), RecentFolder(path: "/p/shop", lastUsed: date), RecentFolder(path: "/p/open", lastUsed: date),
                      RecentFolder(path: "/private/tmp/run/work", lastUsed: date)]
        let list = Places.recents(opened: opened, claude: claude, excluding: ["/p/open"], home: "/h")
        #expect(list.map(\.path) == ["/p/shop", "/p/api"])
        #expect(Places.recents(opened: opened + claude, claude: [], home: "/h", limit: 1).count == 1)
    }

    @Test("status bar counts")
    func status() {
        let summary = StatusSummary(statuses: [.blocked, .working, .blocked, .done])
        #expect(summary.claudes == 4 && summary.needYou == 2)
    }
}
