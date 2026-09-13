import Foundation
import TerminalHost
import WhiskrKit

/// What each command does, against a greeted session, and what it prints.
struct Commands {
    let session: PawSession
    let paw: Paw

    private var io: PawIO { paw.io }

    func perform(_ command: PawCommand) throws(PawFailure) -> PawExit {
        switch command {
        case .run(let run): return try self.run(run)
        case .send(let send): return try self.send(send)
        case .wait(let wait): return try self.wait(wait)
        case .read(let target, let lines, let json): return try read(target, lines: lines, json: json)
        case .keys(let target, let keys):
            let terminal = try session.resolve(target)
            return try simple(.keys(terminal: terminal.id, keys), terminal)
        case .interrupt(let target):
            let terminal = try session.resolve(target)
            return try simple(.interrupt(terminal: terminal.id), terminal)
        case .list(let childrenOnly, let json): return list(childrenOnly: childrenOnly, json: json)
        case .kill(let target, let force): return try kill(target, force: force)
        case .help, .skill, .version: return .ok
        }
    }

    // MARK: run

    private func run(_ run: PawCommand.Run) throws(PawFailure) -> PawExit {
        let task = run.task == "-" ? io.input() : run.task
        var folder = expand(run.folder) ?? paw.currentFolder
        if let branch = run.worktree { folder = try worktree(branch, from: folder) }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            throw PawFailure(.failed, "no folder \(folder)")
        }
        let request = RunRequest(terminal: UUID(), parent: session.caller?.id, command: run.command, task: task, name: run.name, directory: folder,
                                 background: run.background, outlivesParent: run.outlivesParent, notifiesParent: run.notifiesParent,
                                 environment: paw.environment)
        let created: TerminalInfo
        switch try session.ask(.run(request)) {
        case .created(let info): created = info
        case .failed(let failure): throw PawFailure(failure)
        default: throw PawFailure(.failed, "the session host did not start it")
        }
        let label = created.label
        let address = created.address ?? created.id.uuidString
        guard case .waited(let result) = try session.ask(.wait(WaitRequest(terminal: created.id, until: .started, timeout: run.timeout)), waiting: run.timeout) else {
            throw PawFailure(.failed, "the session host did not say whether \(label) started")
        }
        let exit: PawExit
        let said: String
        let handed = task == nil ? "" : (AgentText.delivery(for: run.command ?? "") == .argument ? "; it has its task" : "; its task is sent once it is ready")
        switch result.outcome {
        case .met:
            exit = .ok
            said = result.terminal.exited ? "\(label) ran and has already ended (paw read \(address) shows what it printed)"
                : task == nil ? "started \(label)" : "started \(label) and handed over the task"
        case .blocked:
            exit = .blocked
            said = "started \(label); it waits for an answer before it starts\(handed) (look with: paw read \(address))"
        case .exited:
            exit = .exited
            said = "\(label) ended before it started (look with: paw read \(address))"
        case .timedOut:
            exit = .timedOut
            said = "started \(label), but it is not ready yet\(handed) (look with: paw read \(address))"
        }
        if run.json {
            var object = describe(result.terminal)
            object["started"] = result.outcome == .met
            object["outcome"] = result.outcome.rawValue
            io.out(json(object))
        } else {
            // The address alone on standard output, for scripts; the sentence beside it for people.
            io.out(address)
            io.err(said)
        }
        return exit
    }

    /// The folder of a worktree of the repository `folder` is in, on `branch`: an existing checkout of it,
    /// else a new one in the worktrees folder (the app's setting, passed in `PAW_WORKTREES`).
    private func worktree(_ branch: String, from folder: String) throws(PawFailure) -> String {
        guard let head = GitHead.find(from: folder) else { throw PawFailure(.failed, "--worktree needs a git repository; \(folder) is not in one") }
        let repository = head.repository ?? head.root
        let git = GitRunner()
        guard Worktrees.isValidBranchName(branch, git: git) else { throw PawFailure(.usage, "\(branch) is not a valid branch name") }
        do {
            let existing = try Worktrees.list(repository: repository, git: git)
            if let checkout = existing.first(where: { $0.branch == branch }) { return checkout.path }
            let root = expand(paw.environment["PAW_WORKTREES"]) ?? (NSHomeDirectory() + "/.whiskr/worktrees")
            let path = Worktrees.defaultPath(folder: URL(fileURLWithPath: root, isDirectory: true), repositoryName: URL(fileURLWithPath: repository).lastPathComponent, branch: branch).path
            try Worktrees.create(repository: repository, branch: branch, base: nil, at: path, git: git)
            io.err("made a worktree on \(branch) at \(abbreviate(path))")
            return path
        } catch {
            throw PawFailure(.failed, "could not make the worktree: \(error.message)")
        }
    }

    // MARK: send

    private func send(_ send: PawCommand.Send) throws(PawFailure) -> PawExit {
        let target = try session.resolve(send.target)
        let text = send.text == "-" ? io.input() : send.text
        guard !text.isEmpty else { throw PawFailure(.usage, "nothing to send") }
        let request = SendRequest(terminal: target.id, sender: session.caller?.id, text: text, raw: send.raw, force: send.force, submit: send.submit)
        // Typed once any half-written draft of a person's is sent (up to a minute).
        switch try session.ask(.send(request), waiting: 70) {
        case .done: break
        case .failed(let failure): throw PawFailure(failure, target: send.target)
        default: throw PawFailure(.failed, "the session host did not say it was sent")
        }
        guard send.wait else {
            if send.json { io.out(json(["sent": true, "terminal": target.address ?? ""])) }
            return .ok
        }
        // First it must show it took it in; then it is waited for as `paw wait` does.
        guard case .waited(let took) = try session.ask(.wait(WaitRequest(terminal: target.id, until: .activity, timeout: 5)), waiting: 5) else {
            throw PawFailure(.failed, "the session host did not answer the wait")
        }
        if took.outcome == .timedOut {
            if send.json { io.out(json(["sent": true, "outcome": "stalled", "terminal": target.address ?? ""])) } else {
                io.err("\(target.label) shows no sign of having taken it in (look with: paw read \(target.address ?? ""))")
            }
            return .stalled
        }
        return try settle(target, until: .settled, timeout: send.timeout, json: send.json)
    }

    // MARK: wait

    private func wait(_ wait: PawCommand.Wait) throws(PawFailure) -> PawExit {
        let target: TerminalInfo
        if let name = wait.target {
            target = try session.resolve(name)
        } else if let caller = session.caller {
            target = caller
        } else {
            throw PawFailure(.usage, "wait --children with no terminal waits for yours, and this is not one of the app's terminals")
        }
        let until: WaitCondition = switch wait.until {
        case .settled: .settled
        case .exited: .exited
        case .output(let text): .output(text)
        case .children(let all): .children(all: all)
        }
        return try settle(target, until: until, timeout: wait.timeout, json: wait.json)
    }

    private func settle(_ target: TerminalInfo, until: WaitCondition, timeout: Double, json wantsJSON: Bool) throws(PawFailure) -> PawExit {
        guard case .waited(let result) = try session.ask(.wait(WaitRequest(terminal: target.id, until: until, timeout: timeout)), waiting: timeout) else {
            throw PawFailure(.failed, "the session host did not answer the wait")
        }
        let exit: PawExit = switch result.outcome {
        case .met: .ok
        case .timedOut: .timedOut
        case .blocked: .blocked
        case .exited: until == .exited ? .ok : .exited
        }
        if wantsJSON {
            var object = describe(result.terminal)
            object["outcome"] = result.outcome.rawValue
            if case .children = until { object["children"] = result.children.map(describe) }
            io.out(json(object))
            return exit
        }
        if case .children = until {
            if result.children.isEmpty { io.out("\(result.terminal.label) has started no terminals") }
            for child in result.children { io.out(line(child)) }
        } else {
            io.out(line(result.terminal))
        }
        if result.outcome == .timedOut { io.err("still going after \(Int(timeout)) s; wait again to keep waiting") }
        return exit
    }

    // MARK: read

    private func read(_ name: String, lines: Int, json wantsJSON: Bool) throws(PawFailure) -> PawExit {
        let target = try session.resolve(name)
        guard case .snapshot(let info, let count, _) = try session.ask(.read(terminal: target.id)) else {
            throw PawFailure(.failed, "the session host did not show \(name)")
        }
        let bytes = session.readBytes(count)
        var screen = TextScreen(columns: max(info.size.columns, 1), rows: max(info.size.rows, 1))
        screen.feed(bytes)
        let text = screen.unwrappedText(history: lines)
        if wantsJSON {
            var object = describe(info)
            object["lines"] = text
            io.out(json(object))
        } else {
            io.out(text.joined(separator: "\n"))
        }
        return .ok
    }

    // MARK: keys, interrupt, kill

    private func simple(_ request: HostRequest, _ target: TerminalInfo) throws(PawFailure) -> PawExit {
        switch try session.ask(request) {
        case .done: return .ok
        case .failed(let failure): throw PawFailure(failure, target: target.address)
        default: throw PawFailure(.failed, "the session host did not answer")
        }
    }

    private func kill(_ name: String, force: Bool) throws(PawFailure) -> PawExit {
        let target = try session.resolve(name)
        guard !target.exited else { throw PawFailure(.exited, "\(target.label) has already ended") }
        guard target.origin != nil || force else {
            throw PawFailure(.failed, "\(target.label) is one of the app's own tabs; paw kill ends only terminals paw started (--force to end it anyway)")
        }
        guard target.id != session.caller?.id || force else { throw PawFailure(.failed, "that is this terminal (--force to end it anyway)") }
        return try simple(.close(terminal: target.id, after: 0), target)
    }

    // MARK: ls

    private func list(childrenOnly: Bool, json wantsJSON: Bool) -> PawExit {
        var terminals = session.terminals.filter { !$0.closing || !$0.exited }
        if childrenOnly { terminals = terminals.filter { $0.origin?.parent != nil && $0.origin?.parent == session.caller?.id } }
        terminals.sort { ($0.address ?? "").localizedStandardCompare($1.address ?? "") == .orderedAscending }
        if wantsJSON {
            io.out(json(terminals.map(describe)))
            return .ok
        }
        let rows = [["ADDRESS", "NAME", "STATE", "PROGRAM", "FOLDER", "PARENT"]] + terminals.map { terminal in
            let address = (terminal.address ?? "?") + (terminal.id == session.caller?.id ? "*" : "")
            return [address, terminal.name ?? "", state(terminal), program(terminal) ?? "", abbreviate(terminal.status.folder ?? terminal.directory ?? ""),
                    session.info(terminal.origin?.parent)?.address ?? ""]
        }
        let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            io.out(row.enumerated().map { $1.padding(toLength: $0 == row.count - 1 ? $1.count : widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
        if session.caller != nil { io.err("* this terminal") }
        return .ok
    }

    // MARK: Words

    /// "working", "blocked (permission)", "exited (0)".
    private func state(_ terminal: TerminalInfo) -> String {
        switch terminal.activity {
        case .blocked: terminal.status.program?.kind.map { "blocked (\($0))" } ?? "blocked"
        case .exited: terminal.exitCode.map { "exited (\($0))" } ?? "exited"
        default: terminal.activity.rawValue
        }
    }

    private func program(_ terminal: TerminalInfo) -> String? {
        guard let front = terminal.status.foreground else { return nil }
        return front.isClaude ? "claude" : front.name
    }

    /// "t4 review: idle", for the end of a wait.
    private func line(_ terminal: TerminalInfo) -> String {
        "\(terminal.label): \(state(terminal))"
    }

    private func describe(_ terminal: TerminalInfo) -> [String: Any] {
        func value(_ text: String?) -> Any { text ?? NSNull() }
        var object: [String: Any] = [
            "id": terminal.id.uuidString, "address": value(terminal.address), "name": value(terminal.name),
            "state": terminal.activity.rawValue, "program": value(program(terminal)),
            "folder": value(terminal.status.folder ?? terminal.directory),
            "parent": value(session.info(terminal.origin?.parent)?.address),
            "background": terminal.origin?.background ?? false,
            "startedByPaw": terminal.origin != nil,
        ]
        if let code = terminal.exitCode { object["exitCode"] = Int(code) }
        if let report = terminal.status.program {
            object["turns"] = report.turns
            if let kind = report.kind, report.state == .blocked { object["blockedOn"] = kind }
        }
        return object
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func expand(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        return URL(fileURLWithPath: paw.currentFolder).appendingPathComponent(expanded).standardizedFileURL.path
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
