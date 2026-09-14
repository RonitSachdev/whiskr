import Foundation
import Testing
@testable import WhiskrKit

/// Drives an `AgentWorld` the way the app does, with file reads answered from tables. Effects are held
/// until `settle()`, so a test can look at the world before and after the files are read, as the web
/// prototype's tests do with `await world.settled()`.
private struct Harness {
    var world = AgentWorld()
    var now = Date(timeIntervalSince1970: 1_000_000)
    var meta: [String: SpawnMeta] = [:]
    var title: String?
    var effects: [WorldEffect] = []
    let main = AgentWorld.mainAgent

    init(meta: [String: SpawnMeta] = [:], title: String? = nil) {
        self.meta = meta
        self.title = title
    }

    mutating func hook(_ event: String, _ extra: [String: JSONValue] = [:], session: String = "s1", cwd: String = "/code/shop", pane: String? = "pane-1") {
        var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string(session), "cwd": .string(cwd), "transcript_path": "/t/s1.jsonl"]
        payload.merge(extra) { _, new in new }
        effects += world.ingest(.object(payload), account: "personal", paneID: pane, now: now)
    }

    mutating func spawn(_ toolUseID: String, _ kind: String, by agent: String? = nil) {
        var extra: [String: JSONValue] = ["tool_name": "Agent", "tool_use_id": .string(toolUseID), "tool_input": ["subagent_type": .string(kind), "description": .string("\(kind) task")]]
        if let agent { extra["agent_id"] = .string(agent) }
        hook("PreToolUse", extra)
    }

    mutating func start(_ id: String, _ kind: String) {
        hook("SubagentStart", ["agent_id": .string(id), "agent_type": .string(kind)])
    }

    /// Performs every file read asked for so far, as the app does off the main thread.
    mutating func settle() {
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            switch effect {
            case .readTranscript(let sessionID, _):
                world.apply(transcript: TranscriptFacts(title: title), sessionID: sessionID, now: now)
            case .readMeta(let sessionID, let agentID, _):
                world.apply(meta: meta[agentID], sessionID: sessionID, agentID: agentID, now: now)
            }
        }
    }

    mutating func advance(_ seconds: TimeInterval) {
        now += seconds
        world.tick(now: now)
    }

    var session: SessionSnapshot? { world.snapshots.first }
    func agent(_ id: String) -> AgentSnapshot? { world.snapshots.first?.agents.first { $0.id == id } }
}

@Suite("Agent state from hook events")
struct AgentWorldTests {
    @Test("a turn moves the main agent through thinking, tools, awake and a nap")
    func turn() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        #expect(w.agent(w.main)?.activity == .thinking)

        w.hook("PreToolUse", ["tool_name": "Read", "tool_use_id": "t1", "tool_input": ["file_path": "/code/shop/cart.ts"]])
        #expect(w.agent(w.main)?.activity == .reading)
        #expect(w.agent(w.main)?.detail == "cart.ts")
        #expect(w.agent(w.main)?.line == "Reading · cart.ts")
        w.hook("PostToolUse", ["tool_name": "Read", "tool_use_id": "t1"])
        #expect(w.agent(w.main)?.activity == .thinking)

        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t2", "tool_input": ["command": "npm test"]])
        #expect(w.agent(w.main)?.activity == .running)
        #expect(w.agent(w.main)?.detail == "npm test")
        w.hook("PostToolUse", ["tool_name": "Bash", "tool_use_id": "t2"])

        w.hook("Stop")
        #expect(w.agent(w.main)?.activity == .awake)
        w.advance(46)
        #expect(w.agent(w.main)?.activity == .napping)
        #expect(w.session?.project == "shop")
        #expect(w.session?.paneID == "pane-1")
    }

    @Test("a helper launched by a helper hangs off that helper")
    func nestedHelper() {
        var w = Harness(meta: ["b": SpawnMeta(toolUseID: "spawn-b")])
        w.hook("UserPromptSubmit")
        w.spawn("spawn-a", "Explore")
        w.start("a", "Explore")
        w.spawn("spawn-b", "Explore", by: "a")
        w.start("b", "Explore")
        w.settle()

        #expect(w.agent("a")?.parentID == w.main)
        #expect(w.agent("a")?.depth == 1)
        #expect(w.agent("b")?.parentID == "a")
        #expect(w.agent("b")?.depth == 2)
        #expect(w.agent("b")?.title == "Explore task")
        // Foreground launches leave both bosses waiting on their helpers.
        #expect(w.agent(w.main)?.activity == .supervising)
        #expect(w.agent("a")?.activity == .supervising)
        #expect(w.session?.agents.familyOrder.map(\.id) == [w.main, "a", "b"])
    }

    @Test("a wrong guess between two simultaneous launches is corrected from the meta file")
    func correctedGuess() {
        var w = Harness(meta: ["c": SpawnMeta(toolUseID: "from-a")])
        w.spawn("from-main", "worker")
        w.start("a", "worker")
        w.spawn("from-main-2", "worker")
        w.spawn("from-a", "worker", by: "a")
        // Order alone says c belongs to main's second launch.
        w.start("c", "worker")
        #expect(w.agent("c")?.parentID == w.main)
        w.settle()
        #expect(w.agent("c")?.parentID == "a")

        // The launch c had wrongly claimed is free again for the helper it really belongs to.
        w.start("d", "worker")
        w.settle()
        #expect(w.agent("d")?.parentID == w.main)
    }

    @Test("without a meta file the parent is matched by launch order and type")
    func orderAndType() {
        var w = Harness()
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.spawn("two", "reviewer", by: "a")
        w.spawn("three", "Explore")
        w.start("b", "reviewer")
        w.settle()
        #expect(w.agent("b")?.parentID == "a")
    }

    @Test("helpers that outlive their boss move up to the next one")
    func orphansMoveUp() {
        var w = Harness()
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.spawn("two", "Explore", by: "a")
        w.start("b", "Explore")
        w.hook("SubagentStop", ["agent_id": "a"])
        #expect(w.agent("a") == nil)
        #expect(w.agent("b")?.parentID == w.main)
        #expect(w.agent("b")?.depth == 1)
    }

    @Test("a main agent whose turn ended keeps supervising background helpers, and stays working")
    func backgroundHelpers() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.spawn("one", "Explore")
        w.hook("PostToolUse", ["tool_name": "Agent", "tool_use_id": "one"])
        w.start("a", "Explore")
        #expect(w.agent(w.main)?.activity == .thinking)
        w.hook("Stop")
        #expect(w.agent(w.main)?.activity == .supervising)
        #expect(w.session?.status == .working)
        w.hook("SubagentStop", ["agent_id": "a"])
        #expect(w.agent(w.main)?.activity == .awake)
        #expect(w.session?.status == .done)
    }

    @Test("a failed tool flashes an error and then recovers; an interrupt does not")
    func errorFlash() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1"])
        w.hook("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "t1"])
        #expect(w.agent(w.main)?.activity == .error)
        #expect(w.session?.status == .working)
        w.advance(3)
        #expect(w.agent(w.main)?.activity == .thinking)

        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t2"])
        w.hook("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "t2", "is_interrupt": true])
        #expect(w.agent(w.main)?.activity == .thinking)
    }

    @Test("a session is named after its chat, and a hidden folder is shown with its parent")
    func titleAndProject() {
        var w = Harness(title: "Fix the checkout bug")
        w.hook("SessionStart", session: "s2", cwd: "/code/shop/.work")
        w.settle()
        #expect(w.session?.title == "Fix the checkout bug")
        #expect(w.session?.project == "shop/.work")
    }

    @Test("the transcript is read for the title at most every twenty seconds")
    func titleThrottle() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("PreToolUse", ["tool_name": "Read", "tool_use_id": "t1"])
        #expect(w.effects.filter { if case .readTranscript = $0 { true } else { false } }.count == 1)
        w.advance(21)
        w.hook("PostToolUse", ["tool_name": "Read", "tool_use_id": "t1"])
        #expect(w.effects.filter { if case .readTranscript = $0 { true } else { false } }.count == 2)
    }

    @Test("an unnamed session's transcript is looked at again until it has a name, then rarely")
    func titleFollowUp() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.settle()
        #expect(w.world.dueReads(now: w.now).isEmpty)
        w.now += 4
        #expect(w.world.dueReads(now: w.now).count == 1)
        w.title = "Fix the cart"
        w.effects += w.world.dueReads(now: w.now + 4)
        w.settle()
        #expect(w.session?.title == "Fix the cart")
        #expect(w.world.dueReads(now: w.now + 10).isEmpty)
        #expect(w.world.dueReads(now: w.now + 25).count == 1)
    }

    @Test("web lookups and compaction each get an activity of their own")
    func webAndCompaction() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("PreToolUse", ["tool_name": "WebSearch", "tool_use_id": "t1", "tool_input": ["query": "postgres advisory locks"]])
        #expect(w.agent(w.main)?.activity == .searching)
        #expect(w.agent(w.main)?.detail == "postgres advisory locks")
        w.hook("PostToolUse", ["tool_name": "WebSearch", "tool_use_id": "t1"])
        w.hook("PreCompact")
        #expect(w.agent(w.main)?.activity == .tidying)
        #expect(w.session?.status == .working)
        w.hook("PostCompact")
        #expect(w.agent(w.main)?.activity == .thinking)
    }

    @Test("a tool that was blocked and never reports back is cleared when its batch completes")
    func batchClears() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1"])
        #expect(w.agent(w.main)?.activity == .running)
        w.hook("PostToolBatch")
        #expect(w.agent(w.main)?.activity == .thinking)
    }

    @Test("a permission request marks the agent and the session as needing you until it resolves")
    func permission() {
        var w = Harness()
        w.spawn("one", "Explore")
        w.start("a", "Explore")
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1", "agent_id": "a", "tool_input": ["command": "rm -rf build"]])
        w.hook("PermissionRequest", ["tool_name": "Bash", "agent_id": "a", "tool_input": ["command": "rm -rf build"]])
        #expect(w.agent("a")?.activity == .asking)
        #expect(w.agent("a")?.detail == "rm -rf build")
        #expect(w.agent("a")?.status == .blocked)
        #expect(w.agent("a")?.line == "Run a command · rm -rf build")
        #expect(w.session?.needsYou == true)

        w.hook("PermissionDenied", ["tool_name": "Bash", "agent_id": "a"])
        #expect(w.agent("a")?.activity == .thinking)
        #expect(w.session?.needsYou == false)
    }

    @Test("questions, plans and MCP forms wait on you too")
    func questionsPlansForms() {
        var w = Harness()
        w.hook("PreToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "q1", "tool_input": ["questions": [["question": "Which framework?", "options": [["label": "React"]]]]]])
        #expect(w.session?.status == .blocked)
        #expect(w.agent(w.main)?.line == "Which framework?")
        w.hook("PostToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "q1"])
        #expect(w.session?.status == .working)

        w.hook("PreToolUse", ["tool_name": "ExitPlanMode", "tool_use_id": "p1", "tool_input": ["plan": "## Refactor"]])
        #expect(w.agent(w.main)?.line == "Approve the plan")
        w.hook("PostToolUse", ["tool_name": "ExitPlanMode", "tool_use_id": "p1"])

        w.hook("Elicitation", ["mcp_server_name": "github", "message": "Sign in to GitHub"])
        #expect(w.session?.needsYou == true)
        #expect(w.agent(w.main)?.line == "Sign in to GitHub")
        w.hook("ElicitationResult", ["mcp_server_name": "github", "action": "decline"])
        #expect(w.session?.needsYou == false)
    }

    @Test("a notification that Claude needs your permission marks it blocked")
    func notification() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
        #expect(w.session?.needsYou == false)
        w.hook("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
        #expect(w.session?.needsYou == true)
        #expect(w.agent(w.main)?.line == "Claude needs your permission to use Bash")
    }

    @Test("agents and sessions the app never saw start are picked up from their next event")
    func lateArrivals() {
        var w = Harness(meta: ["late": SpawnMeta(description: "audit the logs", agentType: "Explore")])
        w.hook("SubagentStop", ["agent_id": "ghost"])
        #expect(w.session?.agents.map(\.id) == [w.main])

        w.hook("PreToolUse", ["tool_name": "Grep", "tool_use_id": "t1", "agent_id": "late", "tool_input": ["pattern": "ERROR"]])
        w.settle()
        #expect(w.agent("late")?.parentID == w.main)
        #expect(w.agent("late")?.kind == "Explore")
        #expect(w.agent("late")?.title == "audit the logs")
        #expect(w.agent("late")?.activity == .reading)
    }

    @Test("an ended session is marked, then forgotten, and comes back if it resumes")
    func endAndResume() {
        var w = Harness()
        w.hook("SessionStart")
        w.hook("SessionEnd")
        #expect(w.session?.ended == true)
        w.hook("SessionStart")
        #expect(w.session?.ended == false)

        w.hook("SessionEnd")
        w.now += 21
        let forgotten = w.world.tick(now: w.now)
        #expect(forgotten == ["s1"])
        #expect(w.world.snapshots.isEmpty)
    }

    @Test("helpers silent for twenty minutes are let go; busy ones are kept")
    func staleHelpers() {
        var w = Harness()
        w.start("quiet", "Explore")
        w.start("busy", "Explore")
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1", "agent_id": "busy"])
        w.advance(21 * 60)
        #expect(w.session?.agents.map(\.id) == [w.main, "busy"])
    }

    @Test("payload fields of the wrong type are ignored rather than trusted")
    func wrongTypes() {
        var w = Harness()
        w.hook("PreToolUse", ["tool_name": 42, "tool_use_id": "t1", "tool_input": "nope"])
        #expect(w.agent(w.main)?.activity == .running)
        w.effects += w.world.ingest(["hook_event_name": "Stop", "session_id": 99], account: "personal", paneID: nil, now: w.now)
        w.effects += w.world.ingest(["hook_event_name": "Stop", "session_id": "s1", "agent_id": ["x": 1]], account: "personal", paneID: nil, now: w.now)
        w.effects += w.world.ingest("not an object", account: "personal", paneID: nil, now: w.now)
        #expect(w.agent(w.main)?.activity == .running)
        #expect(w.world.snapshots.count == 1)
    }
}

@Suite("Herdr's states")
struct AgentStatusTests {
    @Test("a finished turn is done until its pane is seen, then idle")
    func doneUntilSeen() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        #expect(w.session?.status == .working)
        w.hook("Stop")
        #expect(w.session?.status == .done)
        #expect(w.agent(w.main)?.line == "Finished")
        w.world.markSeen(sessionID: "s1", now: w.now)
        #expect(w.session?.status == .idle)
        #expect(w.agent(w.main)?.line == "Ready for you")
        // The next turn is done again until seen.
        w.hook("UserPromptSubmit")
        w.hook("Stop")
        #expect(w.session?.status == .done)
    }

    @Test("Mark as Unread makes a seen turn finished again; a session with no finished turn stays idle")
    func markUnread() {
        var w = Harness()
        w.hook("SessionStart")
        w.world.markUnread(sessionID: "s1", now: w.now)
        #expect(w.session?.status == .idle)
        w.hook("UserPromptSubmit")
        w.hook("Stop")
        w.world.markSeen(sessionID: "s1", now: w.now)
        w.world.markUnread(sessionID: "s1", now: w.now)
        #expect(w.session?.status == .done)
        w.world.markSeen(sessionID: "s1", now: w.now)
        #expect(w.session?.status == .idle)
    }

    @Test("a session that has not finished a turn yet is idle, not done")
    func freshIsIdle() {
        var w = Harness()
        w.hook("SessionStart")
        #expect(w.session?.status == .idle)
    }

    @Test("a turn that stopped on an API error is blocked until seen or a new prompt")
    func failedTurn() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("StopFailure", ["error": "rate_limit"])
        #expect(w.session?.status == .blocked)
        #expect(w.session?.failed == true)
        #expect(w.agent(w.main)?.line == "Stopped on an error")
        w.advance(3)
        #expect(w.session?.status == .blocked)
        w.world.markSeen(sessionID: "s1", now: w.now)
        #expect(w.session?.status == .idle)

        w.hook("UserPromptSubmit")
        w.hook("StopFailure")
        w.hook("UserPromptSubmit")
        #expect(w.session?.status == .working)
    }

    @Test("an error seen at once is idle at once, and the next prompt thinks: the error's flash is over")
    func errorSeenAtOnce() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("StopFailure", ["error": "rate_limit"])
        w.world.markSeen(sessionID: "s1", now: w.now)
        #expect(w.session?.status == .idle)
        // The next prompt, at once: thinking, not still flashing the error.
        w.hook("UserPromptSubmit")
        #expect(w.agent(w.main)?.activity == .thinking)
        w.hook("Stop")
        // A step that fails while the turn goes on still flashes as work.
        w.hook("UserPromptSubmit")
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1"])
        w.hook("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "t1"])
        #expect(w.session?.status == .working)
        #expect(w.agent(w.main)?.activity == .error)
    }

    @Test("an interrupted turn ends when the terminal reports the program idle, without counting as done")
    func interrupted() {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t1"])
        #expect(w.session?.status == .working)
        w.world.programIdle(paneID: "other-pane", now: w.now)
        #expect(w.session?.status == .working)
        w.world.programIdle(paneID: "pane-1", now: w.now)
        #expect(w.session?.status == .idle)
        #expect(w.agent(w.main)?.activity == .awake)
    }

    @Test("sessions sort blocked, done, working, idle; ties by time in that state")
    func urgency() {
        var w = Harness()
        w.hook("UserPromptSubmit", session: "working")
        w.hook("UserPromptSubmit", session: "done")
        w.hook("Stop", session: "done")
        w.hook("SessionStart", session: "idle")
        w.now += 1
        w.hook("UserPromptSubmit", session: "blocked-late")
        w.hook("PermissionRequest", ["tool_name": "Bash"], session: "blocked-late")
        w.now -= 2
        w.hook("UserPromptSubmit", session: "blocked-early")
        w.hook("PermissionRequest", ["tool_name": "Bash"], session: "blocked-early")
        #expect(w.world.snapshots.byUrgency.map(\.id) == ["blocked-early", "blocked-late", "done", "working", "idle"])
    }

    @Test("each line says plainly what is happening")
    func lines() {
        #expect(AgentWorld.line(activity: .running, detail: "", ask: "", status: .working, failed: false, helpers: 0) == "Running")
        #expect(AgentWorld.line(activity: .supervising, detail: "", ask: "", status: .working, failed: false, helpers: 3) == "Waiting on 3 helpers")
        #expect(AgentWorld.line(activity: .supervising, detail: "", ask: "", status: .working, failed: false, helpers: 1) == "Waiting on a helper")
        #expect(AgentWorld.line(activity: .asking, detail: "", ask: "", status: .blocked, failed: false, helpers: 0) == "Waiting for you")
        #expect(AgentWorld.line(activity: .tidying, detail: "", ask: "", status: .working, failed: false, helpers: 0) == "Compacting the conversation")
    }
}

@Suite("Agent state kept across a relaunch")
struct AgentWorldRestoreTests {
    @Test("Cats come back as they were: working, finished and not seen, helpers, to-dos; dead panes are dropped")
    func keepsWhatPanesStillHave() throws {
        var w = Harness()
        // pane-1: finished a turn you have not seen, with a to-do list.
        w.hook("UserPromptSubmit")
        w.hook("PostToolUse", ["tool_name": "TodoWrite", "tool_use_id": "t1", "tool_input": ["todos": [
            ["content": "Fix the cart", "status": "completed", "activeForm": "Fixing the cart"],
            ["content": "Ship it", "status": "pending", "activeForm": "Shipping it"]]]])
        w.hook("Stop")
        // pane-2: working, with a helper.
        w.hook("UserPromptSubmit", session: "s2", pane: "pane-2")
        w.hook("PreToolUse", ["tool_name": "Agent", "tool_use_id": "a1", "tool_input": ["subagent_type": "Explore", "description": "Map it"]], session: "s2", pane: "pane-2")
        w.hook("SubagentStart", ["agent_id": "h1", "agent_type": "Explore"], session: "s2", pane: "pane-2")
        // pane-3: a terminal that ended while the app was away.
        w.hook("UserPromptSubmit", session: "s3", pane: "pane-3")
        w.settle()
        let before = w.world.snapshots
        #expect(before.first { $0.id == "s1" }?.status == .done)
        let data = try #require(w.world.saved(keepingPanes: ["pane-1", "pane-2", "pane-3"]))

        var relaunched = AgentWorld()
        relaunched.restore(data, keepingPanes: ["pane-1", "pane-2"], now: w.now.addingTimeInterval(60))
        let after = relaunched.snapshots
        #expect(after.map(\.id) == ["s1", "s2"])
        #expect(after.first { $0.id == "s1" }?.status == .done)
        #expect(after.first { $0.id == "s2" }?.status == .working)
        #expect(after.first { $0.id == "s2" }?.agents.map(\.id) == [AgentWorld.mainAgent, "h1"])
        #expect(relaunched.progress(sessionID: "s1") == TaskProgress(done: 1, total: 2))
        // Seeing it still clears it, as before the relaunch.
        relaunched.markSeen(sessionID: "s1", now: w.now.addingTimeInterval(61))
        #expect(relaunched.snapshot(sessionID: "s1")?.status == .idle)
        // Nothing to keep: no data at all.
        #expect(AgentWorld().saved(keepingPanes: ["pane-1"]) == nil)
        #expect(w.world.saved(keepingPanes: ["elsewhere"]) == nil)
        // A stale save brings nothing back.
        var late = AgentWorld()
        late.restore(data, keepingPanes: ["pane-1", "pane-2"], now: w.now.addingTimeInterval(9 * 3600))
        #expect(late.snapshots.isEmpty)
    }

    @Test("What the terminal said while the app was away: a turn that ended is finished and unseen, a question is a request")
    func reconcilesWithTheTerminal() throws {
        var w = Harness()
        w.hook("UserPromptSubmit")
        w.hook("UserPromptSubmit", session: "s2", pane: "pane-2")
        w.hook("Stop", session: "s2", pane: "pane-2")
        w.world.markSeen(sessionID: "s2", now: w.now)
        w.settle()
        let data = try #require(w.world.saved(keepingPanes: ["pane-1", "pane-2"]))
        var world = AgentWorld()
        let now = w.now.addingTimeInterval(300)
        world.restore(data, keepingPanes: ["pane-1", "pane-2"], now: now)
        #expect(world.snapshot(sessionID: "s1")?.status == .working)
        world.reconcile(paneID: "pane-1", report: ProgramReport(state: .idle, turns: 3), now: now)
        #expect(world.snapshot(sessionID: "s1")?.status == .done)
        // An idle one that began a turn and now waits for an answer.
        #expect(world.snapshot(sessionID: "s2")?.status == .idle)
        world.reconcile(paneID: "pane-2", report: ProgramReport(state: .blocked, kind: "permission"), now: now)
        #expect(world.snapshot(sessionID: "s2")?.status == .blocked)
        world.reconcile(paneID: "pane-2", report: ProgramReport(state: .working), now: now)
        #expect(world.snapshot(sessionID: "s2")?.status == .working)
        // Nothing reported: nothing changes.
        world.reconcile(paneID: "pane-2", report: nil, now: now)
        #expect(world.snapshot(sessionID: "s2")?.status == .working)
    }
}
