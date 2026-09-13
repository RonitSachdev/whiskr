import Foundation
import Testing
@testable import WhiskrKit

/// Drives an `AgentWorld` the way the app does, keeping every detail change of session "s1" as the web
/// prototype's tests keep every message sent. File reads (meta, transcript, helpers' transcripts) happen
/// in `settle()`, as they do in the prototype's tests with `await world.settled()`.
private struct Harness {
    var world = AgentWorld()
    var now = Date(timeIntervalSince1970: 1_000_000)
    let start = Date(timeIntervalSince1970: 1_000_000)
    var meta: [String: SpawnMeta]
    var facts: TranscriptFacts
    let transcript: String
    var effects: [WorldEffect] = []
    var changes: [DetailChange] = []
    /// Which helpers' transcripts were asked for, to show that nothing is read unless watched.
    var reads: [String] = []
    let main = AgentWorld.mainAgent

    init(meta: [String: SpawnMeta] = [:], facts: TranscriptFacts = TranscriptFacts(), transcript: String = "/t/s1.jsonl", watching: Bool = true) {
        self.meta = meta
        self.facts = facts
        self.transcript = transcript
        if watching { world.watch(["s1"]) }
    }

    mutating func hook(_ event: String, _ extra: [String: JSONValue] = [:]) {
        var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": "s1", "cwd": "/code/shop", "transcript_path": .string(transcript)]
        payload.merge(extra) { _, new in new }
        effects += world.ingest(.object(payload), account: "personal", paneID: "pane-1", now: now)
        collect()
    }

    mutating func spawn(_ toolUseID: String, _ kind: String, by agent: String? = nil) {
        var extra: [String: JSONValue] = ["tool_name": "Agent", "tool_use_id": .string(toolUseID), "tool_input": ["subagent_type": .string(kind), "description": .string("\(kind) task")]]
        if let agent { extra["agent_id"] = .string(agent) }
        hook("PreToolUse", extra)
    }

    mutating func start(_ id: String, _ kind: String) {
        hook("SubagentStart", ["agent_id": .string(id), "agent_type": .string(kind)])
    }

    mutating func collect() {
        changes += world.takeDetailChanges()["s1"] ?? []
    }

    /// Performs every file read due, as the app does off the main thread, until none is left.
    mutating func settle() {
        while !effects.isEmpty {
            switch effects.removeFirst() {
            case .readTranscript(let sessionID, _):
                world.apply(transcript: facts, sessionID: sessionID, now: now)
            case .readMeta(let sessionID, let agentID, _):
                world.apply(meta: meta[agentID], sessionID: sessionID, agentID: agentID, now: now)
            }
        }
        while true {
            let due = world.dueHelperReads(now: now)
            if due.isEmpty { break }
            for read in due {
                reads.append(read.agentID)
                world.hear(HelperTranscript.read(read, files: LocalHelperTranscriptFiles()), now: now)
            }
        }
        collect()
    }

    mutating func advance(_ seconds: TimeInterval) {
        now += seconds
        world.tick(now: now)
        collect()
    }

    var detail: SessionDetail { world.detail(sessionID: "s1")! }
    var session: SessionSnapshot? { world.snapshots.first }

    /// A helper's own messages, as (kind, text).
    func heard(from agentID: String) -> [[String]] {
        detail.chat.filter { $0.agentID == agentID }.map { [$0.kind.rawValue, $0.text] }
    }
}

@Suite("Session detail from hook events")
struct JournalTests {
    @Test("a streamed reply is assembled batch by batch and not repeated when the turn ends")
    func streaming() {
        var w = Harness()
        w.hook("UserPromptSubmit", ["prompt": "Fix the cart total"])
        func batch(_ w: inout Harness, _ index: Int, _ delta: String, final: Bool = false) {
            w.hook("MessageDisplay", ["message_id": "m1", "index": .number(Double(index)), "final": .bool(final), "delta": .string(delta)])
        }
        batch(&w, 0, "Here is the plan:\n")
        #expect(w.detail.chat.last == ChatEntry(id: "reply-m1", at: w.start, kind: .reply, agentID: w.main, text: "Here is the plan:\n", streaming: true, clipped: false))
        batch(&w, 1, "1. Read cart.ts\n")
        batch(&w, 1, "1. Read cart.ts\n") // a repeat is ignored
        batch(&w, 2, "", final: true)
        w.hook("Stop", ["last_assistant_message": "Here is the plan:\n1. Read cart.ts"])

        #expect(w.detail.chat.map { "\($0.kind)|\($0.text)|\($0.streaming)" } == [
            "prompt|Fix the cart total|false",
            "reply|Here is the plan:\n1. Read cart.ts\n|false",
        ])
        let appends = w.changes.filter { if case .chatAppend = $0 { true } else { false } }
        #expect(appends == [
            .chatAppend(id: "reply-m1", text: "1. Read cart.ts\n", streaming: true),
            .chatAppend(id: "reply-m1", text: "", streaming: false),
        ])
        #expect(w.detail.facts.prompts == 1)
    }

    @Test("without streaming, the reply comes from the end of the turn; a mid-turn message stays separate")
    func endOfTurnReply() {
        var w = Harness()
        w.hook("UserPromptSubmit", ["prompt": "hi"])
        w.hook("MessageDisplay", ["message_id": "m1", "index": 0, "final": true, "delta": "Running the tests first."])
        w.hook("Stop", ["last_assistant_message": "All green."])
        w.hook("UserPromptSubmit", ["prompt": "again"])
        w.hook("Stop", ["last_assistant_message": "Done again."])
        #expect(w.detail.chat.map { [$0.kind.rawValue, $0.text] } == [
            ["prompt", "hi"], ["reply", "Running the tests first."], ["reply", "All green."], ["prompt", "again"], ["reply", "Done again."],
        ])
    }

    @Test("a helper's final message joins the chat under its name, and its record outlives it")
    func helperReport() {
        var w = Harness()
        w.hook("UserPromptSubmit", ["prompt": "map it"])
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.settle()
        w.advance(4)
        w.hook("SubagentStop", ["agent_id": "a", "agent_type": "Explore", "last_assistant_message": "Found 3 entry points."])
        // Claude Code's own agents (prompt suggestions, /btw) also stop, without ever having started.
        w.hook("SubagentStop", ["agent_id": "internal", "last_assistant_message": "Try asking about tests"])

        let detail = w.detail
        #expect(detail.chat.last.map { [$0.kind.rawValue, $0.agentID, $0.text] } == ["report", "a", "Found 3 entry points."])
        #expect(detail.chat.count { $0.kind == .report } == 1)
        #expect(detail.agents == [
            AgentRecord(id: w.main, kind: "main", title: "", parentID: nil, startedAt: w.start, endedAt: nil),
            AgentRecord(id: "a", kind: "Explore", title: "Explore task", parentID: w.main, startedAt: w.start, endedAt: w.start + 4),
        ])
        let helper = detail.timeline.first { $0.kind == .helper }
        #expect(helper?.agentID == "a")
        #expect(helper?.state == .ok)
        #expect(helper?.duration == 4)
        #expect(helper?.output == "Found 3 entry points.")
    }

    @Test("the to-do list follows the task tools and its count reaches the overview")
    func tasks() {
        var w = Harness()
        w.hook("TaskCreated", ["task_id": "1", "task_subject": "alpha", "task_description": "first"])
        w.hook("PostToolUse", ["tool_name": "TaskCreate", "tool_use_id": "c1", "tool_input": ["subject": "alpha", "description": "first", "activeForm": "Doing alpha"], "tool_response": ["task": ["id": "1", "subject": "alpha"]]])
        w.hook("TaskCreated", ["task_id": "2", "task_subject": "beta"])
        #expect(w.world.progress(sessionID: "s1") == TaskProgress(done: 0, total: 2))

        w.hook("PreToolUse", ["tool_name": "TaskUpdate", "tool_use_id": "u1", "tool_input": ["taskId": "1", "status": "in_progress"]])
        w.hook("PostToolUse", ["tool_name": "TaskUpdate", "tool_use_id": "u1", "tool_input": ["taskId": "1", "status": "in_progress"], "tool_response": ["success": true, "taskId": "1"]])
        #expect(w.detail.tasks.first == TaskItem(id: "1", subject: "alpha", activeForm: "Doing alpha", description: "first", state: .inProgress, owner: ""))
        #expect(w.detail.timeline.last?.title == "Started a task: alpha")

        w.hook("TaskCompleted", ["task_id": "1", "task_subject": "alpha"])
        #expect(w.world.progress(sessionID: "s1") == TaskProgress(done: 1, total: 2))
        // A failed update changes nothing; a deletion removes the task.
        w.hook("PostToolUse", ["tool_name": "TaskUpdate", "tool_use_id": "u2", "tool_input": ["id": "2", "status": "completed"], "tool_response": ["success": false]])
        w.hook("PostToolUse", ["tool_name": "TaskUpdate", "tool_use_id": "u3", "tool_input": ["task_id": "2", "status": "deleted"], "tool_response": ["success": true]])
        #expect(w.detail.tasks.map { "\($0.id) \($0.state)" } == ["1 completed"])
        let lastTasks = w.changes.last { if case .tasks = $0 { true } else { false } }
        #expect(lastTasks == .tasks(w.detail.tasks))

        // The older checklist tool replaces the whole list each time.
        w.hook("PostToolUse", ["tool_name": "TodoWrite", "tool_use_id": "t1", "tool_input": ["todos": [
            ["content": "Write tests", "status": "completed", "activeForm": "Writing tests"],
            ["content": "Ship it", "status": "pending", "activeForm": "Shipping it"],
        ]]])
        #expect(w.detail.tasks.map { "\($0.subject) \($0.state)" } == ["Write tests completed", "Ship it pending"])
        #expect(w.world.progress(sessionID: "s1") == TaskProgress(done: 1, total: 2))
    }

    @Test("the timeline records each tool with how long it took, what came back, and how the turn went")
    func timeline() {
        var w = Harness()
        w.hook("UserPromptSubmit", ["prompt": "run the tests"])
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": "npm test", "description": "Run tests"]])
        w.advance(0.3)
        w.hook("PostToolUse", ["tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": "npm test"], "duration_ms": 255, "tool_response": ["stdout": "13 passing", "stderr": "", "interrupted": false]])
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t2", "tool_input": ["command": "false"]])
        w.hook("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "t2", "error": "Exit code 1", "duration_ms": 12])
        w.advance(0.7)
        w.hook("Stop", ["last_assistant_message": "One check fails."])

        let rows = w.detail.timeline.map { "\($0.kind)|\($0.title)|\($0.state)|\($0.duration.map { String(Int(($0 * 1_000).rounded())) } ?? "-")|\($0.output)" }
        #expect(rows == [
            "prompt|run the tests|info|-|",
            "tool|Ran npm test|ok|255|13 passing",
            "tool|Ran false|failed|12|Exit code 1",
            "turn|Finished the turn|ok|1000|",
        ])
        #expect(w.detail.timeline[1].detail == "npm test")
        // The running event and its finish travel as two versions of the same event.
        let t1 = w.changes.compactMap { if case .event(let event) = $0, event.title == "Ran npm test" { event.state } else { nil } }
        #expect(t1 == [.running, .ok])
    }

    @Test("a permission request says what is asked, and settles as allowed or not")
    func permission() throws {
        var w = Harness()
        let command = "git clean -fdx build"
        w.hook("UserPromptSubmit", ["prompt": "clean up"])
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": .string(command), "description": "Remove the build folder"]])
        w.hook("PermissionRequest", [
            "tool_name": "Bash", "tool_input": ["command": .string(command), "description": "Remove the build folder"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": .string(command)]], "behavior": "allow", "destination": "localSettings"]],
        ])
        let ask = try #require(w.detail.asks.first)
        #expect([ask.kind.rawValue, ask.agentID, ask.tool, ask.summary, ask.description, ask.target] == ["permission", w.main, "Bash", "Run a command", "Remove the build folder", command])
        #expect(ask.options == ["Always allow Bash(\(command))"])
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(ask.input.utf8)) == ["command": .string(command), "description": "Remove the build folder"])
        w.advance(2)
        w.hook("PostToolUse", ["tool_name": "Bash", "tool_use_id": "t1", "tool_response": ["stdout": ""]])
        #expect(w.detail.asks.isEmpty)
        let asked = try #require(w.detail.timeline.first { $0.kind == .permission })
        #expect([asked.title, asked.state.rawValue, asked.output] == ["Run a command", "ok", "Allowed"])
        #expect(asked.duration == 2)

        // Refused in the dialog: the call never reports back, and its batch closes it.
        w.hook("PreToolUse", ["tool_name": "Write", "tool_use_id": "t2", "tool_input": ["file_path": "/code/shop/.env", "content": "SECRET=1"]])
        w.hook("PermissionRequest", ["tool_name": "Write", "tool_input": ["file_path": "/code/shop/.env", "content": "SECRET=1"]])
        #expect(w.detail.asks.first?.summary == "Create or overwrite .env")
        w.hook("PostToolBatch", ["tool_calls": [["tool_use_id": "t2", "tool_name": "Write"]]])
        #expect(w.detail.asks.isEmpty)
        #expect(w.detail.timeline.filter { $0.tool == "Write" }.map { "\($0.kind) \($0.state)" } == ["tool denied", "permission denied"])
        // Once settled, the contents shown with the request are not kept anywhere.
        #expect(!String(describing: w.detail).contains("SECRET=1"))
    }

    @Test("questions, plans and MCP forms wait on you as asks of their own")
    func questionsPlansForms() {
        var w = Harness()
        w.hook("PreToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "q1", "tool_input": ["questions": [
            ["question": "Which framework?", "header": "Framework", "options": [["label": "React"], ["label": "Vue"]], "multiSelect": false],
        ]]])
        // The dialog may also arrive as a permission request; it is the same question, not a second ask.
        w.hook("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": [:]])
        #expect(w.detail.asks.map { "\($0.kind) \($0.summary) \($0.options)" } == ["question Which framework? [\"React\", \"Vue\"]"])
        w.hook("PostToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "q1"])

        w.hook("PreToolUse", ["tool_name": "ExitPlanMode", "tool_use_id": "p1", "tool_input": ["plan": "## Refactor\n1. Extract"]])
        #expect(w.detail.asks.map { [$0.kind.rawValue, $0.summary, $0.target] } == [["plan", "Approve the plan", "## Refactor\n1. Extract"]])
        w.hook("PostToolUse", ["tool_name": "ExitPlanMode", "tool_use_id": "p1"])

        w.hook("Elicitation", ["mcp_server_name": "github", "message": "Sign in to GitHub", "mode": "url", "url": "https://github.com/login", "elicitation_id": "e1"])
        #expect(w.detail.asks.map { [$0.kind.rawValue, $0.tool, $0.summary, $0.target] } == [["form", "github", "Sign in to GitHub", "https://github.com/login"]])
        #expect(w.session?.needsYou == true)
        w.hook("ElicitationResult", ["mcp_server_name": "github", "action": "decline", "elicitation_id": "e1"])
        #expect(w.detail.asks.isEmpty)
        #expect(w.session?.needsYou == false)
        #expect(w.detail.timeline.filter { $0.kind == .question }.map { "\($0.state) \($0.output)" } == ["denied decline"])
    }

    @Test("facts follow the session: model, mode, effort, folder, instructions and how it ended")
    func facts() {
        var w = Harness(facts: TranscriptFacts(model: "claude-sonnet-5-5"))
        w.hook("UserPromptSubmit", ["prompt": "go", "permission_mode": "plan", "effort": ["level": "high"]])
        w.settle()
        #expect(w.detail.facts.model == "claude-sonnet-5-5")
        w.hook("PostModelSwitch", ["from_model": "claude-sonnet-5-5", "to_model": "claude-opus-5", "source": "command"])
        w.hook("InstructionsLoaded", ["file_path": "/code/shop/CLAUDE.md", "memory_type": "Project", "load_reason": "session_start"])
        w.hook("CwdChanged", ["old_cwd": "/code/shop", "new_cwd": "/code/shop/src"])
        w.hook("DirectoryAdded", ["directory": "/code/lib", "source": "slash_command"])
        w.hook("Stop", ["last_assistant_message": "ok", "background_tasks": [["id": "b1", "type": "shell", "status": "running", "command": "tail -f log"]], "session_crons": [["schedule": "0 9 * * 1-5", "prompt": "check the build"]]])
        w.hook("SessionEnd", ["reason": "prompt_input_exit"])

        var expected = SessionFacts(firstSeenAt: w.start, cwd: "/code/shop/src")
        expected.model = "claude-opus-5"
        expected.effort = "high"
        expected.permissionMode = "plan"
        expected.endedAt = w.start
        expected.endReason = "prompt_input_exit"
        expected.directories = ["/code/lib"]
        expected.instructions = ["/code/shop/CLAUDE.md"]
        expected.background = ["shell: tail -f log"]
        expected.scheduled = ["0 9 * * 1-5 · check the build"]
        expected.prompts = 1
        #expect(w.detail.facts == expected)
        #expect(w.detail.timeline.filter { [.model, .setting, .session].contains($0.kind) }.map(\.title) == [
            "Model: claude-opus-5", "Loaded CLAUDE.md", "Moved to src", "Added the folder lib", "Session ended",
        ])
    }

    @Test("compaction is one timeline event with its summary")
    func compaction() {
        var w = Harness()
        w.hook("PreCompact", ["trigger": "manual", "custom_instructions": "keep the API notes"])
        w.advance(5)
        w.hook("PostCompact", ["trigger": "manual", "compact_summary": "We fixed the cart."])
        let compact = w.detail.timeline.first
        #expect(compact?.state == .ok)
        #expect(compact?.detail == "keep the API notes")
        #expect(compact?.output == "We fixed the cart.")
        #expect(compact?.duration == 5)
        #expect(w.detail.facts.compactions == 1)
    }

    @Test("sizes are capped: long text is cut, file contents are never kept, old entries are let go")
    func caps() throws {
        var w = Harness()
        w.hook("UserPromptSubmit", ["prompt": .string(String(repeating: "x", count: 50_000))])
        let prompt = try #require(w.detail.chat.first)
        #expect(prompt.text.count == Journal.Limits.chatText)
        #expect(prompt.clipped)

        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "big", "tool_input": ["command": "cat huge.log"]])
        w.hook("PostToolUse", ["tool_name": "Bash", "tool_use_id": "big", "tool_response": ["stdout": .string(String(repeating: "y", count: 1_000_000))]])
        #expect((w.detail.timeline.last?.output.count ?? .max) <= 1_000)

        w.hook("PreToolUse", ["tool_name": "Write", "tool_use_id": "w1", "tool_input": ["file_path": "/code/shop/key.pem", "content": "PRIVATE-KEY-MATERIAL"]])
        w.hook("PostToolUse", ["tool_name": "Write", "tool_use_id": "w1", "tool_input": ["file_path": "/code/shop/key.pem", "content": "PRIVATE-KEY-MATERIAL"], "tool_response": ["filePath": "/code/shop/key.pem", "content": "PRIVATE-KEY-MATERIAL"]])
        #expect(!String(describing: w.detail).contains("PRIVATE-KEY-MATERIAL"))
        #expect(!String(describing: w.changes).contains("PRIVATE-KEY-MATERIAL"))

        for i in 0..<(Journal.Limits.timeline + 10) {
            w.hook("Notification", ["message": .string("note \(i)"), "notification_type": "idle_prompt"])
        }
        #expect(w.detail.timeline.count == Journal.Limits.timeline)
        #expect(w.detail.timeline.last?.title == "note \(Journal.Limits.timeline + 9)")
        let dropped = w.changes.flatMap { if case .drop(.timeline, let ids) = $0 { ids } else { [] } }
        #expect(dropped.count == 13)

        for i in 0..<(Journal.Limits.chat + 5) { w.hook("UserPromptSubmit", ["prompt": .string("p\(i)")]) }
        #expect(w.detail.chat.count == Journal.Limits.chat)
        #expect(w.changes.contains { if case .drop(.chat, let ids) = $0 { ids.contains(prompt.id) } else { false } })
    }

    @Test("payload fields of the wrong type are ignored rather than trusted")
    func wrongTypes() {
        var w = Harness()
        w.hook("PreToolUse", ["tool_name": 42, "tool_use_id": "t1", "tool_input": "nope"])
        w.hook("MessageDisplay", ["message_id": "m", "index": "x", "final": "yes", "delta": ["evil": true]])
        w.hook("MessageDisplay", ["message_id": "m", "index": 1e300, "delta": "more"])
        w.hook("PostToolUse", ["tool_name": "TaskUpdate", "tool_input": ["taskId": ["toString": 1], "status": 7]])
        w.world.ingest(["hook_event_name": "Stop", "session_id": 99], account: "personal", paneID: nil, now: w.now)
        #expect(w.session?.agents.first?.activity == .running)
        #expect(w.detail.tasks.isEmpty)
    }

    @Test("Claude Code's automatic notices are told apart from what you typed")
    func notices() {
        var w = Harness()
        w.hook("UserPromptSubmit", ["prompt": "Fix it"])
        w.hook("UserPromptSubmit", ["prompt": "\n <task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"])
        w.hook("UserPromptSubmit", ["prompt": "<system-reminder>The date changed.</system-reminder>"])
        w.hook("UserPromptSubmit", ["prompt": "<task-notifications are not a tag I know"])
        #expect(w.detail.chat.map(\.kind) == [.prompt, .notice, .notice, .prompt])
        #expect(w.detail.facts.prompts == 2)
        #expect(w.detail.timeline.filter { $0.kind == .prompt }.map(\.title) == [
            "Fix it", "Automatic notice from Claude Code", "Automatic notice from Claude Code", "<task-notifications are not a tag I know",
        ])
        #expect(Journal.isNotice("<system-reminder>"))
        #expect(Journal.isNotice("<task-notification"))
        #expect(!Journal.isNotice("<system-reminders>"))
        #expect(!Journal.isNotice("please read <system-reminder>"))
    }

    @Test("detail is kept for a watched session only: whole first, then changes that rebuild it")
    func watching() throws {
        var w = Harness(watching: false)
        // Watching a session that has not reported in yet: nothing to show until it does.
        #expect(w.world.detail(sessionID: "s1") == nil)
        w.hook("UserPromptSubmit", ["prompt": "hello"])
        w.hook("Stop", ["last_assistant_message": "hi there"])
        #expect(w.changes.isEmpty)

        w.world.watch(["s1"])
        #expect(w.world.takeDetailChanges().isEmpty)
        var shown = try #require(w.world.detail(sessionID: "s1"))
        #expect(shown.chat.map(\.text) == ["hello", "hi there"])

        w.hook("UserPromptSubmit", ["prompt": "more", "permission_mode": "acceptEdits"])
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": "ls"]])
        w.hook("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]])
        w.hook("MessageDisplay", ["message_id": "m2", "index": 0, "delta": "Listing "])
        w.hook("MessageDisplay", ["message_id": "m2", "index": 1, "final": true, "delta": "the folder."])
        w.hook("TaskCreated", ["task_id": "1", "task_subject": "alpha"])
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.advance(2)
        w.hook("SubagentStop", ["agent_id": "a", "last_assistant_message": "Done."])
        w.hook("Stop", ["last_assistant_message": "Listing the folder."])
        for change in w.changes { shown.apply(change) }
        #expect(shown == w.detail)

        // Unwatched again: changes are let go as they happen.
        w.world.watch([])
        w.hook("UserPromptSubmit", ["prompt": "unseen"])
        w.world.watch(["s1"])
        #expect(w.world.takeDetailChanges().isEmpty)
    }

    // MARK: Helpers' own words, from their transcripts

    @Test("a helper's task and words join the chat only once its session is watched, and file contents never do")
    func helperWords() throws {
        let t = try TempSession()
        try t.write("a", [
            t.task("u1", "Map the checkout flow and say where the discount is applied."),
            t.says("u2", ["type": "thinking", "thinking": "PRIVATE-THOUGHT"]),
            t.says("u3", words("I will start with the cart.")),
            t.says("u4", ["type": "tool_use", "id": "w1", "name": "Write", "input": ["file_path": "/code/shop/key.pem", "content": "PRIVATE-KEY-MATERIAL"]]),
            t.result("u5", "PRIVATE-KEY-MATERIAL"),
            t.meta("u6", "<system-reminder>PRIVATE-REMINDER</system-reminder>"),
            t.says("u7", words("The discount is applied twice.")),
        ])
        var w = Harness(transcript: t.transcript, watching: false)
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.hook("PreToolUse", ["agent_id": "a", "tool_name": "Read", "tool_use_id": "r1", "tool_input": ["file_path": "/code/shop/cart.ts"]])
        w.advance(10)
        w.settle()
        #expect(w.reads.isEmpty)
        #expect(w.heard(from: "a").isEmpty)

        w.world.watch(["s1"])
        w.settle()
        #expect(w.heard(from: "a") == [
            ["task", "Map the checkout flow and say where the discount is applied."],
            ["reply", "I will start with the cart."],
            ["reply", "The discount is applied twice."],
        ])
        // Each says when it was written, from the transcript.
        #expect(w.detail.chat.first { $0.kind == .task }?.at == TempSession.stamp(0))
        let everything = String(describing: w.detail) + String(describing: w.changes)
        for secret in ["PRIVATE-KEY-MATERIAL", "PRIVATE-THOUGHT", "PRIVATE-REMINDER"] {
            #expect(!everything.contains(secret), "\(secret)")
        }

        // Unwatched again, nothing more is read.
        w.world.watch([])
        let before = w.reads.count
        try t.append("a", t.says("u8", words("More.")))
        w.hook("PostToolUse", ["agent_id": "a", "tool_name": "Read", "tool_use_id": "r1"])
        w.advance(10)
        w.settle()
        #expect(w.reads.count == before)
    }

    @Test("lines a helper appends arrive as changes, a half-written line is neither lost nor repeated, and its last words become its report")
    func helperAppends() throws {
        let t = try TempSession()
        try t.write("a", [t.task("u1", "Trace the tax rules.")])
        var w = Harness(transcript: t.transcript)
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.settle()

        // Its next event brings what it wrote since.
        try t.append("a", t.says("u2", words("Reading tax.ts now.")))
        let seen = w.changes.count
        w.hook("PreToolUse", ["agent_id": "a", "tool_name": "Read", "tool_use_id": "r1", "tool_input": ["file_path": "/code/shop/tax.ts"]])
        w.settle()
        #expect(w.changes.dropFirst(seen).contains { if case .chat(let entry) = $0 { entry.agentID == "a" && entry.text == "Reading tax.ts now." } else { false } })

        // A line caught half-written, split inside a character, waits for the rest; the slow timer finds it.
        let line = Data(t.says("u3", words("Tax comes after the discount ☕")).utf8)
        let cut = try #require(line.firstRange(of: Data("☕".utf8))).lowerBound + 1
        try t.append("a", line.prefix(cut))
        w.advance(5)
        w.settle()
        #expect(w.heard(from: "a").count == 2)
        try t.append("a", line.suffix(from: cut))
        w.advance(5)
        w.settle()
        #expect(w.heard(from: "a").last == ["reply", "Tax comes after the discount ☕"])
        #expect(w.heard(from: "a").count == 3)

        // A file replaced by a fresh copy is read from its start, without repeating what was already heard.
        let copy = try t.contents("a") + Data(t.says("u4", words("All done: tax is fine.")).utf8)
        try t.remove("a")
        try t.write("a", copy)
        w.advance(5)
        w.settle()
        #expect(w.heard(from: "a").count == 4)

        // Its last words, handed back as the report, are shown once, as the report.
        w.hook("SubagentStop", ["agent_id": "a", "last_assistant_message": "All done: tax is fine."])
        w.settle()
        #expect(w.heard(from: "a") == [
            ["task", "Trace the tax rules."],
            ["reply", "Reading tax.ts now."],
            ["reply", "Tax comes after the discount ☕"],
            ["report", "All done: tax is fine."],
        ])
    }

    @Test("helpers' words are capped like the rest of the chat and never push your conversation out")
    func helperCaps() throws {
        let t = try TempSession()
        var lines = [t.task("u0", "Say a lot."), t.says("long", words(String(repeating: "z", count: 50_000)))]
        // A line far too long to be anything but a tool's output is passed over; the next one still counts.
        lines.append(t.result("huge", String(repeating: "q", count: 3 * 1024 * 1024)))
        for i in 0..<(Journal.Limits.helperChat + 20) { lines.append(t.says("m\(i)", words("note \(i)"))) }
        try t.write("a", lines)
        var w = Harness(transcript: t.transcript)
        w.hook("UserPromptSubmit", ["prompt": "Please look into it."])
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.settle()

        let chat = w.detail.chat
        let heard = chat.filter { $0.agentID == "a" }
        #expect(heard.count == Journal.Limits.helperChat)
        #expect(heard.last?.text == "note \(Journal.Limits.helperChat + 19)")
        #expect(chat.contains { $0.kind == .prompt && $0.text == "Please look into it." })
        #expect(!String(describing: w.detail).contains("qqqq"))

        // The long message was kept cut short, and marked so, before it was let go.
        let long = w.changes.lazy.compactMap { if case .chat(let entry) = $0, entry.agentID == "a", entry.text.hasPrefix("zzz") { entry } else { nil } }.first
        #expect(long?.text.count == Journal.Limits.chatText)
        #expect(long?.clipped == true)
    }

    @Test("an agent id that is not plainly an id never becomes a path")
    func badAgentIDs() throws {
        let t = try TempSession()
        // Where "agent-../../outside" would lead if it were joined into a path.
        try Data(t.task("u1", "SHOULD-NOT-BE-READ").utf8).write(to: t.subagents.appendingPathComponent("outside.jsonl"))
        var w = Harness(transcript: t.transcript)
        for id in ["../../outside", "a/b", "", String(repeating: "x", count: 200)] {
            w.hook("PreToolUse", ["agent_id": .string(id), "tool_name": "Read", "tool_use_id": .string("r-\(id)"), "tool_input": [:]])
        }
        w.advance(10)
        w.settle()
        #expect(!String(describing: w.detail).contains("SHOULD-NOT-BE-READ"))
        #expect(w.detail.chat.isEmpty)
    }

    @Test("a helper's notice from its boss is a notice, not a task")
    func helperNotice() throws {
        let t = try TempSession()
        try t.write("a", [t.task("u1", "Check the logs."), t.task("u2", "<task-notification>\n<status>completed</status>\n</task-notification>")])
        var w = Harness(transcript: t.transcript)
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.settle()
        #expect(w.detail.chat.filter { $0.agentID == "a" }.map(\.kind) == [.task, .notice])
    }
}

func words(_ said: String) -> JSONValue { ["type": "text", "text": .string(said)] }

/// A temporary session folder laid out as Claude Code lays it out, and lines written the way it writes them.
final class TempSession {
    let folder: URL
    let subagents: URL
    var transcript: String { folder.appendingPathComponent("s1.jsonl").path }
    private var stamps = 0

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-journal-\(UUID().uuidString)").resolvingSymlinksInPath()
        subagents = folder.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// The n-th timestamp handed out: 2026-11-12 09:00:00 UTC plus n seconds.
    static func stamp(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_794_474_000 + Double(n)) }

    private func stamp() -> String {
        defer { stamps += 1 }
        return Self.stamp(stamps).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    func file(_ agentID: String) -> URL { subagents.appendingPathComponent("agent-\(agentID).jsonl") }

    func line(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "") + "\n"
    }

    func task(_ uuid: String, _ said: String) -> String {
        line(["type": "user", "uuid": .string(uuid), "isSidechain": true, "timestamp": .string(stamp()), "message": ["role": "user", "content": .string(said)]])
    }

    func says(_ uuid: String, _ blocks: JSONValue...) -> String {
        line(["type": "assistant", "uuid": .string(uuid), "isSidechain": true, "timestamp": .string(stamp()), "message": ["id": .string("msg-\(uuid)"), "role": "assistant", "content": .array(blocks)]])
    }

    func result(_ uuid: String, _ output: String) -> String {
        line(["type": "user", "uuid": .string(uuid), "isSidechain": true, "timestamp": .string(stamp()), "toolUseResult": ["content": .string(output)],
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "w1", "content": .string(output)]]]])
    }

    func meta(_ uuid: String, _ said: String) -> String {
        line(["type": "user", "uuid": .string(uuid), "isMeta": true, "isSidechain": true, "timestamp": .string(stamp()), "message": ["role": "user", "content": .string(said)]])
    }

    func write(_ agentID: String, _ lines: [String]) throws {
        try write(agentID, Data(lines.joined().utf8))
    }

    func write(_ agentID: String, _ data: Data) throws {
        try data.write(to: file(agentID))
    }

    func append(_ agentID: String, _ text: String) throws {
        try append(agentID, Data(text.utf8))
    }

    func append(_ agentID: String, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file(agentID))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func contents(_ agentID: String) throws -> Data { try Data(contentsOf: file(agentID)) }

    func remove(_ agentID: String) throws { try FileManager.default.removeItem(at: file(agentID)) }
}
