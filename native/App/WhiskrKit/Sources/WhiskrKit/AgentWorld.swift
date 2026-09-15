import Foundation

/// What an agent is doing right now, finer than herdr's states. Same words as the web prototype.
public enum Activity: String, Sendable, CaseIterable, Codable {
    case awake, reading, editing, running, searching, thinking, tidying, supervising, asking, napping, error
}

/// Herdr's states, in order of urgency: the order the sidebar sorts by.
///   blocked: waiting for you (a permission, a question, a form) or stopped on an error you have not seen.
///   done:    finished a turn and you have not looked at its pane since.
///   working: still busy.
///   idle:    not working, or done and seen.
///   unknown: a Claude pane that has not reported anything yet.
public enum AgentStatus: Int, Sendable, Comparable, CaseIterable, Codable {
    case blocked, done, working, idle, unknown

    public static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The small file Claude Code writes beside each helper's transcript naming the tool call that launched it.
public struct SpawnMeta: Sendable, Equatable {
    public var toolUseID: String?
    public var description: String?
    public var agentType: String?

    public init(toolUseID: String? = nil, description: String? = nil, agentType: String? = nil) {
        self.toolUseID = toolUseID
        self.description = description
        self.agentType = agentType
    }
}

/// What the end of a session's transcript says that hooks do not: the chat's name and the model answering.
public struct TranscriptFacts: Sendable, Equatable {
    public var title: String?
    public var model: String?

    public init(title: String? = nil, model: String? = nil) {
        self.title = title
        self.model = model
    }
}

/// File reads the world needs and cannot do itself, being a plain value. Whoever owns the world performs
/// them off the main thread and hands the results back with `apply(transcript:)` and `apply(meta:)`.
public enum WorldEffect: Sendable, Equatable {
    case readTranscript(sessionID: String, transcriptPath: String)
    case readMeta(sessionID: String, agentID: String, transcriptPath: String)
}

/// What a request waits for, which Settings › Alerts can sound differently: a permission (Claude Code's
/// PermissionRequest, or its permission_prompt notification), or a question, a plan to approve or a form
/// to fill in (AskUserQuestion, ExitPlanMode, an MCP server's elicitation).
public enum RequestKind: String, Sendable, Codable {
    case permission, question
}

public struct AgentSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String           // agent type, e.g. "Explore"; "main" for the session's own Claude
    public let title: String          // the task it was launched with ("" for main)
    public let parentID: String?      // who launched it; nil only for main
    public let depth: Int             // 0 for main, 1 for its helpers, 2 for theirs…
    public let activity: Activity
    public let detail: String         // what exactly: a file name, a command
    public let status: AgentStatus
    public let line: String           // one plain line for the sidebar, e.g. "Running · npm test"
    public let since: Date            // when this activity began
    public let request: RequestKind?  // what it waits for, while it asks
}

public struct SessionSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let account: String
    public let paneID: String?
    public let cwd: String
    public let project: String
    public let title: String
    public let ended: Bool
    public let status: AgentStatus
    public let statusSince: Date
    public let failed: Bool           // the last turn stopped on an API error you have not seen
    public let agents: [AgentSnapshot] // launch order, main first

    public var main: AgentSnapshot { agents[0] }
    /// Owned: started in one of the app's panes, so the app has its terminal. Watched: reported by
    /// hooks from a session running elsewhere (no pane), which the app can show but not type into.
    public var isOwned: Bool { paneID != nil }
    public var needsYou: Bool { status == .blocked }
    /// What the session waits for: its own Claude's request first, else a helper's.
    public var request: RequestKind? { agents.lazy.compactMap(\.request).first }
}

/// Turns the stream of Claude Code hook events into "who exists and what are they doing right now".
/// A port of the web prototype's `server/world.ts`, plus herdr's "done until seen". Each session's
/// chat, tasks and timeline are kept beside it in a `Journal` (see JournalWiring.swift).
/// A plain value with no clock and no files: time comes in with each call and file reads go out as
/// effects, so every case can be tested directly.
public struct AgentWorld: Sendable {
    public static let mainAgent = "main"

    static let errorFlash: TimeInterval = 2.5
    /// How long after its turn ends a waiting Claude dozes off.
    public static let napAfter: TimeInterval = 45
    static let forgetEnded: TimeInterval = 20
    static let staleSession: TimeInterval = 8 * 3600
    static let staleAgent: TimeInterval = 20 * 60
    static let staleSpawn: TimeInterval = 10 * 60
    /// A chat's name can change as it goes on, but not often enough to look more than this.
    static let titleEvery: TimeInterval = 20
    /// Claude Code writes the first name a few seconds into the first turn, often after the last
    /// event of a short turn, so an unnamed session is looked at this often until it has one.
    static let untitledEvery: TimeInterval = 3

    private static let reading: Set = ["Read", "Grep", "Glob", "LS", "NotebookRead", "ToolSearch", "LSP", "TaskOutput", "BashOutput"]
    private static let searching: Set = ["WebSearch", "WebFetch"]
    private static let editing: Set = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    private static let spawning: Set = ["Agent", "Task"]
    private static let asking: Set = ["AskUserQuestion", "ExitPlanMode"]
    private static let planning: Set = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "EnterPlanMode", "Skill"]
    private static let needsYouNotifications: Set = ["permission_prompt", "elicitation_dialog", "agent_needs_input"]
    /// Of those, the one that asks for a permission; the others ask a question or for a form.
    private static let permissionNotification = "permission_prompt"

    private struct PendingTool: Sendable, Codable {
        let id: String
        let tool: String
        let activity: Activity
        let detail: String
    }

    /// An Agent tool call that has been made; the helper it launches claims it when it shows up.
    private struct Spawn: Sendable, Codable {
        let id: String
        let parentID: String
        let kind: String
        let title: String
        let at: Date
        var claimedBy: String?
    }

    private struct Agent: Sendable, Codable {
        let id: String
        var kind: String
        var title: String
        var parentID: String?
        var pending: [PendingTool] = []
        var needsYou = false
        /// What `needsYou` waits for (optional, so agents kept by an earlier version still load).
        var askKind: RequestKind?
        var ask = ""
        var errorUntil = Date.distantPast
        var lastSeen: Date
        var activity: Activity = .awake
        var detail = ""
        var since: Date
    }

    private struct Session: Sendable, Codable {
        let id: String
        var account: String
        var paneID: String?
        var cwd: String
        var title = ""
        var titleCheckedAt = Date.distantPast
        var transcriptPath = ""
        var agents: [Agent]
        var spawns: [Spawn] = []
        var turnActive = false
        var compacting = false
        var stoppedAt: Date
        var ended = false
        var endedAt = Date.distantPast
        var lastSeen: Date
        /// Turns finished, and how many of them you have seen. Done = turns > seen (herdr's `turn` and `herdr.seen`).
        var turns = 0
        var seenTurns = 0
        var failed = false
        var status: AgentStatus = .idle
        var statusSince: Date

        func index(of agentID: String) -> Int? { agents.firstIndex { $0.id == agentID } }
    }

    private var sessions: [Session] = []
    private var unnamed = 0
    var journals = Journals()

    public init() {}

    // MARK: Events

    /// Takes in one hook event posted from the pane `paneID` of a session running under `account`.
    @discardableResult
    public mutating func ingest(_ payload: JSONValue, account: String, paneID: String?, now: Date) -> [WorldEffect] {
        let event = payload["hook_event_name"].text
        let sessionID = payload["session_id"].text
        // Payloads come from outside: anything not shaped like a hook event is ignored.
        guard !event.isEmpty, !sessionID.isEmpty else { return [] }
        if let field = payload["agent_id"] {
            guard case .string = field else { return [] }
        }
        var effects: [WorldEffect] = []
        let s = session(for: payload, sessionID: sessionID, account: account, paneID: paneID, now: now, effects: &effects)
        journals.record(payload, sessionID: sessionID, cwd: sessions[s].cwd, now: now)
        let agentID = payload["agent_id"].text

        switch event {
        case "SessionEnd":
            sessions[s].ended = true
            sessions[s].endedAt = now
            refresh(now: now)
            return effects
        case "SubagentStop":
            if !agentID.isEmpty, let gone = sessions[s].index(of: agentID), agentID != Self.mainAgent {
                remove(agentAt: gone, from: s)
            }
            refresh(now: now)
            return effects
        default:
            break
        }

        // Any event from an agent we haven't met (the app may have started mid-run) introduces it.
        let a = agentID.isEmpty ? 0 : subagent(agentID, type: payload["agent_type"].text, in: s, now: now, effects: &effects)
        let isMain = a == 0
        sessions[s].agents[a].lastSeen = now

        switch event {
        case "UserPromptSubmit":
            sessions[s].turnActive = true
            sessions[s].failed = false
            sessions[s].agents[a].needsYou = false
            // A new turn: the last one's error has had its moment.
            sessions[s].agents[a].errorUntil = .distantPast
        case "PreToolUse":
            let tool = payload["tool_name"].text.isEmpty ? "tool" : payload["tool_name"].text
            let input = payload["tool_input"].fields
            var id = payload["tool_use_id"].text
            if id.isEmpty {
                unnamed += 1
                id = "unnamed-\(unnamed)"
            }
            sessions[s].agents[a].needsYou = false
            sessions[s].agents[a].pending.removeAll { $0.id == id }
            sessions[s].agents[a].pending.append(PendingTool(id: id, tool: tool, activity: Self.activity(of: tool), detail: Self.pendingDetail(tool: tool, input: input)))
            if Self.spawning.contains(tool) {
                sessions[s].spawns.append(Spawn(id: id, parentID: sessions[s].agents[a].id, kind: input["subagent_type"].text, title: input["description"].text, at: now))
            }
            if isMain { sessions[s].turnActive = true }
        case "PermissionRequest":
            sessions[s].agents[a].needsYou = true
            sessions[s].agents[a].askKind = Self.asking.contains(payload["tool_name"].text) ? .question : .permission
            sessions[s].agents[a].ask = Describe.permissionSummary(tool: payload["tool_name"].text, input: payload["tool_input"].fields)
        case "Notification":
            if Self.needsYouNotifications.contains(payload["notification_type"].text) {
                // Claude Code sends this after the PermissionRequest of the same ask, which knows the tool:
                // that one's kind stands.
                if !sessions[s].agents[a].needsYou {
                    sessions[s].agents[a].askKind = payload["notification_type"].text == Self.permissionNotification ? .permission : .question
                }
                sessions[s].agents[a].needsYou = true
                if sessions[s].agents[a].ask.isEmpty { sessions[s].agents[a].ask = Describe.clip(Describe.firstLine(payload["message"].text), 80) }
            }
        case "PostToolUse", "PermissionDenied":
            settle(agentAt: a, in: s, payload: payload)
        case "PostToolUseFailure":
            settle(agentAt: a, in: s, payload: payload)
            if !payload["is_interrupt"].isTrue { sessions[s].agents[a].errorUntil = now.addingTimeInterval(Self.errorFlash) }
        case "PostToolBatch":
            // Every call the agent made together has now finished. A call that another hook blocked
            // never reports back on its own, so this is what stops it looking busy forever.
            sessions[s].agents[a].pending.removeAll()
            sessions[s].agents[a].needsYou = false
        case "Stop":
            if isMain { endTurn(s, now: now, counted: true, failed: false) }
        case "StopFailure":
            if isMain { endTurn(s, now: now, counted: true, failed: true) }
            sessions[s].agents[a].errorUntil = now.addingTimeInterval(Self.errorFlash)
        case "PreCompact":
            sessions[s].compacting = true
        case "PostCompact":
            sessions[s].compacting = false
        case "Elicitation":
            sessions[s].agents[a].needsYou = true
            sessions[s].agents[a].askKind = .question
            let message = Describe.clip(Describe.firstLine(payload["message"].text), 80)
            sessions[s].agents[a].ask = message.isEmpty ? String(localized: "An MCP server needs your input", bundle: .module, comment: "A request: a tool's form waits to be filled in") : message
        case "ElicitationResult":
            sessions[s].agents[a].needsYou = false
        default:
            break
        }
        refresh(now: now)
        return effects
    }

    /// The terminal itself reported that the program in `paneID` is no longer working (OSC 7501).
    /// Claude Code sends no hook when you interrupt a turn with Esc, so without this a turn you
    /// stopped would look busy until the next prompt.
    public mutating func programIdle(paneID: String, now: Date) {
        guard let s = sessions.lastIndex(where: { $0.paneID == paneID && !$0.ended }), sessions[s].turnActive else { return }
        endTurn(s, now: now, counted: false, failed: false)
        refresh(now: now)
    }

    /// You looked at this session's pane: its finished turns and its error stop are seen.
    public mutating func markSeen(sessionID: String, now: Date) {
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard sessions[s].seenTurns != sessions[s].turns || sessions[s].failed else { return }
        sessions[s].seenTurns = sessions[s].turns
        sessions[s].failed = false
        refresh(now: now)
    }

    /// Mark as Unread (herdr writes `turn - 1`): the last finished turn shows as not seen again.
    public mutating func markUnread(sessionID: String, now: Date) {
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }), sessions[s].turns > 0,
              sessions[s].seenTurns >= sessions[s].turns else { return }
        sessions[s].seenTurns = sessions[s].turns - 1
        refresh(now: now)
    }

    /// Timed changes that no event announces: error flashes ending, naps starting, things going stale.
    /// Returns the sessions forgotten.
    @discardableResult
    public mutating func tick(now: Date) -> [String] {
        var forgotten: [String] = []
        sessions.removeAll { s in
            let gone = (s.ended && now.timeIntervalSince(s.endedAt) > Self.forgetEnded) || now.timeIntervalSince(s.lastSeen) > Self.staleSession
            if gone { forgotten.append(s.id) }
            return gone
        }
        for s in sessions.indices {
            while let stale = sessions[s].agents.indices.dropFirst().first(where: {
                sessions[s].agents[$0].pending.isEmpty && now.timeIntervalSince(sessions[s].agents[$0].lastSeen) > Self.staleAgent
            }) {
                remove(agentAt: stale, from: s)
            }
            sessions[s].spawns.removeAll { $0.claimedBy == nil && now.timeIntervalSince($0.at) > Self.staleSpawn }
        }
        refresh(now: now)
        return forgotten
    }

    /// Transcript reads that are due without any event: unnamed sessions often, named ones now and
    /// then (a name can be changed with /rename). Call it with each tick.
    public mutating func dueReads(now: Date) -> [WorldEffect] {
        var effects: [WorldEffect] = []
        for s in sessions.indices where !sessions[s].ended && !sessions[s].transcriptPath.isEmpty {
            let every = sessions[s].title.isEmpty ? Self.untitledEvery : Self.titleEvery
            guard now.timeIntervalSince(sessions[s].titleCheckedAt) > every else { continue }
            sessions[s].titleCheckedAt = now
            effects.append(.readTranscript(sessionID: sessions[s].id, transcriptPath: sessions[s].transcriptPath))
        }
        return effects
    }

    // MARK: File results

    public mutating func apply(transcript facts: TranscriptFacts, sessionID: String, now: Date) {
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let title = facts.title, !title.isEmpty { sessions[s].title = title }
        if let model = facts.model { journals.noteModel(model, sessionID: sessionID) }
        refresh(now: now)
    }

    /// The meta file for a helper, or nil when it could not be read (yet). Returns whether the helper
    /// still needs it: true asks the caller to try again a little later.
    @discardableResult
    public mutating func apply(meta: SpawnMeta?, sessionID: String, agentID: String, now: Date) -> Bool {
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }), let a = sessions[s].index(of: agentID), a != 0 else { return false }
        guard let meta else { return true }
        if let toolUseID = meta.toolUseID, let spawn = sessions[s].spawns.firstIndex(where: { $0.id == toolUseID }) {
            for other in sessions[s].spawns.indices where sessions[s].spawns[other].claimedBy == agentID {
                sessions[s].spawns[other].claimedBy = nil
            }
            sessions[s].spawns[spawn].claimedBy = agentID
            sessions[s].agents[a].parentID = sessions[s].spawns[spawn].parentID
            if !sessions[s].spawns[spawn].title.isEmpty { sessions[s].agents[a].title = sessions[s].spawns[spawn].title }
        }
        if sessions[s].agents[a].title.isEmpty { sessions[s].agents[a].title = meta.description ?? "" }
        if let type = meta.agentType, !type.isEmpty { sessions[s].agents[a].kind = type }
        refresh(now: now)
        return false
    }

    // MARK: Reading

    public var snapshots: [SessionSnapshot] { sessions.map(snapshot) }

    public func snapshot(sessionID: String) -> SessionSnapshot? {
        sessions.first { $0.id == sessionID }.map(snapshot)
    }

    // MARK: Internals

    private mutating func session(for payload: JSONValue, sessionID: String, account: String, paneID: String?, now: Date, effects: inout [WorldEffect]) -> Int {
        let s: Int
        if let known = sessions.firstIndex(where: { $0.id == sessionID }) {
            s = known
        } else {
            let main = Agent(id: Self.mainAgent, kind: "main", title: "", parentID: nil, lastSeen: now, since: now)
            sessions.append(Session(id: sessionID, account: account, paneID: paneID, cwd: payload["cwd"].text, agents: [main], stoppedAt: now, lastSeen: now, statusSince: now))
            s = sessions.count - 1
        }
        // A resumed session reports in again under the same id.
        sessions[s].ended = false
        sessions[s].lastSeen = now
        if let paneID { sessions[s].paneID = paneID }
        let title = payload["session_title"].text
        if !title.isEmpty { sessions[s].title = title }
        let path = payload["transcript_path"].text
        if !path.isEmpty, sessions[s].transcriptPath.isEmpty, payload["agent_id"].text.isEmpty { sessions[s].transcriptPath = path }
        if !sessions[s].transcriptPath.isEmpty, now.timeIntervalSince(sessions[s].titleCheckedAt) > Self.titleEvery {
            sessions[s].titleCheckedAt = now
            effects.append(.readTranscript(sessionID: sessionID, transcriptPath: sessions[s].transcriptPath))
        }
        return s
    }

    private mutating func subagent(_ agentID: String, type: String, in s: Int, now: Date, effects: inout [WorldEffect]) -> Int {
        if let known = sessions[s].index(of: agentID) { return known }
        // Show the helper right away under our best guess of its parent, then confirm from the meta file.
        // Without it all we know is order: the oldest unclaimed launch, preferring one of the same type.
        let open = sessions[s].spawns.indices.filter { sessions[s].spawns[$0].claimedBy == nil }
        let guess = open.first { sessions[s].spawns[$0].kind == type } ?? open.first
        if let guess { sessions[s].spawns[guess].claimedBy = agentID }
        let spawn = guess.map { sessions[s].spawns[$0] }
        let kind = [type, spawn?.kind ?? ""].first { !$0.isEmpty } ?? "agent"
        sessions[s].agents.append(Agent(id: agentID, kind: kind, title: spawn?.title ?? "", parentID: spawn?.parentID ?? Self.mainAgent, lastSeen: now, since: now))
        effects.append(.readMeta(sessionID: sessions[s].id, agentID: agentID, transcriptPath: sessions[s].transcriptPath))
        return sessions[s].agents.count - 1
    }

    private mutating func remove(agentAt a: Int, from s: Int) {
        let gone = sessions[s].agents[a]
        // Helpers that outlive whoever launched them move up to the next boss.
        for other in sessions[s].agents.indices where sessions[s].agents[other].parentID == gone.id {
            sessions[s].agents[other].parentID = gone.parentID
        }
        sessions[s].spawns.removeAll { $0.claimedBy == gone.id }
        sessions[s].agents.remove(at: a)
    }

    private mutating func settle(agentAt a: Int, in s: Int, payload: JSONValue) {
        sessions[s].agents[a].needsYou = false
        let id = payload["tool_use_id"].text
        if !id.isEmpty, let pending = sessions[s].agents[a].pending.firstIndex(where: { $0.id == id }) {
            sessions[s].agents[a].pending.remove(at: pending)
            return
        }
        let tool = payload["tool_name"].text
        if let same = sessions[s].agents[a].pending.lastIndex(where: { $0.tool == tool }) {
            sessions[s].agents[a].pending.remove(at: same)
        }
    }

    private mutating func endTurn(_ s: Int, now: Date, counted: Bool, failed: Bool) {
        sessions[s].turnActive = false
        sessions[s].compacting = false
        sessions[s].stoppedAt = now
        sessions[s].agents[0].pending.removeAll()
        sessions[s].agents[0].needsYou = false
        if counted { sessions[s].turns += 1 }
        sessions[s].failed = failed
    }

    private static func activity(of tool: String) -> Activity {
        if reading.contains(tool) { return .reading }
        if searching.contains(tool) { return .searching }
        if editing.contains(tool) { return .editing }
        if spawning.contains(tool) { return .supervising }
        if asking.contains(tool) { return .asking }
        if planning.contains(tool) { return .thinking }
        return .running
    }

    private static func pendingDetail(tool: String, input: [String: JSONValue]) -> String {
        switch tool {
        case "AskUserQuestion":
            let question = Describe.firstLine(input["questions"].items.first["question"].text)
            return question.isEmpty ? String(localized: "Claude has a question", bundle: .module, comment: "A request: Claude asks something") : Describe.clip(question, 80)
        case "ExitPlanMode":
            return String(localized: "Approve the plan", bundle: .module, comment: "A request: Claude waits for its plan to be approved")
        default:
            return Describe.toolDetail(tool: tool, input: input)
        }
    }

    private func parent(of agent: Agent, in session: Session) -> String? {
        guard agent.id != Self.mainAgent else { return nil }
        if let parentID = agent.parentID, parentID != agent.id, session.index(of: parentID) != nil { return parentID }
        return Self.mainAgent
    }

    private func depth(of agent: Agent, in session: Session) -> Int {
        var depth = 0
        var at = parent(of: agent, in: session)
        while let current = at, depth < session.agents.count, let a = session.index(of: current) {
            depth += 1
            at = parent(of: session.agents[a], in: session)
        }
        return depth
    }

    private func doing(_ agent: Agent, in session: Session, now: Date) -> (Activity, String) {
        let working = agent.pending.last { $0.activity != .supervising }
        if agent.needsYou { return (.asking, working?.detail ?? "") }
        if agent.errorUntil > now { return (.error, "") }
        if let working { return (working.activity, working.detail) }
        // Only launch calls are open: it is waiting on helpers it started in the foreground.
        if let launch = agent.pending.last { return (.supervising, launch.detail) }
        if agent.id != Self.mainAgent { return (.thinking, "") }
        // Compacting: it is squaring away what it remembers of the conversation so far.
        if session.compacting { return (.tidying, "") }
        if session.turnActive { return (.thinking, "") }
        // Its turn is over but helpers it left running in the background are still at it.
        if session.agents.count > 1 { return (.supervising, "") }
        return (now.timeIntervalSince(session.stoppedAt) > Self.napAfter ? .napping : .awake, "")
    }

    private func status(of session: Session) -> AgentStatus {
        if session.agents.contains(where: { $0.activity == .asking }) || session.failed { return .blocked }
        switch session.agents[0].activity {
        case .awake, .napping:
            return session.turns > session.seenTurns ? .done : .idle
        // The error's flash on a turn that has ended is its last look, not more work: once the error is
        // seen the Claude is idle at once, not "working" until the flash is over.
        case .error where !session.turnActive:
            return session.turns > session.seenTurns ? .done : .idle
        default:
            return .working
        }
    }

    private mutating func refresh(now: Date) {
        for s in sessions.indices {
            for a in sessions[s].agents.indices {
                let (activity, detail) = doing(sessions[s].agents[a], in: sessions[s], now: now)
                sessions[s].agents[a].detail = detail
                if activity != sessions[s].agents[a].activity {
                    sessions[s].agents[a].activity = activity
                    sessions[s].agents[a].since = now
                }
            }
            let status = status(of: sessions[s])
            if status != sessions[s].status {
                sessions[s].status = status
                sessions[s].statusSince = now
            }
        }
        journals.sync(snapshots, now: now)
    }

    /// What an asking agent waits for. An open AskUserQuestion or ExitPlanMode is a question whatever the
    /// hook that said it is waiting (Claude Code may also announce it as a permission prompt).
    private func request(of agent: Agent) -> RequestKind? {
        guard agent.activity == .asking else { return nil }
        if agent.pending.contains(where: { Self.asking.contains($0.tool) }) { return .question }
        return agent.needsYou ? agent.askKind ?? .permission : .question
    }

    private func snapshot(_ session: Session) -> SessionSnapshot {
        let agents = session.agents.map { agent -> AgentSnapshot in
            let detail = agent.detail
            let isMain = agent.id == Self.mainAgent
            let status: AgentStatus = isMain ? session.status : (agent.activity == .asking ? .blocked : .working)
            return AgentSnapshot(
                id: agent.id, kind: agent.kind, title: agent.title,
                parentID: parent(of: agent, in: session), depth: depth(of: agent, in: session),
                activity: agent.activity, detail: detail, status: status,
                line: Self.line(activity: agent.activity, detail: detail, ask: agent.ask, status: status, failed: isMain && session.failed, helpers: session.agents.count - 1),
                since: agent.since, request: request(of: agent))
        }
        return SessionSnapshot(
            id: session.id, account: session.account, paneID: session.paneID, cwd: session.cwd,
            project: Self.project(of: session.cwd), title: session.title, ended: session.ended,
            status: session.ended ? .idle : session.status, statusSince: session.statusSince,
            failed: session.failed, agents: agents)
    }

    /// One plain line saying what an agent is doing, for the sidebar.
    static func line(activity: Activity, detail: String, ask: String, status: AgentStatus, failed: Bool, helpers: Int) -> String {
        func with(_ label: String) -> String { detail.isEmpty ? label : "\(label) · \(detail)" }
        if failed { return String(localized: "Stopped on an error", bundle: .module, comment: "What Claude is doing: its turn stopped on an error") }
        switch activity {
        case .asking:
            let what = ask.isEmpty ? (detail.isEmpty ? String(localized: "Waiting for you", bundle: .module, comment: "What Claude is doing: it asks you something") : detail) : ask
            return ask.isEmpty || detail.isEmpty || detail == ask ? what : "\(what) · \(detail)"
        case .reading: return with(String(localized: "Reading", bundle: .module, comment: "What Claude is doing, before the file's name"))
        case .editing: return with(String(localized: "Editing", bundle: .module, comment: "What Claude is doing, before the file's name"))
        case .running: return with(String(localized: "Running", bundle: .module, comment: "What Claude is doing, before the command"))
        case .searching: return with(String(localized: "Searching the web", bundle: .module, comment: "What Claude is doing"))
        case .thinking: return String(localized: "Thinking", bundle: .module, comment: "What Claude is doing")
        case .tidying: return String(localized: "Compacting the conversation", bundle: .module, comment: "What Claude is doing: summarising its conversation to make room")
        case .supervising:
            if !detail.isEmpty { return String(localized: "Waiting on a helper · \(detail)", bundle: .module, comment: "What Claude is doing: waiting for a helper, then what the helper does") }
            return helpers == 1 ? String(localized: "Waiting on a helper", bundle: .module, comment: "What Claude is doing") : String(localized: "Waiting on \(helpers) helpers", bundle: .module, comment: "What Claude is doing: waiting for several helpers")
        case .error: return String(localized: "A step failed", bundle: .module, comment: "What Claude is doing: one of its steps failed")
        case .awake, .napping: return status == .done ? String(localized: "Finished", bundle: .module, comment: "What Claude is doing: its turn ended") : String(localized: "Ready for you", bundle: .module, comment: "What Claude is doing: idle, waiting for a prompt")
        }
    }

    /// The folder a session runs in. A hidden folder such as ".work" says nothing on its own, so its parent is shown too.
    static func project(of cwd: String) -> String {
        let parts = cwd.split(separator: "/").map(String.init)
        guard let folder = parts.last else { return "session" }
        if folder.hasPrefix("."), parts.count > 1 { return "\(parts[parts.count - 2])/\(folder)" }
        return folder
    }
}

public extension Array where Element == AgentSnapshot {
    /// The agents in sidebar order: main first, each helper directly under whoever launched it.
    var familyOrder: [AgentSnapshot] {
        var result: [AgentSnapshot] = []
        func visit(_ parentID: String?) {
            for agent in self where agent.parentID == parentID {
                result.append(agent)
                visit(agent.id)
            }
        }
        visit(nil)
        return result
    }
}

public extension Array where Element == SessionSnapshot {
    /// Sessions in herdr's priority order: blocked, done, working, idle; ties by time in that state, longest first.
    var byUrgency: [SessionSnapshot] {
        sorted { ($0.status, $0.statusSince, $0.id) < ($1.status, $1.statusSince, $1.id) }
    }
}

// MARK: Keeping across a relaunch

/// The sessions of panes that are still open, kept when the app quits, so that after a relaunch (their
/// terminals ran on in the session host) each cat comes back as it was: working or idle, a turn finished
/// and not yet seen, its helpers, its to-dos. What happened meanwhile is told by the terminal itself
/// (`reconcile`): hooks have nobody to report to while the app is away.
public extension AgentWorld {
    private struct Saved: Codable {
        var version = 1
        var sessions: [Session]
        var tasks: [String: [TaskItem]]
    }

    /// The sessions reported from these panes that have not ended, as data; nil when there are none.
    func saved(keepingPanes panes: Set<String>) -> Data? {
        let kept = sessions.filter { session in !session.ended && session.paneID.map(panes.contains) == true }
        guard !kept.isEmpty else { return nil }
        let tasks = Dictionary(kept.compactMap { session in journals[session.id].map { (session.id, $0.taskItems) } }, uniquingKeysWith: { first, _ in first })
        return try? JSONEncoder().encode(Saved(sessions: kept, tasks: tasks.filter { !$0.value.isEmpty }))
    }

    /// Brings back what `saved` kept, for the panes that are still there with Claude in them; anything
    /// else (a pane gone, a terminal that ended while the app was away, a session gone stale) is dropped.
    mutating func restore(_ data: Data, keepingPanes panes: Set<String>, now: Date) {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1 else { return }
        for session in saved.sessions {
            guard let pane = session.paneID, panes.contains(pane), !session.ended, now.timeIntervalSince(session.lastSeen) < Self.staleSession,
                  !sessions.contains(where: { $0.id == session.id }) else { continue }
            sessions.append(session)
            journals.restore(sessionID: session.id, cwd: session.cwd, transcriptPath: session.transcriptPath, tasks: saved.tasks[session.id] ?? [], now: now)
        }
        refresh(now: now)
    }

    /// What the program in a pane's terminal last said of itself (OSC 7501, which the session host read
    /// while the app was away): a turn that ended meanwhile shows as finished and not yet seen, one that
    /// began as working, a question as a request.
    mutating func reconcile(paneID: String, report: ProgramReport?, now: Date) {
        guard let report, let s = sessions.lastIndex(where: { $0.paneID == paneID && !$0.ended }) else { return }
        switch report.state {
        case .working:
            sessions[s].turnActive = true
            sessions[s].agents[0].needsYou = false
        case .blocked:
            sessions[s].turnActive = true
            sessions[s].agents[0].needsYou = true
        case .idle, .done:
            if sessions[s].turnActive || sessions[s].agents[0].needsYou { endTurn(s, now: now, counted: true, failed: false) }
        case .error:
            if sessions[s].turnActive { endTurn(s, now: now, counted: true, failed: true) }
        }
        refresh(now: now)
    }
}
