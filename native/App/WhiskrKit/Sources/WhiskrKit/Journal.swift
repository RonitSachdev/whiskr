import Foundation

/// Everything a session's hooks tell beyond "who is doing what right now": the conversation, the to-do
/// list, a timeline per agent, what is waiting on you, every agent it has had, and facts about it. A
/// port of the web prototype's `server/journal.ts`. It lives in memory only and every list is bounded,
/// so a long or chatty session costs a known, small amount. File contents (what Read, Write and Edit
/// carry) are never kept, only their paths. A plain value: time comes in with each call.
public struct Journal: Sendable {
    enum Limits {
        static let chat = 200              // messages kept
        static let chatText = 16_000       // characters per message; a pasted log can be far longer
        static let chatTotal = 400_000     // characters across the whole conversation
        // Helpers' own words (their tasks and what they wrote as they worked) are kept within an
        // allowance of their own, the same size, so a busy team of helpers never pushes your
        // conversation out.
        static let helperChat = 200
        static let helperChatTotal = 400_000
        static let timeline = 500          // events kept, across all agents
        static let tasks = 100
        static let agents = 200
        static let facts = 30              // entries per list in the facts
    }

    private struct RunningTool: Sendable {
        let useID: String
        let eventID: String
        let agentID: String
        let tool: String
    }

    /// An ask, plus what settles it: the tool call it belongs to, or the form's id.
    private struct OpenAsk: Sendable {
        let ask: Ask
        let toolUseID: String
        let formID: String
        let eventID: String?
    }

    public let id: String
    /// The session's own transcript, beside which its helpers' transcripts are kept.
    public private(set) var transcriptPath = ""
    private var facts: SessionFacts
    private var agents: [AgentRecord] = []
    private var chat: [ChatEntry] = []
    /// Characters kept in the conversation and in helpers' own words, each against its own allowance.
    private var saidSize = 0
    private var heardSize = 0
    /// The next batch index expected for each reply still streaming in.
    private var streams: [String: Int] = [:]
    private var tasks: [TaskItem] = []
    private var timeline: [TimelineEvent] = []
    private var running: [RunningTool] = []
    private var asks: [OpenAsk] = []
    private var turnStartedAt: Date?
    private var changes: [DetailChange] = []
    private var factsChanged = false
    private var tasksChanged = false
    private var asksChanged = false
    private var seq = 0

    public init(sessionID: String, cwd: String, now: Date) {
        id = sessionID
        facts = SessionFacts(firstSeenAt: now, cwd: cwd)
    }

    /// After a relaunch: where its transcript is (its helpers' are beside it) and the to-dos it had.
    mutating func restore(transcriptPath: String, tasks: [TaskItem]) {
        self.transcriptPath = transcriptPath
        self.tasks = tasks
        tasksChanged = !tasks.isEmpty
    }

    /// The to-do list as it is.
    var taskItems: [TaskItem] { tasks }

    // MARK: Events

    /// Takes in one hook event. `agentID` is `AgentWorld.mainAgent` or the helper the event came from.
    public mutating func record(event: String, payload p: JSONValue, agentID: String, now: Date) {
        let isMain = agentID == AgentWorld.mainAgent
        if isMain {
            setFact(\.permissionMode, Describe.first(Describe.clip(p["permission_mode"].text, 40), facts.permissionMode))
            setFact(\.effort, Describe.first(Describe.clip(p["effort"]["level"].text, 40), facts.effort))
            if transcriptPath.isEmpty, p["transcript_path"].text.hasSuffix(".jsonl") { transcriptPath = p["transcript_path"].text }
        }
        if facts.endedAt != nil, event != "SessionEnd" {
            // A resumed session reports in again under the same id.
            setFact(\.endedAt, nil)
            setFact(\.endReason, "")
        }

        switch event {
        case "UserPromptSubmit":
            let prompt = p["prompt"].text
            let entry = say(.prompt, agentID: agentID, prompt, now: now)
            if entry.kind == .prompt { setFact(\.prompts, facts.prompts + 1) }
            turnStartedAt = now
            settleAsks(state: .denied, now: now) { $0.ask.agentID == agentID }
            let title = entry.kind == .notice ? String(localized: "Automatic notice from Claude Code", bundle: .module, comment: "A step in Claude's story: a message Claude Code itself added") : Describe.clip(Describe.first(Describe.firstLine(prompt), String(localized: "Prompt", bundle: .module, comment: "A step in Claude's story: a message you sent, when it has no text")), 120)
            note(.prompt, agentID: agentID, title: title, detail: "", now: now)
        case "UserPromptExpansion":
            let command = "/\(p["command_name"].text) \(p["command_args"].text)".trimmingCharacters(in: .whitespacesAndNewlines)
            note(.command, agentID: agentID, title: Describe.clip(command, 120), detail: Self.joined(p["expansion_type"].text, p["command_source"].text), now: now)
        case "MessageDisplay":
            // A batch index is small; anything else is treated as the first, never trusted as a number.
            let index = Describe.number(p["index"]).flatMap { Int(exactly: $0) }.flatMap { (0...1_000_000).contains($0) ? $0 : nil } ?? 0
            stream(agentID: agentID, messageID: p["message_id"].text, index: index, final: p["final"].isTrue, delta: p["delta"].text, now: now)
        case "PreToolUse":
            startTool(agentID: agentID, payload: p, now: now)
        case "PermissionRequest":
            askPermission(agentID: agentID, payload: p, now: now)
        case "PostToolUse":
            let tool = p["tool_name"].text
            applyTasks(tool: tool, input: p["tool_input"].fields, response: p["tool_response"])
            finishTool(agentID: agentID, payload: p, state: .ok, output: Describe.toolOutput(tool: tool, response: p["tool_response"]), now: now)
        case "PostToolUseFailure":
            let output = Describe.first(Describe.errorOutput(p["error"]), p["is_interrupt"].isTrue ? "Interrupted" : "")
            finishTool(agentID: agentID, payload: p, state: .failed, output: output, now: now)
        case "PermissionDenied":
            finishTool(agentID: agentID, payload: p, state: .denied, output: Describe.errorOutput(p["reason"]), now: now)
        case "PostToolBatch":
            // Every call in the batch has resolved. One still open never ran: you said no, or a hook blocked it.
            let ids = Set(p["tool_calls"].items.map { $0["tool_use_id"].text }.filter { !$0.isEmpty })
            closeRunning(output: String(localized: "It did not run.", bundle: .module, comment: "A step in Claude's story: a step that was refused"), now: now) { $0.agentID == agentID && (ids.isEmpty || ids.contains($0.useID)) }
        case "Notification":
            note(.notification, agentID: agentID, title: Describe.clip(Describe.first(p["message"].text, "Notification"), 120),
                 detail: Self.joined(p["title"].text, p["notification_type"].text), now: now)
        case "SubagentStart":
            add(.helper, agentID: agentID, title: p["agent_type"].text.isEmpty ? String(localized: "Started as a helper", bundle: .module, comment: "A step in Claude's story: a helper began") : String(localized: "Started as \(p["agent_type"].text)", bundle: .module, comment: "A step in Claude's story: a helper of the named kind began"), state: .running, now: now)
        case "SubagentStop":
            // Claude Code also runs agents of its own (prompt suggestions, /btw) that were never seen to start.
            guard agents.contains(where: { $0.id == agentID }) else { break }
            let said = p["last_assistant_message"].text
            if !Self.isBlank(said) { report(agentID: agentID, said, now: now) }
            if let helper = timeline.last(where: { $0.kind == .helper && $0.agentID == agentID && $0.state == .running }) {
                finish(helper.id, state: .ok, output: Describe.clip(said, 1_000), now: now)
            }
            closeRunning(output: String(localized: "It never reported back.", bundle: .module, comment: "A step in Claude's story: a step whose result never came"), now: now) { $0.agentID == agentID }
            settleAsks(state: .denied, now: now) { $0.ask.agentID == agentID }
        case "TaskCreated":
            putTask(p["task_id"].text, subject: p["task_subject"].text, description: p["task_description"].text, owner: p["teammate_name"].text)
        case "TaskCompleted":
            putTask(p["task_id"].text, subject: p["task_subject"].text, state: .completed)
        case "Stop":
            endTurn(agentID: agentID, said: p["last_assistant_message"].text, now: now)
            setFact(\.background, p["background_tasks"].items.prefix(Limits.facts).map { task in
                let what = Describe.first(task["description"].text, task["command"].text, task["name"].text, task["agent_type"].text)
                return Describe.clip("\(task["type"].text): \(what)", 500)
            })
            setFact(\.scheduled, p["session_crons"].items.prefix(Limits.facts).map { cron in
                Describe.clip("\(cron["schedule"].text) · \(cron["prompt"].text)", 500)
            })
        case "StopFailure":
            let error = Describe.first(p["error"].text, "unknown")
            say(.error, agentID: agentID, Describe.first(p["last_assistant_message"].text, String(localized: "API error: \(error)", bundle: .module, comment: "Claude's story: its turn stopped on an error from the service")), now: now)
            add(.error, agentID: agentID, title: String(localized: "Stopped: \(error.replacingOccurrences(of: "_", with: " "))", bundle: .module, comment: "A step in Claude's story: the turn stopped on the error named"),
                output: Describe.errorOutput(p["error_details"]), state: .failed, now: now)
            closeTurn(agentID: agentID, now: now)
        case "TeammateIdle":
            note(.helper, agentID: agentID, title: Describe.clip(p["teammate_name"].text.isEmpty ? String(localized: "A teammate is idle", bundle: .module, comment: "A step in Claude's story") : String(localized: "\(p["teammate_name"].text) is idle", bundle: .module, comment: "A step in Claude's story: the named teammate has nothing to do"), 120), detail: "", now: now)
        case "PreCompact":
            add(.compact, agentID: agentID,
                title: p["trigger"].text == "manual" ? String(localized: "Compacting the conversation, as you asked", bundle: .module, comment: "A step in Claude's story") : String(localized: "Compacting the conversation", bundle: .module, comment: "What Claude is doing: summarising its conversation to make room"),
                detail: Describe.clip(p["custom_instructions"].text, 2_000), state: .running, now: now)
        case "PostCompact":
            let summary = Describe.clip(p["compact_summary"].text, 2_000)
            if let open = timeline.last(where: { $0.kind == .compact && $0.state == .running }) {
                finish(open.id, state: .ok, output: summary, now: now)
            } else {
                add(.compact, agentID: agentID, title: String(localized: "Compacted the conversation", bundle: .module, comment: "A step in Claude's story"), output: summary, now: now)
            }
            setFact(\.compactions, facts.compactions + 1)
        case "PostModelSwitch":
            let to = Describe.clip(p["to_model"].text, 200)
            if !to.isEmpty { setFact(\.model, to) }
            let from = p["from_model"].text
            note(.model, agentID: agentID, title: to.isEmpty ? String(localized: "Model changed", bundle: .module, comment: "A step in Claude's story") : String(localized: "Model: \(to)", bundle: .module, comment: "A step in Claude's story: the model now used"),
                 detail: Self.joined(from.isEmpty ? "" : String(localized: "from \(from)", bundle: .module, comment: "A step in Claude's story: the model used before"), p["source"].text), now: now)
        case "InstructionsLoaded":
            let file = Describe.clip(p["file_path"].text, 1_000)
            addFact(\.instructions, file)
            note(.setting, agentID: agentID, title: file.isEmpty ? String(localized: "Loaded instructions", bundle: .module, comment: "A step in Claude's story") : String(localized: "Loaded \(Describe.basename(file))", bundle: .module, comment: "A step in Claude's story: read the named instructions file"),
                 detail: Self.joined(p["memory_type"].text, p["load_reason"].text, file), now: now)
        case "ConfigChange":
            let source = p["source"].text.replacingOccurrences(of: "_", with: " ")
            note(.setting, agentID: agentID, title: source.isEmpty ? String(localized: "Settings changed", bundle: .module, comment: "A step in Claude's story") : String(localized: "Settings changed: \(source)", bundle: .module, comment: "A step in Claude's story: which settings changed"), detail: Describe.clip(p["file_path"].text, 1_000), now: now)
        case "CwdChanged":
            let cwd = Describe.clip(p["new_cwd"].text, 1_000)
            if !cwd.isEmpty { setFact(\.cwd, cwd) }
            note(.setting, agentID: agentID, title: cwd.isEmpty ? String(localized: "Moved to another folder", bundle: .module, comment: "A step in Claude's story") : String(localized: "Moved to \(Describe.basename(cwd))", bundle: .module, comment: "A step in Claude's story: now works in the named folder"), detail: cwd, now: now)
        case "DirectoryAdded":
            let folder = Describe.clip(p["directory"].text, 1_000)
            addFact(\.directories, folder)
            note(.setting, agentID: agentID, title: String(localized: "Added the folder \(Describe.basename(folder))", bundle: .module, comment: "A step in Claude's story: may now work in the named folder too"), detail: folder, now: now)
        case "Elicitation":
            var formID = p["elicitation_id"].text
            if formID.isEmpty {
                seq += 1
                formID = "form-\(seq)"
            }
            ask(.form, agentID: agentID, tool: p["mcp_server_name"].text, payload: p, toolUseID: "", formID: formID, now: now)
        case "ElicitationResult":
            let server = p["mcp_server_name"].text
            let formID = p["elicitation_id"].text
            guard let open = asks.first(where: { $0.ask.kind == .form && (formID.isEmpty ? $0.ask.tool == server : $0.formID == formID) }) else { break }
            settleAsks(state: p["action"].text == "accept" ? .ok : .denied, now: now, output: p["action"].text) { $0.ask.id == open.ask.id }
        case "SessionEnd":
            setFact(\.endedAt, now)
            setFact(\.endReason, p["reason"].text)
            closeRunning(output: String(localized: "The session ended.", bundle: .module, comment: "A step in Claude's story"), now: now) { _ in true }
            settleAsks(state: .denied, now: now) { _ in true }
            note(.session, agentID: agentID, title: String(localized: "Session ended", bundle: .module, comment: "A step in Claude's story"), detail: p["reason"].text.replacingOccurrences(of: "_", with: " "), now: now)
        default:
            break
        }
    }

    /// Keeps the record of every agent in step with the world's current cast.
    public mutating func syncAgents(_ current: [AgentSnapshot], now: Date) {
        for agent in current {
            if let at = agents.firstIndex(where: { $0.id == agent.id }) {
                let known = agents[at]
                guard known.kind != agent.kind || known.title != agent.title || known.parentID != agent.parentID || known.endedAt != nil else { continue }
                putAgent(AgentRecord(id: agent.id, kind: agent.kind, title: agent.title, parentID: agent.parentID, startedAt: known.startedAt, endedAt: nil))
            } else {
                putAgent(AgentRecord(id: agent.id, kind: agent.kind, title: agent.title, parentID: agent.parentID, startedAt: now, endedAt: nil))
                trimAgents()
            }
        }
        let present = Set(current.map(\.id))
        for known in agents where known.endedAt == nil && !present.contains(known.id) {
            var ended = known
            ended.endedAt = now
            putAgent(ended)
        }
    }

    /// A model read from the transcript only fills a gap; a model switch the hooks reported is newer.
    public mutating func noteModel(_ model: String) {
        if facts.model.isEmpty, !model.isEmpty { setFact(\.model, Describe.clip(model, 200)) }
    }

    // MARK: Reading

    public var progress: TaskProgress? {
        tasks.isEmpty ? nil : TaskProgress(done: tasks.count { $0.state == .completed }, total: tasks.count)
    }

    public var detail: SessionDetail {
        SessionDetail(id: id, facts: facts, agents: agents, chat: chat, tasks: tasks, timeline: timeline, asks: asks.map(\.ask))
    }

    /// Every agent the session has had that the journal still remembers, main first.
    public var agentRecords: [AgentRecord] { agents }

    /// What changed since the last call, in order.
    public mutating func takeChanges() -> [DetailChange] {
        if factsChanged { changes.append(.facts(facts)) }
        if tasksChanged { changes.append(.tasks(tasks)) }
        if asksChanged { changes.append(.asks(asks.map(\.ask))) }
        factsChanged = false
        tasksChanged = false
        asksChanged = false
        defer { changes = [] }
        return changes
    }

    // MARK: Conversation

    /// Claude Code files its own notices as prompts, and in a helper's conversation as messages from its
    /// boss (a background helper finishing, a reminder). They open with one of its own tags.
    static func isNotice(_ text: String) -> Bool {
        let start = text.drop { $0.isWhitespace }
        for tag in ["<task-notification", "<system-reminder"] where start.hasPrefix(tag) {
            let next = start.dropFirst(tag.count).first
            if next.map({ !($0.isLetter || $0.isNumber || $0 == "_") }) ?? true { return true }
        }
        return false
    }

    /// Whether a message is a helper's own words, kept within the helpers' allowance, as opposed to the
    /// conversation with you or a report.
    private static func isHeard(_ entry: ChatEntry) -> Bool {
        entry.agentID != AgentWorld.mainAgent && [.task, .reply, .notice].contains(entry.kind)
    }

    @discardableResult
    private mutating func say(_ kind: ChatKind, agentID: String, _ said: String, now: Date, id: String? = nil, streaming: Bool = false) -> ChatEntry {
        let entryID: String
        if let id {
            entryID = id
        } else {
            seq += 1
            entryID = "chat-\(seq)"
        }
        let shown: ChatKind = (kind == .prompt || kind == .task) && Self.isNotice(said) ? .notice : kind
        var entry = ChatEntry(id: entryID, at: now, kind: shown, agentID: agentID, text: "", streaming: streaming, clipped: false)
        Self.fill(&entry, said)
        chat.append(entry)
        grow(entry, by: entry.text.count)
        changes.append(.chat(entry))
        trimChat()
        return entry
    }

    /// Puts as much of `more` into the entry as its size allows. Returns what went in.
    @discardableResult
    private static func fill(_ entry: inout ChatEntry, _ more: String) -> String {
        let room = max(0, Limits.chatText - entry.text.count)
        let taken = more.count > room ? String(more.prefix(room)) : more
        entry.text += taken
        if taken.count < more.count {
            entry.clipped = true
            entry.streaming = false
        }
        return taken
    }

    /// Claude's text as the terminal shows it: one event per batch of finished lines, in order.
    private mutating func stream(agentID: String, messageID: String, index: Int, final: Bool, delta: String, now: Date) {
        guard !messageID.isEmpty else { return }
        let id = "reply-\(Describe.clip(messageID, 100))"
        guard let at = chat.firstIndex(where: { $0.id == id }) else {
            say(.reply, agentID: agentID, delta, now: now, id: id, streaming: !final)
            if !final { streams[id] = index + 1 }
            return
        }
        guard chat[at].streaming, let expected = streams[id], index >= expected else { return }
        let wasClipped = chat[at].clipped
        let taken = Self.fill(&chat[at], delta)
        grow(chat[at], by: taken.count)
        if final { chat[at].streaming = false }
        streams[id] = chat[at].streaming ? index + 1 : nil
        // Once cut short, the view gets the entry whole so it can show that it was.
        if chat[at].clipped && !wasClipped {
            changes.append(.chat(chat[at]))
        } else {
            changes.append(.chatAppend(id: id, text: taken, streaming: chat[at].streaming))
        }
        trimChat()
    }

    /// The turn is over. `said` is Claude's final message, which streaming may already have delivered.
    private mutating func endTurn(agentID: String, said: String, now: Date) {
        let latest = chat.lastIndex { $0.agentID == agentID && [.reply, .prompt, .notice].contains($0.kind) }
        let last = latest.flatMap { chat[$0].kind == .reply ? $0 : nil }
        if let last, chat[last].clipped || Self.same(chat[last].text, said) {
            if chat[last].streaming { finishReply(at: last, said: chat[last].text) }
        } else if let last, chat[last].streaming {
            finishReply(at: last, said: said)
        } else if !Self.isBlank(said) {
            say(.reply, agentID: agentID, said, now: now)
        }
        add(.turn, agentID: agentID, title: String(localized: "Finished the turn", bundle: .module, comment: "A step in Claude's story: Claude ended its turn"), state: .ok, duration: turnStartedAt.map { now.timeIntervalSince($0) }, now: now)
        closeTurn(agentID: agentID, now: now)
    }

    private mutating func finishReply(at index: Int, said: String) {
        grow(chat[index], by: -chat[index].text.count)
        chat[index].text = ""
        chat[index].clipped = false
        Self.fill(&chat[index], said)
        grow(chat[index], by: chat[index].text.count)
        chat[index].streaming = false
        streams[chat[index].id] = nil
        changes.append(.chat(chat[index]))
    }

    private mutating func closeTurn(agentID: String, now: Date) {
        turnStartedAt = nil
        closeRunning(output: String(localized: "It never reported back.", bundle: .module, comment: "A step in Claude's story: a step whose result never came"), now: now) { $0.agentID == agentID }
        settleAsks(state: .denied, now: now) { $0.ask.agentID == agentID }
    }

    private mutating func grow(_ entry: ChatEntry, by size: Int) {
        if Self.isHeard(entry) { heardSize += size } else { saidSize += size }
    }

    /// Lets the oldest messages go while either the conversation or the helpers' words are over allowance.
    private mutating func trimChat() {
        var dropped: [String] = []
        for heard in [false, true] {
            let most = heard ? Limits.helperChat : Limits.chat
            let total = heard ? Limits.helperChatTotal : Limits.chatTotal
            var count = chat.count { Self.isHeard($0) == heard }
            while count > 1, count > most || (heard ? heardSize : saidSize) > total,
                  let oldest = chat.firstIndex(where: { Self.isHeard($0) == heard }) {
                let old = chat.remove(at: oldest)
                grow(old, by: -old.text.count)
                streams[old.id] = nil
                dropped.append(old.id)
                count -= 1
            }
        }
        if !dropped.isEmpty { changes.append(.drop(.chat, ids: dropped)) }
    }

    /// A helper's own words, read from its transcript. Records already heard are skipped by their id, and
    /// so is its last message once it has arrived as the report.
    public mutating func heard(agentID: String, said: [HelperSaid], now: Date) {
        guard agentID != AgentWorld.mainAgent, agents.contains(where: { $0.id == agentID }) else { return }
        let prefix = "heard-\(Describe.clip(agentID, 100))-"
        for one in said {
            let id = prefix + Describe.clip(one.id, 100)
            if chat.contains(where: { $0.id == id }) { continue }
            if one.kind == .reply, chat.contains(where: { $0.agentID == agentID && $0.kind == .report && Self.sameStart($0.text, one.text) }) { continue }
            say(one.kind == .task ? .task : .reply, agentID: agentID, one.text, now: one.at ?? now, id: id)
        }
    }

    /// A helper hands its final message back. If its transcript already gave that message as a reply,
    /// the reply makes way for the report rather than showing the same words twice.
    private mutating func report(agentID: String, _ said: String, now: Date) {
        let echoes = chat.filter { $0.agentID == agentID && $0.kind == .reply && $0.id.hasPrefix("heard-") && Self.sameStart($0.text, said) }
        if !echoes.isEmpty {
            for echo in echoes { grow(echo, by: -echo.text.count) }
            let gone = Set(echoes.map(\.id))
            chat.removeAll { gone.contains($0.id) }
            changes.append(.drop(.chat, ids: echoes.map(\.id)))
        }
        say(.report, agentID: agentID, said, now: now)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same words, as far as a message is kept: one copy may have been cut short at the size limit.
    private static func sameStart(_ kept: String, _ full: String) -> Bool {
        same(kept, String(full.prefix(Limits.chatText)))
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Timeline

    @discardableResult
    private mutating func add(_ kind: TimelineKind, agentID: String, tool: String = "", title: String, detail: String = "", output: String = "",
                              state: EventState = .info, duration: TimeInterval? = nil, now: Date) -> TimelineEvent {
        seq += 1
        let event = TimelineEvent(id: "event-\(seq)", at: now, agentID: agentID, kind: kind, tool: tool, title: title, detail: detail,
                                  output: output, state: state, duration: duration)
        timeline.append(event)
        changes.append(.event(event))
        if timeline.count > Limits.timeline {
            let gone = timeline.prefix(timeline.count - Limits.timeline).map(\.id)
            timeline.removeFirst(gone.count)
            changes.append(.drop(.timeline, ids: gone))
        }
        return event
    }

    private mutating func note(_ kind: TimelineKind, agentID: String, title: String, detail: String, now: Date) {
        add(kind, agentID: agentID, title: title, detail: detail, now: now)
    }

    /// An event that has already scrolled out of the timeline is not brought back.
    private mutating func finish(_ eventID: String, state: EventState, output: String, now: Date, duration: TimeInterval? = nil) {
        guard let at = timeline.lastIndex(where: { $0.id == eventID }) else { return }
        timeline[at].state = state
        if !output.isEmpty { timeline[at].output = output }
        timeline[at].duration = duration ?? now.timeIntervalSince(timeline[at].at)
        changes.append(.event(timeline[at]))
    }

    private mutating func startTool(agentID: String, payload p: JSONValue, now: Date) {
        let tool = Describe.first(p["tool_name"].text, "tool")
        let input = p["tool_input"].fields
        var useID = p["tool_use_id"].text
        if useID.isEmpty {
            seq += 1
            useID = "call-\(seq)"
        }
        let tasks = tasks
        let event = add(.tool, agentID: agentID, tool: tool,
                        title: Describe.toolTitle(tool: tool, input: input) { id in tasks.first { $0.id == id }?.subject ?? "" },
                        detail: Describe.toolTarget(tool: tool, input: input), state: .running, now: now)
        let call = RunningTool(useID: useID, eventID: event.id, agentID: agentID, tool: tool)
        if let known = running.firstIndex(where: { $0.useID == useID }) { running[known] = call } else { running.append(call) }
        if tool == "AskUserQuestion" { ask(.question, agentID: agentID, tool: tool, payload: p, toolUseID: useID, formID: "", now: now) }
        if tool == "ExitPlanMode" { ask(.plan, agentID: agentID, tool: tool, payload: p, toolUseID: useID, formID: "", now: now) }
        // In auto mode a helper hands its report over through this tool rather than as its last message.
        if tool == "SubagentHandback", !Self.isBlank(input["message"].text) { report(agentID: agentID, input["message"].text, now: now) }
    }

    /// The tool call a payload is about: by its id, or else this agent's latest open call of that tool.
    private func call(agentID: String, useID: String, tool: String) -> RunningTool? {
        if !useID.isEmpty, let exact = running.first(where: { $0.useID == useID }) { return exact }
        return running.last { $0.agentID == agentID && $0.tool == tool }
    }

    private mutating func finishTool(agentID: String, payload p: JSONValue, state: EventState, output: String, now: Date) {
        guard let found = call(agentID: agentID, useID: p["tool_use_id"].text, tool: p["tool_name"].text) else { return }
        running.removeAll { $0.useID == found.useID }
        finish(found.eventID, state: state, output: output, now: now, duration: Describe.number(p["duration_ms"]).map { $0 / 1_000 })
        // It reached the point of running, so any approval it waited on was given.
        settleAsks(state: state == .denied ? .denied : .ok, now: now) { $0.toolUseID == found.useID }
    }

    private mutating func closeRunning(output: String, now: Date, _ which: (RunningTool) -> Bool) {
        for call in running where which(call) {
            running.removeAll { $0.useID == call.useID }
            finish(call.eventID, state: .denied, output: output, now: now)
            settleAsks(state: .denied, now: now) { $0.toolUseID == call.useID }
        }
    }

    // MARK: Waiting on you

    private mutating func askPermission(agentID: String, payload p: JSONValue, now: Date) {
        let tool = p["tool_name"].text
        // The request carries no call id, so it belongs to this agent's latest open call of the tool.
        let useID = call(agentID: agentID, useID: "", tool: tool)?.useID ?? ""
        // Questions and plans already wait on you as themselves.
        if !useID.isEmpty, asks.contains(where: { $0.toolUseID == useID }) { return }
        ask(.permission, agentID: agentID, tool: Describe.first(tool, "tool"), payload: p, toolUseID: useID, formID: "", now: now)
    }

    private mutating func ask(_ kind: AskKind, agentID: String, tool: String, payload: JSONValue, toolUseID: String, formID: String, now: Date) {
        let said = Describe.askText(kind: kind, tool: tool, payload: payload)
        seq += 1
        let ask = Ask(id: "ask-\(seq)", at: now, kind: kind, agentID: agentID, tool: tool, summary: said.summary, description: said.description,
                      target: said.target, options: said.options, input: said.input, questionCount: said.questionCount, multiSelect: said.multiSelect)
        // Questions and plans are tool calls with an event of their own; permissions and forms get one here.
        let event = kind == .permission || kind == .form
            ? add(kind == .form ? .question : .permission, agentID: agentID, tool: tool, title: said.summary, detail: said.target, state: .running, now: now)
            : nil
        asks.append(OpenAsk(ask: ask, toolUseID: toolUseID, formID: formID, eventID: event?.id))
        asksChanged = true
    }

    private mutating func settleAsks(state: EventState, now: Date, output: String = "", _ which: (OpenAsk) -> Bool) {
        let settled = asks.filter(which)
        guard !settled.isEmpty else { return }
        asks.removeAll(where: which)
        for open in settled {
            if let eventID = open.eventID {
                finish(eventID, state: state, output: Describe.first(output, state == .ok ? String(localized: "Allowed", bundle: .module, comment: "A step in Claude's story: a request you allowed") : String(localized: "Not allowed", bundle: .module, comment: "A step in Claude's story: a request that was refused")), now: now)
            }
        }
        asksChanged = true
    }

    // MARK: To-do list

    private mutating func applyTasks(tool: String, input: [String: JSONValue], response: JSONValue?) {
        let r = response.fields
        switch tool {
        case "TaskCreate":
            let task = r["task"]
            putTask(task["id"].text, subject: Describe.first(input["subject"].text, task["subject"].text), description: input["description"].text,
                    activeForm: Describe.first(input["activeForm"].text, input["active_form"].text))
        case "TaskUpdate":
            if r["success"] == .bool(false) { return }
            let id = Describe.first(Describe.taskID(input), r["taskId"].text)
            let state = input["status"].text
            if state == "deleted" {
                let before = tasks.count
                tasks.removeAll { $0.id == Describe.clip(id, 100) }
                if tasks.count != before { tasksChanged = true }
                return
            }
            putTask(id, subject: input["subject"].text, description: input["description"].text,
                    activeForm: Describe.first(input["activeForm"].text, input["active_form"].text), owner: input["owner"].text, state: TaskState(rawValue: state))
        case "TaskList":
            // A full listing: the surest view of the list, and how one started before the app caught up.
            guard case .array(let listed) = r["tasks"] else { return }
            let before = tasks
            tasks = []
            for task in listed.filter({ !$0["id"].text.isEmpty }).prefix(Limits.tasks) {
                let id = Describe.clip(task["id"].text, 100)
                let known = before.first { $0.id == id }
                tasks.append(TaskItem(
                    id: id, subject: Describe.first(Describe.clip(task["subject"].text, 200), known?.subject ?? "", "Task \(id)"),
                    activeForm: known?.activeForm ?? "", description: known?.description ?? "",
                    state: TaskState(rawValue: task["status"].text) ?? known?.state ?? .pending, owner: Describe.clip(task["owner"].text, 100)))
            }
            tasksChanged = true
        case "TodoWrite":
            // The older checklist tool sends the whole list every time.
            let todos = input["todos"].items.isEmpty ? r["newTodos"].items : input["todos"].items
            tasks = todos.prefix(Limits.tasks).enumerated().map { at, todo in
                TaskItem(id: "todo-\(at + 1)", subject: Describe.clip(todo["content"].text, 200), activeForm: Describe.clip(todo["activeForm"].text, 200),
                         description: "", state: TaskState(rawValue: todo["status"].text) ?? .pending, owner: "")
            }
            tasksChanged = true
        default:
            break
        }
    }

    private mutating func putTask(_ rawID: String, subject: String = "", description: String = "", activeForm: String = "", owner: String = "", state: TaskState? = nil) {
        guard !rawID.isEmpty else { return }
        let id = Describe.clip(rawID, 100)
        let known = tasks.firstIndex { $0.id == id }
        var task = known.map { tasks[$0] } ?? TaskItem(id: id, subject: "", activeForm: "", description: "", state: .pending, owner: "")
        if !subject.isEmpty { task.subject = Describe.clip(subject, 200) }
        if !description.isEmpty { task.description = Describe.clip(description, 1_000) }
        if !activeForm.isEmpty { task.activeForm = Describe.clip(activeForm, 200) }
        if !owner.isEmpty { task.owner = Describe.clip(owner, 100) }
        if let state { task.state = state }
        if task.subject.isEmpty { task.subject = String(localized: "Task \(task.id)", bundle: .module, comment: "A to-do without a title: its number") }
        if let known {
            tasks[known] = task
        } else {
            tasks.append(task)
            // Too many: let the oldest finished one go, or else the oldest.
            if tasks.count > Limits.tasks { tasks.remove(at: tasks.firstIndex { $0.state == .completed } ?? 0) }
        }
        tasksChanged = true
    }

    // MARK: Facts and agents

    private mutating func setFact<Value: Equatable>(_ key: WritableKeyPath<SessionFacts, Value>, _ value: Value) {
        guard facts[keyPath: key] != value else { return }
        facts[keyPath: key] = value
        factsChanged = true
    }

    private mutating func addFact(_ key: WritableKeyPath<SessionFacts, [String]>, _ value: String) {
        guard !value.isEmpty, !facts[keyPath: key].contains(value) else { return }
        setFact(key, Array((facts[keyPath: key] + [value]).suffix(Limits.facts)))
    }

    private mutating func putAgent(_ agent: AgentRecord) {
        if let at = agents.firstIndex(where: { $0.id == agent.id }) { agents[at] = agent } else { agents.append(agent) }
        changes.append(.agent(agent))
    }

    private mutating func trimAgents() {
        guard agents.count > Limits.agents, let gone = agents.firstIndex(where: { $0.endedAt != nil }) else { return }
        let id = agents.remove(at: gone).id
        changes.append(.drop(.agents, ids: [id]))
    }

    /// Changes nobody is watching are let go as they happen; whoever starts watching takes `detail` whole.
    mutating func discardChanges() {
        changes.removeAll()
        factsChanged = false
        tasksChanged = false
        asksChanged = false
    }
}
