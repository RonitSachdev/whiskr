import Foundation
import Testing
@testable import WhiskrKit

/// The real files, counting which paths were opened.
private final class CountingFiles: HelperTranscriptFiles, @unchecked Sendable {
    private(set) var opened: [String] = []

    func open(_ path: String) -> (any HelperTranscriptHandle)? {
        opened.append(path)
        return LocalHelperTranscriptFiles().open(path)
    }
}

@Suite("Reading helpers' transcripts")
struct HelperTranscriptTests {
    private func read(_ t: TempSession, _ agentID: String = "a", from: HelperBookmark = .start, files: any HelperTranscriptFiles = LocalHelperTranscriptFiles()) -> HelperReadResult {
        HelperTranscript.read(HelperRead(sessionID: "s1", agentID: agentID, transcriptPath: t.transcript, from: from), files: files)
    }

    @Test("only what was appended since the bookmark is read, as tasks and replies")
    func appends() throws {
        let t = try TempSession()
        try t.write("a", [t.task("u1", "Trace the tax rules."), t.says("u2", words("Reading tax.ts."))])
        let first = read(t)
        #expect(first.said.map(\.text) == ["Trace the tax rules.", "Reading tax.ts."])
        #expect(first.said.map(\.kind) == [.task, .reply])
        #expect(first.said.first?.at == TempSession.stamp(0))
        #expect(first.bookmark.offset == UInt64(try t.contents("a").count))

        #expect(read(t, from: first.bookmark).said.isEmpty)
        try t.append("a", t.says("u3", words("Done.")))
        #expect(read(t, from: first.bookmark).said.map(\.text) == ["Done."])
    }

    @Test("a half-written line waits, and a character split across reads is joined whole")
    func partialLine() throws {
        let t = try TempSession()
        let line = Data(t.says("u1", words("Tax comes after the discount ☕")).utf8)
        let cut = try #require(line.firstRange(of: Data("☕".utf8))).lowerBound + 1
        try t.write("a", line.prefix(cut))
        let first = read(t)
        #expect(first.said.isEmpty)
        #expect(first.bookmark.partial?.count == cut)

        try t.append("a", line.suffix(from: cut))
        let second = read(t, from: first.bookmark)
        #expect(second.said.map(\.text) == ["Tax comes after the discount ☕"])
        #expect(second.bookmark.partial == nil)
    }

    @Test("a replaced or shortened file is read again from its start")
    func replacedFile() throws {
        let t = try TempSession()
        try t.write("a", [t.task("u1", "One."), t.says("u2", words("Two."))])
        let first = read(t)
        try t.remove("a")
        try t.write("a", [t.task("u1", "One.")])
        let again = read(t, from: first.bookmark)
        #expect(again.said.map(\.id) == ["u1"])
        #expect(again.bookmark.offset == UInt64(try t.contents("a").count))
    }

    @Test("a missing file leaves the bookmark as it was")
    func missingFile() throws {
        let t = try TempSession()
        let mark = HelperBookmark(file: "1:2", offset: 10)
        let result = read(t, from: mark)
        #expect(result.said.isEmpty)
        #expect(result.bookmark == mark)
    }

    @Test("an agent id that is not plainly an id is never opened")
    func badAgentID() throws {
        let t = try TempSession()
        let files = CountingFiles()
        for id in ["../../outside", "a/b", "", ".", "..", String(repeating: "x", count: 129), "é"] {
            #expect(read(t, id, files: files).said.isEmpty)
        }
        #expect(files.opened.isEmpty)
        _ = read(t, "a-B_9", files: files)
        #expect(files.opened == [t.file("a-B_9").path])
    }

    @Test("a line far too long is passed over, a long message is cut one past the limit, and file contents are dropped")
    func caps() throws {
        let t = try TempSession()
        try t.write("a", [
            t.result("huge", String(repeating: "q", count: 3 * 1024 * 1024)),
            t.says("long", words(String(repeating: "z", count: 50_000))),
            t.says("tool", ["type": "tool_use", "id": "w1", "name": "Write", "input": ["file_path": "/k.pem", "content": "PRIVATE"]]),
            t.meta("note", "<system-reminder>PRIVATE</system-reminder>"),
            t.says("think", ["type": "thinking", "thinking": "PRIVATE"]),
            t.says("last", words("Short.")),
        ])
        let result = read(t)
        #expect(result.said.map(\.id) == ["long", "last"])
        #expect(result.said.first?.text.count == Journal.Limits.chatText + 1)
        #expect(!String(describing: result.said).contains("PRIVATE"))
    }

    @Test("a line too long to keep that is still being written is skipped once it ends")
    func longPartial() throws {
        let t = try TempSession()
        let huge = Data(t.result("huge", String(repeating: "q", count: 2 * 1024 * 1024)).utf8)
        try t.write("a", huge.dropLast(10))
        let first = read(t)
        #expect(first.bookmark.skipping)
        #expect(first.bookmark.partial == nil)
        try t.append("a", huge.suffix(10) + Data(t.says("after", words("Still heard.")).utf8))
        #expect(read(t, from: first.bookmark).said.map(\.id) == ["after"])
    }

    @Test("one read at a time per helper; one wanted meanwhile follows when it is handed back")
    func follower() {
        var follower = HelperTranscriptFollower()
        let now = Date(timeIntervalSince1970: 1_000)
        let agents = [
            AgentRecord(id: AgentWorld.mainAgent, kind: "main", title: "", parentID: nil, startedAt: now, endedAt: nil),
            AgentRecord(id: "a", kind: "Explore", title: "", parentID: AgentWorld.mainAgent, startedAt: now, endedAt: nil),
            AgentRecord(id: "gone", kind: "Explore", title: "", parentID: AgentWorld.mainAgent, startedAt: now, endedAt: now - 60),
        ]
        let first = follower.due(sessionID: "s1", transcriptPath: "/t/s1.jsonl", agents: agents, now: now)
        // Helpers at work are read every few seconds; long-stopped ones and main are not.
        #expect(first.map(\.agentID) == ["a"])
        follower.want("a")
        #expect(follower.due(sessionID: "s1", transcriptPath: "/t/s1.jsonl", agents: agents, now: now + 1).isEmpty)
        let mark = HelperBookmark(file: "1:1", offset: 42)
        follower.finish(HelperReadResult(read: first[0], said: [], bookmark: mark))
        let next = follower.due(sessionID: "s1", transcriptPath: "/t/s1.jsonl", agents: agents, now: now + 2)
        #expect(next.map(\.from) == [mark])
        // A helper that stopped a long time ago is still read when asked for.
        follower.wantAll(agents)
        #expect(follower.due(sessionID: "s1", transcriptPath: "/t/s1.jsonl", agents: agents, now: now + 3).map(\.agentID) == ["gone"])
    }
}

@Suite("The answer bar's options")
struct AnswerPlanTests {
    private func ask(_ kind: AskKind, tool: String = "Bash", options: [String] = [], target: String = "rm -rf build", questions: Int = 0, multiSelect: Bool = false, id: String = "ask-1") -> Ask {
        Ask(id: id, at: Date(timeIntervalSince1970: 1_000), kind: kind, agentID: AgentWorld.mainAgent, tool: tool, summary: "Run a command",
            description: "", target: target, options: options, input: "{}", questionCount: questions, multiSelect: multiSelect)
    }

    private func keys(_ plan: AnswerPlan) -> [String] { plan.options.map { "\($0.label)=\($0.keys ?? "-")" } }

    @Test("a permission offers Allow, the rule Claude Code suggests, and Deny by Esc")
    func permission() {
        let plain = AnswerPlan(ask: ask(.permission))
        #expect(keys(plain) == ["Allow=1", "Deny=\u{1B}", "Deny and say why…=-"])
        #expect(plain.options.filter(\.isDefault).map(\.role) == [.allow])

        let suggested = AnswerPlan(ask: ask(.permission, tool: "WebFetch", options: ["Always allow WebFetch(domain:github.com)"]))
        #expect(keys(suggested) == ["Allow=1", "Always: Always allow WebFetch(domain:github.com)=2", "Deny=\u{1B}", "Deny and say why…=-"])
        #expect(suggested.options[1].positionVerified)
        // A command's always-row may be an editable prefix, so its key is not trusted.
        #expect(!AnswerPlan(ask: ask(.permission, options: ["Always allow Bash(npm test)"])).options[1].positionVerified)
    }

    @Test("a single question offers its options by number, then Claude Code's own free-text row")
    func question() {
        let plan = AnswerPlan(ask: ask(.question, tool: "AskUserQuestion", options: ["React", "Vue"], questions: 1))
        #expect(keys(plan) == ["React=1", "Vue=2", "Something else…=3"])
        #expect(plan.options.first?.isDefault == true)
        #expect(plan.options.allSatisfy { $0.positionVerified })

        for many in [ask(.question, options: ["A", "B"], questions: 2), ask(.question, options: ["A", "B"], questions: 1, multiSelect: true)] {
            #expect(AnswerPlan(ask: many).options.map(\.role) == [.answerInTerminal])
        }
    }

    @Test("a plan's approvals are offered with their assumed positions, and forms are answered in the terminal")
    func planAndForm() {
        let plan = AnswerPlan(ask: ask(.plan, tool: "ExitPlanMode"))
        #expect(keys(plan) == ["Approve, auto-accept edits=1", "Approve, review each edit=2", "Keep planning…=-"])
        #expect(plan.options.prefix(2).allSatisfy { !$0.positionVerified })
        let clearing = AnswerPlan(ask: ask(.plan, tool: "ExitPlanMode"), planClearsContext: true)
        #expect(clearing.options.compactMap(\.keys) == ["1", "2", "3"])
        #expect(AnswerPlan(ask: ask(.form, tool: "github")).options.map(\.keys) == [nil])
    }

    @Test("an answer is refused once the ask has changed or gone, even if a new one looks the same")
    func fingerprint() {
        let shown = ask(.permission)
        let plan = AnswerPlan(ask: shown)
        #expect(plan.fingerprint == AnswerPlan(ask: shown).fingerprint)
        #expect(plan.fingerprint.count == 16)
        #expect(plan.isCurrent(in: [shown]))
        #expect(!plan.isCurrent(in: []))
        #expect(!plan.isCurrent(in: [ask(.permission, target: "rm -rf /")]))
        #expect(!plan.isCurrent(in: [ask(.permission, id: "ask-2")]))
        #expect(AnswerPlan.fingerprint(of: ask(.permission, target: "a")) != AnswerPlan.fingerprint(of: ask(.permission, target: "b")))
    }

    @Test("asks from the journal plan their answers, and a settled ask refuses one")
    func fromJournal() throws {
        var world = AgentWorld()
        let now = Date(timeIntervalSince1970: 1_000)
        func hook(_ event: String, _ extra: [String: JSONValue]) {
            var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": "s1", "cwd": "/code/shop"]
            payload.merge(extra) { _, new in new }
            world.ingest(.object(payload), account: "personal", paneID: nil, now: now)
        }
        hook("PreToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "q1", "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]])
        let asked = try #require(world.detail(sessionID: "s1")?.asks.first)
        let plan = AnswerPlan(ask: asked)
        #expect(keys(plan) == ["A=1", "B=2", "Something else…=3"])
        #expect(plan.isCurrent(in: world.detail(sessionID: "s1")?.asks ?? []))
        hook("PostToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "q1"])
        #expect(!plan.isCurrent(in: world.detail(sessionID: "s1")?.asks ?? []))
    }
}
