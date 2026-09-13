import Foundation

/// Every session's journal and helper-transcript follower, kept by `AgentWorld` beside its sessions and
/// fed from the same hook events, so the overview and the detail can never disagree about who exists.
struct Journals: Sendable {
    private var journals: [String: Journal] = [:]
    private var followers: [String: HelperTranscriptFollower] = [:]
    /// Sessions someone is looking at. Only their changes are kept and only their helpers are read.
    private var watched: Set<String> = []

    subscript(sessionID: String) -> Journal? { journals[sessionID] }

    /// One hook event, before the world itself acts on it (as the web prototype does), so a helper that
    /// stops is still on record when its last words arrive.
    mutating func record(_ payload: JSONValue, sessionID: String, cwd: String, now: Date) {
        let agentID = payload["agent_id"].text.isEmpty ? AgentWorld.mainAgent : payload["agent_id"].text
        journals[sessionID, default: Journal(sessionID: sessionID, cwd: cwd, now: now)]
            .record(event: payload["hook_event_name"].text, payload: payload, agentID: agentID, now: now)
        // A helper reporting in has probably written something since it was last read.
        if agentID != AgentWorld.mainAgent, watched.contains(sessionID) { followers[sessionID, default: HelperTranscriptFollower()].want(agentID) }
    }

    /// After every change to the world: agents' records follow its cast, and forgotten sessions go.
    mutating func sync(_ sessions: [SessionSnapshot], now: Date) {
        let present = Set(sessions.map(\.id))
        journals = journals.filter { present.contains($0.key) }
        followers = followers.filter { present.contains($0.key) }
        for session in sessions {
            journals[session.id]?.syncAgents(session.agents, now: now)
            if !watched.contains(session.id) { journals[session.id]?.discardChanges() }
        }
    }

    /// A session brought back after a relaunch: its journal starts again, with the to-dos it had.
    mutating func restore(sessionID: String, cwd: String, transcriptPath: String, tasks: [TaskItem], now: Date) {
        var journal = Journal(sessionID: sessionID, cwd: cwd, now: now)
        journal.restore(transcriptPath: transcriptPath, tasks: tasks)
        journals[sessionID] = journal
    }

    mutating func noteModel(_ model: String, sessionID: String) {
        journals[sessionID]?.noteModel(model)
    }

    mutating func watch(_ sessionIDs: Set<String>) {
        for id in sessionIDs.subtracting(watched) {
            // Whoever starts watching takes the detail whole; what changed before that is not news.
            journals[id]?.discardChanges()
            if let journal = journals[id] { followers[id, default: HelperTranscriptFollower()].wantAll(journal.agentRecords) }
        }
        watched = sessionIDs
    }

    mutating func takeChanges() -> [String: [DetailChange]] {
        var taken: [String: [DetailChange]] = [:]
        for id in watched {
            guard let changes = journals[id]?.takeChanges(), !changes.isEmpty else { continue }
            taken[id] = changes
        }
        return taken
    }

    mutating func dueHelperReads(now: Date) -> [HelperRead] {
        watched.sorted().flatMap { id -> [HelperRead] in
            guard let journal = journals[id] else { return [] }
            return followers[id, default: HelperTranscriptFollower()].due(sessionID: id, transcriptPath: journal.transcriptPath, agents: journal.agentRecords, now: now)
        }
    }

    mutating func hear(_ result: HelperReadResult, now: Date) {
        let id = result.read.sessionID
        followers[id]?.finish(result)
        if !result.said.isEmpty { journals[id]?.heard(agentID: result.read.agentID, said: result.said, now: now) }
    }
}

/// The detail behind the inspector (Chat, Tasks, Timeline) and the answer bar. The app drives it like
/// this, all on the main thread except the file reads:
///
///     world.watch([sessionID])                       // the session whose detail is on screen
///     let detail = world.detail(sessionID: id)       // once, whole
///     for (id, changes) in world.takeDetailChanges() // after every ingest, tick and hear
///     for read in world.dueHelperReads(now: now) {   // after every ingest and tick
///         let result = HelperTranscript.read(read, files: LocalHelperTranscriptFiles()) // off the main thread
///         world.hear(result, now: Date())            // back on it
///     }
public extension AgentWorld {
    /// Everything known about one session beyond the overview; nil when there is no such session.
    func detail(sessionID: String) -> SessionDetail? {
        journals[sessionID]?.detail
    }

    /// The session's to-do list count, for the overview; nil while it has none.
    func progress(sessionID: String) -> TaskProgress? {
        journals[sessionID]?.progress
    }

    /// Which sessions' detail is on screen. Only their changes are kept, and only their helpers'
    /// transcripts are read: a session newly watched has every helper it has had read at once, so its
    /// chat shows their words from the start. Watching a session that has not reported yet is allowed;
    /// its detail appears when it does.
    mutating func watch(_ sessionIDs: Set<String>) {
        journals.watch(sessionIDs)
    }

    /// What changed in each watched session's detail since the last call, in order, ready for
    /// `SessionDetail.apply`. Sessions with no changes are left out.
    mutating func takeDetailChanges() -> [String: [DetailChange]] {
        journals.takeChanges()
    }

    /// Helper transcripts that are due to be read, each with where its last read stopped.
    mutating func dueHelperReads(now: Date) -> [HelperRead] {
        journals.dueHelperReads(now: now)
    }

    /// A helper-transcript read came back: its words join the chat, and the next read carries on from
    /// where this one stopped.
    mutating func hear(_ result: HelperReadResult, now: Date) {
        journals.hear(result, now: now)
    }
}
