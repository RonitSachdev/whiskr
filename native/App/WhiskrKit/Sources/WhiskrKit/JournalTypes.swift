import Foundation

// What a session's detail is made of: the conversation, the to-do list, the timeline, what waits on
// you, every agent it has had, and facts about it. The same shapes as the web prototype's
// `shared/protocol.ts`, as values with stable ids so a view can keep each row and update it in place.

/// Who said a message in the conversation.
///   prompt: what was submitted to Claude: typed by you, or pasted.
///   notice: Claude Code's own automatic notes, which it submits the way a prompt is submitted (a
///           background helper finishing, a reminder): nobody typed them, so they are not shown as yours.
///           In a helper's conversation they arrive as messages from its boss.
///   reply:  text Claude or a helper showed. One turn can hold several, written between its tool calls.
///   report: a helper's final message, handed back to whoever launched it.
///   error:  the turn ended on an API error such as a rate limit; the text is what Claude Code showed.
///   task:   what a helper was asked to do by whoever launched it, from its transcript file.
public enum ChatKind: String, Sendable, CaseIterable {
    case prompt, notice, reply, report, error, task
}

/// One message. A helper's words arrive late (its transcript is read every few seconds) and the list
/// only grows at the end, so a view shows messages in order of `at`, not in the order they arrived.
public struct ChatEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let at: Date               // when it began
    public var kind: ChatKind
    public let agentID: String        // AgentWorld.mainAgent, or the helper whose task, reply or report it is
    public var text: String
    public var streaming: Bool        // more of this reply is still arriving as `.chatAppend` changes
    public var clipped: Bool          // it grew past what is kept and was cut; nothing more is appended
}

public enum TaskState: String, Sendable, CaseIterable, Codable {
    case pending, inProgress = "in_progress", completed
}

/// One item of the to-do list Claude keeps with its task tools (or, in older setups, TodoWrite).
public struct TaskItem: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var subject: String        // e.g. "Fix the cart total"
    public var activeForm: String     // the same while being done, e.g. "Fixing the cart total"; "" when not given
    public var description: String
    public var state: TaskState
    public var owner: String          // the teammate it is assigned to, in agent teams; "" otherwise
}

/// The to-do list's count, for the overview.
public struct TaskProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

///   prompt:       a prompt (or an automatic notice) was submitted; the chat has its text
///   command:      a slash command or MCP prompt was expanded before reaching Claude
///   tool:         a tool call; `running` until it reports back
///   helper:       a helper started (on its own lane) and later finished, or a teammate went idle
///   permission:   Claude Code asked you to allow a tool; `running` until it is settled
///   question:     an MCP server asked you something (Claude's own questions are tool events)
///   notification: Claude Code raised a notification, e.g. "Claude is waiting for your input"
///   compact:      the conversation was compacted; the summary is in `output`
///   model:        the session's model changed
///   setting:      instructions loaded, settings changed, the working folder moved or a folder was added
///   turn:         Claude finished responding to a prompt
///   error:        the turn stopped on an API error
///   session:      the session ended
public enum TimelineKind: String, Sendable, CaseIterable {
    case prompt, command, tool, helper, permission, question, notification, compact, model, setting, turn, error, session
}

///   running: still going.  ok: finished well.  failed: finished with an error.
///   denied:  never ran: refused by you, by auto mode, or by another hook.
///   info:    a moment, not something with a duration.
public enum EventState: String, Sendable, CaseIterable {
    case running, ok, failed, denied, info
}

public struct TimelineEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let at: Date               // when it began
    public let agentID: String        // whose lane it belongs on
    public let kind: TimelineKind
    public let tool: String           // the tool's name for tool and permission events; "" otherwise
    public let title: String          // one short plain line, e.g. "Ran npm test"
    public let detail: String         // the thing itself: a full command, a file path, a URL; "" when nothing to add
    public var output: String         // the start of what came back: output, an error, a report, a summary
    public var state: EventState
    public var duration: TimeInterval? // how long it took, once finished
}

///   permission: a tool needs your approval.   question: Claude is asking you to pick from options.
///   plan:       Claude wants its plan approved before it starts.   form: an MCP server asks for input.
public enum AskKind: String, Sendable, CaseIterable {
    case permission, question, plan, form
}

/// Something waiting on you. It goes away when Claude Code moves on.
public struct Ask: Sendable, Equatable, Identifiable {
    public let id: String
    public let at: Date
    public let kind: AskKind
    public let agentID: String        // who is asking
    public let tool: String           // the tool's name, or the MCP server's for a form
    public let summary: String        // one plain line, e.g. "Run a command" or the question itself
    public let description: String    // Claude's own words about why, when it gave any
    public let target: String         // the command, file path, URL, or the plan's start
    public let options: [String]      // a question's choices, the "always allow" rules offered, or a form's fields
    public let input: String          // the whole request as JSON, cut short when long, for a "show everything" view
    /// How many questions a question ask holds (its options are the first one's); 0 for other kinds.
    public let questionCount: Int
    /// Whether the (first) question lets you pick several options.
    public let multiSelect: Bool
}

/// Every agent the session has had, including helpers that already finished, so the chat and the
/// timeline can still name them after they have left the overview.
public struct AgentRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: String
    public var title: String
    public var parentID: String?
    public let startedAt: Date
    public var endedAt: Date?
}

public struct SessionFacts: Sendable, Equatable {
    public var model = ""             // "" until known: from a model switch, or read from the transcript
    public var effort = ""            // effort level, e.g. "high"; "" when the model has none
    public var permissionMode = ""    // e.g. "default", "plan", "acceptEdits", "auto"
    public var firstSeenAt: Date      // when the app first heard from it (it may have started earlier)
    public var endedAt: Date?
    public var endReason = ""         // why it ended, e.g. "prompt_input_exit", "clear"; "" while running
    public var cwd: String            // the working folder now; follows `cd`
    public var directories: [String] = [] // folders added during the session with /add-dir
    public var instructions: [String] = [] // CLAUDE.md and rule files loaded into its context
    public var background: [String] = []  // work still running in the background at the end of the last turn
    public var scheduled: [String] = []   // wake-ups the session has scheduled, e.g. "0 9 * * 1-5 · check the build"
    public var prompts = 0            // prompts submitted so far (automatic notices are not counted)
    public var compactions = 0

    public init(firstSeenAt: Date, cwd: String) {
        self.firstSeenAt = firstSeenAt
        self.cwd = cwd
    }
}

public struct SessionDetail: Sendable, Equatable, Identifiable {
    public let id: String
    public var facts: SessionFacts
    public var agents: [AgentRecord]   // launch order
    public var chat: [ChatEntry]       // oldest first
    public var tasks: [TaskItem]       // in the order they were created
    public var timeline: [TimelineEvent] // oldest first
    public var asks: [Ask]             // oldest first
}

/// The lists a `.drop` change can let entries go from.
public enum DetailList: String, Sendable {
    case chat, timeline, agents
}

/// How a session's detail changed. Applied in order with `SessionDetail.apply`, they turn the detail
/// taken earlier into the current one, so a view updates only the rows that changed.
public enum DetailChange: Sendable, Equatable {
    case facts(SessionFacts)
    case agent(AgentRecord)                                   // add, or replace the one with this id
    case chat(ChatEntry)                                      // add at the end, or replace the one with this id
    case chatAppend(id: String, text: String, streaming: Bool) // more text for a streaming reply
    case tasks([TaskItem])                                    // the whole list, which is short
    case event(TimelineEvent)                                 // add at the end, or replace the one with this id
    case asks([Ask])                                          // everything waiting on you now
    case drop(DetailList, ids: [String])                      // old entries let go to stay within the limits
}

public extension SessionDetail {
    mutating func apply(_ change: DetailChange) {
        switch change {
        case .facts(let value):
            facts = value
        case .agent(let agent):
            if let at = agents.firstIndex(where: { $0.id == agent.id }) { agents[at] = agent } else { agents.append(agent) }
        case .chat(let entry):
            if let at = chat.firstIndex(where: { $0.id == entry.id }) { chat[at] = entry } else { chat.append(entry) }
        case .chatAppend(let id, let text, let streaming):
            guard let at = chat.firstIndex(where: { $0.id == id }) else { return }
            chat[at].text += text
            chat[at].streaming = streaming
        case .tasks(let value):
            tasks = value
        case .event(let event):
            if let at = timeline.firstIndex(where: { $0.id == event.id }) { timeline[at] = event } else { timeline.append(event) }
        case .asks(let value):
            asks = value
        case .drop(let list, let ids):
            let gone = Set(ids)
            switch list {
            case .chat: chat.removeAll { gone.contains($0.id) }
            case .timeline: timeline.removeAll { gone.contains($0.id) }
            case .agents: agents.removeAll { gone.contains($0.id) }
            }
        }
    }
}
