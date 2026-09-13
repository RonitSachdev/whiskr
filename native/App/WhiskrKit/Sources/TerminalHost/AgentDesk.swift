import Foundation
import WhiskrKit

/// The host's side of agents starting and steering agents (`paw`): a terminal started from another
/// gets its command typed once its shell's prompt is up and its first task once the program is ready;
/// messages are pasted only when the receiver can take them (never into an answer it is waiting for,
/// never into a person's half-typed draft, never with a tag into a plain shell); a parent hears when a
/// helper of its needs an answer, stops on an error or ends; waits end when what they wait for happens.
///
/// It has no clock of its own: the host calls `tick` ten times a second while any of this is pending,
/// and `changed` whenever a terminal's report, output or life changes. Used only on the host's queue.
final class AgentDesk: @unchecked Sendable {
    /// How long a shell may take to show its prompt before the command is typed anyway.
    static let promptLatest: TimeInterval = 4
    /// Quiet output that counts as a shell's prompt being up (when it does not say so).
    static let promptQuiet: TimeInterval = 0.4
    /// Quiet output that counts as a program being ready, for one that reports nothing.
    static let readyQuiet: TimeInterval = 1.5
    /// Between a paste and its Return: a program reading a paste may take the Return as part of it.
    static let submitGap: TimeInterval = 0.3
    /// How long a person's unsent typing holds a message back, at most.
    static let draftWait: TimeInterval = 60

    private let terminal: (UUID) -> HostedTerminal?
    private let allTerminals: () -> [HostedTerminal]
    /// Tells subscribers (the app) that text passed from one terminal into another.
    private let passed: (PassedMessage) -> Void
    private var startups: [UUID: Startup] = [:]
    private var queues: [UUID: [Delivery]] = [:]
    /// The terminal a paste is being typed into, until its Return has gone.
    private var typing: Set<UUID> = []
    private var waits: [Wait] = []

    init(terminal: @escaping (UUID) -> HostedTerminal?, allTerminals: @escaping () -> [HostedTerminal], passed: @escaping (PassedMessage) -> Void) {
        self.terminal = terminal
        self.allTerminals = allTerminals
        self.passed = passed
    }

    /// Anything waiting on the clock.
    var isBusy: Bool { !startups.isEmpty || !queues.isEmpty || !waits.isEmpty || programs.values.contains(.running) }

    // MARK: Starting a helper

    private struct Startup {
        enum Phase { case shell, program, delivered, blocked, failed }
        var phase = Phase.shell
        let line: String?
        let task: String?
        let delivery: AgentText.Delivery
        let parent: UUID?
        let began = Date()
        /// When the command was typed, and whether a program has been seen in front since.
        var typedAt: Date?
        var programSeen = false
        var reason = ""
    }

    /// A terminal `run` started. `endsWithProgram`: one without a tab of its own (`--bg`) ends when its
    /// program does, so its parent hears how it ended; one with a tab keeps its shell, as a tab does.
    func started(_ id: UUID, command: String?, task: String?, parent: UUID?, endsWithProgram: Bool) {
        let task = task.flatMap { $0.isEmpty ? nil : $0 }
        let line = command.map { AgentText.typedLine(command: $0, task: task) + (endsWithProgram ? "; exit" : "") }
        startups[id] = Startup(line: line, task: task, delivery: command.map(AgentText.delivery(for:)) ?? .paste, parent: parent)
        if command != nil && !endsWithProgram { programs[id] = .notYet }
        advance(id)
    }

    /// The program a terminal was started to run: not in front yet, running, or ended (its shell may stay).
    private enum Program { case notYet, running, ended }
    private var programs: [UUID: Program] = [:]

    /// It has ended: the terminal itself, or (for one with a tab, whose shell stays) the program it was
    /// started to run.
    private func hasEnded(_ terminal: HostedTerminal) -> Bool {
        if terminal.exited { return true }
        guard terminal.origin?.background == false, let program = programs[terminal.id] else { return false }
        switch program {
        case .ended: return true
        case .notYet, .running:
            if terminal.programInFront {
                programs[terminal.id] = .running
                return false
            }
            if program == .running { programs[terminal.id] = .ended }
            return program == .running
        }
    }

    /// Where a helper's start has got to, for `wait --started`.
    private func startPhase(_ id: UUID) -> Startup.Phase? { startups[id]?.phase }

    private func advance(_ id: UUID) {
        guard var startup = startups[id] else { return }
        guard let terminal = terminal(id), !terminal.exited else {
            // A command with no task that has run and ended (a helper without a tab ends with it).
            let ran = startup.task == nil && startup.typedAt != nil
            startup.phase = ran ? .delivered : .failed
            startup.reason = "it ended before it started"
            return finish(id, startup)
        }
        let now = Date()
        switch startup.phase {
        case .shell:
            let quiet = terminal.lastOutput.map { now.timeIntervalSince($0) >= Self.promptQuiet } ?? false
            guard terminal.sawPrompt || quiet || now.timeIntervalSince(startup.began) >= Self.promptLatest else { break }
            guard let line = startup.line else {
                startup.phase = startup.task == nil ? .delivered : .program
                if startup.task != nil { startup.typedAt = now }
                break
            }
            terminal.typeForAgent(Data((line + "\r").utf8))
            startup.typedAt = now
            startup.phase = .program
        case .program:
            if terminal.programInFront {
                startup.programSeen = true
                if programs[id] == .notYet, terminal.origin?.background == false { programs[id] = .running }
            }
            if startup.programSeen && !terminal.programInFront && startup.line != nil {
                // With no task to hand over, a command already done has simply run.
                startup.phase = startup.task == nil ? .delivered : .failed
                startup.reason = "the program ended at once"
                break
            }
            guard let task = startup.task else {
                // Nothing to hand over: started once the program is in front (or a moment has passed).
                if startup.programSeen || now.timeIntervalSince(startup.typedAt ?? now) > 3 { startup.phase = .delivered }
                break
            }
            let report = terminal.report
            if report?.state == .blocked {
                startup.phase = .blocked
                break
            }
            switch startup.delivery {
            case .argument:
                // Claude has the task already; it is under way once Claude says it works on it, or (for
                // one that reports nothing) once it has been quiet in front for a while.
                let quiet = terminal.lastOutput.map { now.timeIntervalSince($0) >= Self.readyQuiet * 2 } ?? false
                if report?.isBusy == true || (report == nil && startup.programSeen && quiet) { startup.phase = .delivered }
            case .paste:
                let quiet = terminal.lastOutput.map { now.timeIntervalSince($0) >= Self.readyQuiet } ?? false
                let ready = report.map { $0.state == .idle || $0.state == .done } ?? (startup.programSeen && quiet)
                guard ready else { break }
                enqueue(Delivery(text: task, kind: .task, sender: startup.parent, needsAgent: false, whenBlocked: .wait, submit: true) { _ in }, to: id)
                startup.phase = .delivered
            }
        case .blocked:
            // An answer was given: the task goes on as it would have (pasted once it is ready).
            if terminal.report?.state != .blocked { startup.phase = .program }
        case .delivered, .failed:
            break
        }
        startups[id] = startup
        if startup.phase == .delivered { finish(id, startup) }
        if startup.phase == .failed { finish(id, startup) }
    }

    private func finish(_ id: UUID, _ startup: Startup) {
        startups[id] = startup.phase == .blocked ? startup : nil
        if startup.phase == .delivered, startup.task != nil, startup.delivery == .argument {
            passed(PassedMessage(from: startup.parent, to: id, kind: .task))
        }
        evaluateWaits()
    }

    // MARK: Messages

    private struct Delivery: Sendable {
        let text: String
        let kind: PassedMessage.Kind
        let sender: UUID?
        /// Typed only while the receiver is an agent (a tagged message, a note): a shell would run it.
        let needsAgent: Bool
        /// While the receiver waits for an answer: a note or a task waits for it to be given; a
        /// message is refused then (unless forced, when it goes in anyway).
        let whenBlocked: WhenBlocked
        let submit: Bool
        var queuedAt = Date()
        let done: @Sendable (HostReply) -> Void

        enum WhenBlocked { case wait, refuse, type }
    }

    /// A message to type into a terminal (`paw send`). Refused at once when the receiver has ended, or
    /// waits for an answer and `force` is off; else answered once it has been typed.
    func send(_ request: SendRequest, done: @escaping @Sendable (HostReply) -> Void) {
        guard let target = terminal(request.terminal) else { return done(.failed(HostFailure(.noSuchTerminal))) }
        guard !target.exited else { return done(.failed(HostFailure(.exited, "\(target.label) has ended"))) }
        if target.report?.state == .blocked && !request.force { return done(.failed(blocked(target))) }
        // An agent reads a message as a message from someone; a shell would run it, so it is never tagged.
        let tagged = !request.raw && target.isAgentNow
        let sender = request.sender.flatMap { terminal($0) }
        let text = tagged ? AgentText.tagged(request.text, from: sender?.label) : request.text
        enqueue(Delivery(text: text, kind: .message, sender: request.sender, needsAgent: tagged, whenBlocked: request.force ? .type : .refuse,
                         submit: request.submit, done: done), to: request.terminal)
    }

    private func blocked(_ target: HostedTerminal) -> HostFailure {
        HostFailure(.blocked, "\(target.label) is waiting for an answer\(target.report?.kind.map { " (\($0))" } ?? "")")
    }

    private func enqueue(_ delivery: Delivery, to id: UUID) {
        queues[id, default: []].append(delivery)
        deliver(id)
    }

    /// Types the next message into `id` if it can take it now.
    private func deliver(_ id: UUID) {
        guard !typing.contains(id), var queue = queues[id], let next = queue.first else { return }
        guard let target = terminal(id), !target.exited else {
            queues[id] = nil
            for delivery in queue { delivery.done(.failed(HostFailure(.exited, "it has ended"))) }
            return
        }
        let now = Date()
        if target.report?.state == .blocked {
            switch next.whenBlocked {
            case .wait: return
            case .refuse:
                queue.removeFirst()
                queues[id] = queue.isEmpty ? nil : queue
                next.done(.failed(blocked(target)))
                return deliver(id)
            case .type: break
            }
        }
        // Never into what a person is typing, for a while.
        if target.draftOpen, let typed = target.lastTyped, now.timeIntervalSince(typed) < Self.draftWait,
           now.timeIntervalSince(next.queuedAt) < Self.draftWait { return }
        queue.removeFirst()
        queues[id] = queue.isEmpty ? nil : queue
        if next.needsAgent && !target.isAgentNow {
            next.done(.failed(HostFailure(.invalid, "\(target.label) is at its shell prompt now; nothing was typed")))
            return deliver(id)
        }
        target.paste(next.text)
        typing.insert(id)
        afterGap(next.submit ? Self.submitGap : 0) { [weak self] in
            guard let self else { return }
            if next.submit, let target = self.terminal(id), !target.exited { target.typeForAgent(Data("\r".utf8)) }
            self.typing.remove(id)
            next.done(.done)
            self.passed(PassedMessage(from: next.sender, to: id, kind: next.kind))
            self.deliver(id)
        }
    }

    /// Runs `work` on the host's queue after `seconds`; set by the host.
    var afterGap: (TimeInterval, @escaping @Sendable () -> Void) -> Void = { _, work in work() }

    // MARK: Notes to a parent

    /// What a helper's parent last heard about it, so each change is told once.
    private var told: [UUID: String] = [:]

    /// A terminal's report or life changed: its parent may want to know.
    private func noteParent(of child: HostedTerminal) {
        guard let origin = child.origin, origin.notifiesParent, let parentID = origin.parent,
              let parent = terminal(parentID), !parent.exited else { return }
        let note: AgentText.Note?
        if hasEnded(child) {
            note = .exited(code: child.info.exitCode)
        } else if child.report?.state == .blocked {
            note = .blocked(kind: child.report?.kind)
        } else if child.report?.state == .error {
            note = .error
        } else {
            note = nil
        }
        guard let note else {
            told[child.id] = nil
            return
        }
        guard told[child.id] != note.word else { return }
        told[child.id] = note.word
        // Only an agent reads notes; a shell would run them.
        guard parent.report != nil else { return }
        let text = AgentText.tagged(note.text(label: child.label, address: child.address), from: child.label, note: note.word)
        enqueue(Delivery(text: text, kind: .note, sender: child.id, needsAgent: true, whenBlocked: .wait, submit: true) { _ in }, to: parentID)
    }

    // MARK: Waits

    private final class Wait {
        let id = UUID()
        let request: WaitRequest
        let link: ObjectIdentifier
        let began = Date()
        /// The report when it began, to tell a change from what already was.
        let turnsBefore: Int
        let reply: (HostReply) -> Void
        init(request: WaitRequest, link: ObjectIdentifier, turnsBefore: Int, reply: @escaping (HostReply) -> Void) {
            self.request = request
            self.link = link
            self.turnsBefore = turnsBefore
            self.reply = reply
        }
    }

    func wait(_ request: WaitRequest, link: ObjectIdentifier, reply: @escaping (HostReply) -> Void) {
        guard let target = terminal(request.terminal) else { return reply(.failed(HostFailure(.noSuchTerminal))) }
        if case .output = request.until { target.watchText() }
        let wait = Wait(request: request, link: link, turnsBefore: target.report?.turns ?? 0, reply: reply)
        waits.append(wait)
        evaluate(wait)
    }

    /// The client that waited has gone.
    func dropWaits(of link: ObjectIdentifier) {
        waits.removeAll { $0.link == link }
        stopWatchingTextNoOneNeeds()
    }

    private func evaluateWaits() {
        for wait in waits { evaluate(wait) }
    }

    private func children(of id: UUID) -> [HostedTerminal] {
        allTerminals().filter { $0.origin?.parent == id }.sorted { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
    }

    private func evaluate(_ wait: Wait) {
        guard waits.contains(where: { $0 === wait }) else { return }
        guard let target = terminal(wait.request.terminal) else {
            return end(wait, WaitResult(outcome: .exited, terminal: TerminalInfo(id: wait.request.terminal, pid: 0, size: TerminalSize(columns: 0, rows: 0), exited: true)))
        }
        let info = target.info
        var outcome: WaitResult.Outcome?
        var kids: [TerminalInfo] = []
        switch wait.request.until {
        case .settled:
            switch info.activity {
            case .exited: outcome = .exited
            case .blocked: outcome = .blocked
            case .working: break
            case .idle, .done, .error: outcome = .met
            }
        case .exited:
            if hasEnded(target) { outcome = .met }
        case .output(let needle):
            if target.printed(needle) { outcome = .met } else if info.exited { outcome = .exited }
        case .children(let all):
            kids = children(of: target.id).map(\.info)
            let settled = kids.filter { $0.activity.isSettled }
            if kids.isEmpty || (all ? settled.count == kids.count : !settled.isEmpty) {
                outcome = settled.contains { $0.activity == .blocked } ? .blocked : .met
            }
        case .activity:
            if info.exited {
                outcome = .exited
            } else if let report = info.status.program {
                if report.isBusy || report.turns > wait.turnsBefore { outcome = report.state == .blocked ? .blocked : .met }
            } else if info.status.foreground != nil {
                outcome = .met
            }
        case .started:
            switch startPhase(target.id) {
            case nil, .delivered: outcome = .met
            case .blocked: outcome = .blocked
            case .failed: outcome = .exited
            case .shell, .program: if info.exited { outcome = .exited }
            }
        }
        if outcome == nil, Date().timeIntervalSince(wait.began) >= wait.request.timeout { outcome = .timedOut }
        guard let outcome else { return }
        if outcome == .exited || info.exited { target.noteExitSeen() }
        end(wait, WaitResult(outcome: outcome, terminal: info, children: kids))
    }

    private func end(_ wait: Wait, _ result: WaitResult) {
        waits.removeAll { $0 === wait }
        wait.reply(.waited(result))
        stopWatchingTextNoOneNeeds()
    }

    private func stopWatchingTextNoOneNeeds() {
        let watched = Set(waits.compactMap { wait -> UUID? in if case .output = wait.request.until { wait.request.terminal } else { nil } })
        for terminal in allTerminals() where !watched.contains(terminal.id) { terminal.stopWatchingText() }
    }

    // MARK: The clock and changes

    /// Ten times a second while anything is pending.
    func tick() {
        for id in Array(startups.keys) { advance(id) }
        for (id, program) in programs where program == .running {
            guard let terminal = terminal(id) else { continue }
            if hasEnded(terminal) { noteParent(of: terminal) }
        }
        for id in Array(queues.keys) { deliver(id) }
        evaluateWaits()
    }

    /// A terminal's report changed, it printed, or it ended.
    func changed(_ terminal: HostedTerminal) {
        if startups[terminal.id] != nil { advance(terminal.id) }
        noteParent(of: terminal)
        if let parent = terminal.origin?.parent, queues[parent] != nil { deliver(parent) }
        if queues[terminal.id] != nil { deliver(terminal.id) }
        evaluateWaits()
    }

    /// A terminal has been forgotten.
    func forget(_ id: UUID) {
        startups[id] = nil
        told[id] = nil
        programs[id] = nil
        evaluateWaits()
    }
}
