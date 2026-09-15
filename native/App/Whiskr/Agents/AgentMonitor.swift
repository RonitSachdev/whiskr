import Foundation
import Observation
import WhiskrKit

/// Keeps the state model (`AgentWorld`) fed: hook events from the listener, a tick every second for
/// timed changes, and the transcript and meta-file reads it asks for, done off the main thread. For the
/// sessions on screen it also keeps their detail (the journal: chat, steps, to-dos, asks) current, for
/// a helper's story, a pane's to-do mark and the answer bar.
@Observable
final class AgentMonitor {
    /// Every session known, ended ones included until the model forgets them.
    private(set) var sessions: [SessionSnapshot] = []
    /// The detail of each watched session, kept current.
    private(set) var details: [String: SessionDetail] = [:]

    @ObservationIgnored private var world = AgentWorld()
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private(set) var gate: HookGate?
    @ObservationIgnored private var ticker: Timer?
    /// Each session's account folder, read from where its transcript lives.
    @ObservationIgnored private var configDirs: [String: String] = [:]
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var reading: Set<String> = []
    /// Whether the app still has this pane; events from a pane closed since are ignored.
    @ObservationIgnored var hasPane: (String) -> Bool = { _ in false }
    /// An account's name from its config folder (nil: the default account).
    @ObservationIgnored var accountName: (String?) -> String = { _ in ClaudeAccount.defaultName }
    /// Called after every change, with the sessions before and after.
    @ObservationIgnored var onChange: ((_ before: [SessionSnapshot], _ after: [SessionSnapshot]) -> Void)?
    /// Called when a helper the app knew of finishes (SubagentStop), with its pane, session, id and task.
    @ObservationIgnored var onHelperFinished: ((_ paneID: UUID, _ sessionID: String, _ agentID: String, _ title: String) -> Void)?

    /// When a helper's meta file is looked for: at once, then twice more, as it can land a moment late.
    static let metaRetries: [Duration] = [.zero, .milliseconds(250), .seconds(1)]

    func start() async throws {
        let server = HookServer { paneID, payload in
            Task { @MainActor [weak self] in self?.receive(paneID: paneID, payload: payload) }
        }
        self.server = server
        gate = try await server.start()
        let ticker = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func stop() {
        ticker?.invalidate()
        server?.stop()
    }

    /// The latest session reported from a pane that has not ended.
    func session(forPane paneID: UUID) -> SessionSnapshot? {
        let id = paneID.uuidString
        return sessions.last { $0.paneID == id && !$0.ended }
    }

    /// The account folder a session runs under (`…/.claude-work`), from its transcript's path.
    func configDir(sessionID: String) -> String? {
        configDirs[sessionID]
    }

    func markSeen(sessionID: String) {
        update { $0.markSeen(sessionID: sessionID, now: Date()) }
    }

    /// One session's detail now (its open asks, say), whether or not it is on screen.
    func detail(sessionID: String) -> SessionDetail? {
        details[sessionID] ?? world.detail(sessionID: sessionID)
    }

    func markUnread(sessionID: String) {
        update { $0.markUnread(sessionID: sessionID, now: Date()) }
    }

    func programIdle(paneID: UUID) {
        update { $0.programIdle(paneID: paneID.uuidString, now: Date()) }
    }

    /// Claude has left the pane (the shell is back at its prompt) without saying so: the session ends,
    /// as if it had sent SessionEnd.
    func paneLeft(paneID: UUID, sessionID: String) {
        receive(paneID: paneID.uuidString, payload: ["hook_event_name": "SessionEnd", "session_id": .string(sessionID), "reason": "other"])
    }

    // MARK: Across a relaunch

    /// The sessions of these panes as they are now, to bring back after a relaunch; nil when none.
    func saved(keepingPanes panes: Set<String>) -> Data? {
        world.saved(keepingPanes: panes)
    }

    /// Brings back saved sessions for the panes that still have Claude in them.
    func restore(_ data: Data, keepingPanes panes: Set<String>) {
        update { $0.restore(data, keepingPanes: panes, now: Date()) }
    }

    /// What a pane's program reported of itself while the app was away (`AgentWorld.reconcile`).
    func reconcile(paneID: UUID, report: ProgramReport?) {
        update { $0.reconcile(paneID: paneID.uuidString, report: report, now: Date()) }
    }

    // MARK: Detail

    /// The sessions whose detail is on screen (a helper's story, a pane's to-do list, an ask).
    func watch(_ sessionIDs: Set<String>) {
        guard sessionIDs != watched else { return }
        watched = sessionIDs
        world.watch(sessionIDs)
        var next: [String: SessionDetail] = [:]
        for id in sessionIDs { next[id] = details[id] ?? world.detail(sessionID: id) }
        details = next
        takeDetail()
    }

    /// The to-do list's progress, for the mark on a pane's title; nil while it has none.
    func progress(sessionID: String) -> TaskProgress? {
        _ = sessions
        return world.progress(sessionID: sessionID)
    }

    private func takeDetail() {
        let changes = world.takeDetailChanges()
        if !changes.isEmpty {
            var next = details
            for (id, list) in changes {
                guard var detail = next[id] ?? world.detail(sessionID: id) else { continue }
                for change in list { detail.apply(change) }
                next[id] = detail
            }
            details = next
        }
        for id in watched where details[id] == nil {
            if let detail = world.detail(sessionID: id) { details[id] = detail }
        }
        readHelpers()
    }

    /// Helpers' own words are in their transcripts, not in hooks: read what is due, off the main thread.
    private func readHelpers() {
        for read in world.dueHelperReads(now: Date()) {
            let key = "\(read.sessionID)/\(read.agentID)"
            guard !reading.contains(key) else { continue }
            reading.insert(key)
            Task {
                let result = await Task.detached(priority: .utility) { HelperTranscript.read(read, files: LocalHelperTranscriptFiles()) }.value
                reading.remove(key)
                world.hear(result, now: Date())
                takeDetail()
            }
        }
    }

    #if DEBUG
    /// Debug builds: a hook event as if Claude Code had posted it from a pane (the demo workbench).
    func simulate(paneID: UUID, payload: JSONValue) {
        receive(paneID: paneID.uuidString, payload: payload)
    }
    #endif

    private func receive(paneID: String, payload: JSONValue) {
        guard hasPane(paneID) else { return }
        let sessionID = payload["session_id"].text
        if !sessionID.isEmpty, let dir = Self.configDir(transcriptPath: payload["transcript_path"].text) { configDirs[sessionID] = dir }
        let account = accountName(configDirs[sessionID])
        // A helper's SubagentStop: who it was is known only until the model lets it go.
        let finishedHelper = payload["hook_event_name"].text == "SubagentStop"
            ? sessions.first { $0.id == sessionID }?.agents.first { $0.id == payload["agent_id"].text && $0.depth > 0 } : nil
        var effects: [WorldEffect] = []
        update { effects = $0.ingest(payload, account: account, paneID: paneID, now: Date()) }
        for effect in effects { perform(effect) }
        if let finishedHelper, let pane = UUID(uuidString: paneID) { onHelperFinished?(pane, sessionID, finishedHelper.id, finishedHelper.title) }
    }

    /// `<config folder>/projects/<project>/<session>.jsonl` → the config folder.
    static func configDir(transcriptPath: String) -> String? {
        guard let range = transcriptPath.range(of: "/projects/", options: .backwards) else { return nil }
        let dir = String(transcriptPath[..<range.lowerBound])
        return dir.isEmpty ? nil : dir
    }

    private func tick() {
        var effects: [WorldEffect] = []
        update {
            $0.tick(now: Date())
            effects = $0.dueReads(now: Date())
        }
        for effect in effects { perform(effect) }
    }

    private func update(_ change: (inout AgentWorld) -> Void) {
        change(&world)
        let after = world.snapshots
        if !watched.isEmpty { takeDetail() }
        guard after != sessions else { return }
        let before = sessions
        sessions = after
        configDirs = configDirs.filter { id, _ in after.contains { $0.id == id } }
        onChange?(before, after)
    }

    private func perform(_ effect: WorldEffect) {
        switch effect {
        case .readTranscript(let sessionID, let path):
            Task {
                let facts = await Task.detached(priority: .utility) { Transcripts.facts(transcriptPath: path) }.value
                update { $0.apply(transcript: facts, sessionID: sessionID, now: Date()) }
            }
        case .readMeta(let sessionID, let agentID, let path):
            Task {
                for delay in Self.metaRetries {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    let meta = await Task.detached(priority: .utility) { Transcripts.spawnMeta(transcriptPath: path, agentID: agentID) }.value
                    var wantsMore = false
                    update { wantsMore = $0.apply(meta: meta, sessionID: sessionID, agentID: agentID, now: Date()) }
                    if !wantsMore { return }
                }
            }
        }
    }
}
