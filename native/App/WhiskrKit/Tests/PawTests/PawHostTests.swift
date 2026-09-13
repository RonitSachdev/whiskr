import Darwin
import Foundation
import Testing
@testable import Paw
@testable import TerminalHost
import WhiskrKit

/// `paw` against a real session host with real pseudo-terminals: a parent terminal made as the app
/// makes its panes, helpers started from it, messages, notes, waits, reads and lifetimes. Agents are
/// played by a small script that speaks the program status protocol (OSC 7501) as Claude Code does.
@Suite("paw: agents starting and steering agents", .serialized)
final class PawHostTests {
    let folder: URL
    let socket: HostSocket
    let finished = DispatchSemaphore(value: 0)
    var server: HostServer?
    var app: HostConnection?

    init() throws {
        folder = URL(fileURLWithPath: "/tmp/wkp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        socket = HostSocket(path: folder.appendingPathComponent("h.sock").path, lock: folder.appendingPathComponent("h.lock").path, log: "")
        try Self.agentScript.write(to: folder.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        chmod(folder.appendingPathComponent("agent.sh").path, 0o755)
    }

    deinit {
        app?.close()
        server?.stop()
        _ = finished.wait(timeout: .now() + 5)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An agent as far as the host can tell: it reports idle at its prompt, working while it handles a
    /// line, and blocked when a line asks it to wait for an answer. Every line it reads it prints back.
    static let agentScript = #"""
    #!/bin/sh
    report() { printf '\033]7501;state=%s\033\\' "$1"; }
    report idle
    while IFS= read -r line; do
      report working
      echo "got: $line"
      case "$line" in
        *please-block*) report "blocked:kind=permission"; IFS= read -r answer; report working; echo "answer: $answer" ;;
        *please-fail*) report error; continue ;;
        *please-quit*) exit 3 ;;
      esac
      sleep 0.3
      report idle
    done
    """#

    func startServer(speaks: HostVersion = HostProtocol.current) throws {
        let finished = finished
        let server = HostServer(options: .init(socket: socket, build: "test", idleGrace: 600, speaks: speaks)) { finished.signal() }
        try server.start()
        self.server = server
    }

    func connect(version: HostVersion = HostProtocol.current, heard: Heard = Heard()) throws -> HostConnection {
        let connection = try HostConnection(socketPath: socket.path, handlers: heard.handlers)
        guard case .hello? = connection.requestAndWait(.hello(version, client: "test"), timeout: 5) else { throw HostFailure(.connectionLost, "no hello") }
        return connection
    }

    var environment: [String: String] { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "HOME": folder.path, "PS1": "$ "] }

    /// A terminal as the app makes one for a pane: a login shell, attached to the "app" connection.
    func makePane(_ connection: HostConnection, heard: Heard? = nil) throws -> TerminalInfo {
        let id = UUID()
        let spec = TerminalSpec(terminal: id, process: Launch.shell("/bin/sh", directory: folder.path, environment: environment), size: TerminalSize(columns: 100, rows: 30))
        guard case .created(let info)? = connection.requestAndWait(.create(spec), timeout: 5) else { throw HostFailure(.launchFailed) }
        return info
    }

    func list(_ connection: HostConnection) -> [TerminalInfo] {
        guard case .list(let terminals)? = connection.requestAndWait(.list, timeout: 5) else { return [] }
        return terminals
    }

    /// `paw` as typed in the terminal `caller` (its environment, as the host set it).
    func paw(_ arguments: String..., in caller: TerminalInfo?, input: String = "") -> (code: Int32, out: String, err: String) {
        var environment = environment
        environment["PAW_SOCKET"] = socket.path
        if let address = caller?.address { environment["PAW_ID"] = address }
        let out = Lines(), err = Lines()
        let code = Paw(environment: environment, currentFolder: folder.path, io: PawIO(out: { out.add($0) }, err: { err.add($0) }, input: { input })).run(arguments)
        return (code, out.text, err.text)
    }

    /// The screen of a terminal, through `paw read`.
    func screen(_ target: String) -> String { paw("read", target, "--lines", "200", in: nil).out }

    // MARK: Identity

    @Test("Every terminal gets an address and is told who it is; a helper also hears who started it")
    func identity() throws {
        try startServer()
        let app = try connect()
        self.app = app
        let heard = Heard()
        let viewer = try connect(heard: heard)
        let pane = try makePane(viewer)
        #expect(pane.address == "t1")
        viewer.type(Data("echo id=$PAW_ID parent=${PAW_PARENT:-none} sock=${PAW_SOCKET##*/}\n".utf8), into: pane.id)
        #expect(eventually { heard.text.contains("id=t1 parent=none sock=h.sock") })

        let started = paw("run", "--bg", "--name", "helper", in: pane)
        #expect(started.code == 0, "\(started.err)")
        #expect(started.out == "t2")
        let helper = try #require(list(app).first { $0.address == "t2" })
        #expect(helper.name == "helper")
        #expect(helper.origin == TerminalOrigin(parent: pane.id, background: true))
        #expect(paw("send", "helper", "echo me=$PAW_ID name=$PAW_NAME parent=$PAW_PARENT pane=$WHISKR_PANE", in: pane).code == 0)
        #expect(eventually { self.screen("t2").contains("me=t2 name=helper parent=t1 pane=\(helper.id.uuidString)") })
        // A name is taken while its terminal runs, and must look like one.
        #expect(paw("run", "--bg", "--name", "helper", in: pane).code == PawExit.failed.rawValue)
        #expect(paw("run", "--bg", "--name", "t9", in: pane).code == PawExit.failed.rawValue)
        // ls lists both, the caller marked.
        let listing = paw("ls", in: pane)
        #expect(listing.out.contains("t1*") && listing.out.contains("t2") && listing.out.contains("helper"))
        let json = paw("ls", "--children", "--json", in: pane).out
        let children = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(children?.map { $0["address"] as? String } == ["t2"])
        #expect(children?.first?["parent"] as? String == "t1")
        viewer.close()
    }

    // MARK: Tasks

    @Test("run types the command once the prompt is up and hands the task over when the program is ready")
    func runHandsOverTheTask() throws {
        try startServer()
        let app = try connect()
        self.app = app
        let pane = try makePane(app)
        // An agent: the task is pasted once it reports idle, and it starts working on it.
        let agent = paw("run", "--bg", "--name", "agent", "\(folder.path)/agent.sh", "Map the old auth code", in: pane)
        #expect(agent.code == 0, "\(agent.err)")
        #expect(eventually { self.screen("agent").contains("got: Map the old auth code") })
        // Something that reports nothing: the task goes in once it has been quiet in front for a moment.
        let plain = paw("run", "--bg", "cat", "plain task", in: pane)
        #expect(plain.code == 0, "\(plain.err)")
        #expect(eventually(8) { self.screen(plain.out).components(separatedBy: "plain task").count >= 3 })
        // A task from standard input.
        let piped = paw("run", "--bg", "\(folder.path)/agent.sh", "-", in: pane, input: "from stdin")
        #expect(piped.code == 0)
        #expect(eventually { self.screen(piped.out).contains("got: from stdin") })
        // A program that is blocked before it is ready: run says so (exit 6) and the task waits.
        let script = folder.appendingPathComponent("asks-first.sh")
        try "#!/bin/sh\nprintf '\\033]7501;state=blocked:kind=question\\033\\\\'\nIFS= read -r a\nexec \(folder.path)/agent.sh\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let asks = paw("run", "--bg", "--timeout", "10", script.path, "the held task", in: pane)
        #expect(asks.code == PawExit.blocked.rawValue, "\(asks.err)")
        #expect(!screen(asks.out).contains("got: the held task"))
        #expect(paw("keys", asks.out, "y", "enter", in: pane).code == 0)
        #expect(eventually { self.screen(asks.out).contains("got: the held task") })
    }

    @Test("Claude Code gets its task on its command line, never pasted")
    func claudeTakesTheTaskAsItsArgument() throws {
        #expect(AgentText.delivery(for: "claude") == .argument)
        #expect(AgentText.delivery(for: "claude --model haiku") == .argument)
        #expect(AgentText.delivery(for: "/usr/local/bin/claude") == .argument)
        #expect(AgentText.delivery(for: "CLAUDE_CONFIG_DIR=~/.claude-work claude") == .argument)
        #expect(AgentText.delivery(for: "codex") == .paste)
        #expect(AgentText.delivery(for: "claudette") == .paste)
        #expect(AgentText.typedLine(command: "claude --model haiku", task: "hi") == "claude --model haiku -- \"$PAW_TASK\"")
        #expect(AgentText.typedLine(command: "claude --allowedTools Read -- ", task: "hi") == "claude --allowedTools Read --  \"$PAW_TASK\"")
        #expect(AgentText.typedLine(command: "claude", task: nil) == "claude")
        // A stand-in `claude` on the PATH shows the task arrives whole, quotes and all.
        try startServer()
        let app = try connect()
        self.app = app
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '\\033]7501;state=working\\033\\\\'\n[ \"$1\" = -- ] && shift\necho \"claude-got[$1]\"\nsleep 30\n".write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        chmod(bin.appendingPathComponent("claude").path, 0o755)
        let id = UUID()
        var environment = environment
        environment["PATH"] = bin.path + ":" + environment["PATH"]!
        let spec = TerminalSpec(terminal: id, process: Launch.shell("/bin/sh", directory: folder.path, environment: environment), size: TerminalSize(columns: 100, rows: 30))
        guard case .created(let pane)? = app.requestAndWait(.create(spec), timeout: 5) else { Issue.record("no pane"); return }
        let task = #"Fix "the cart" & say $HOME's 'name'"#
        let run = paw("run", "--bg", "claude", task, in: pane)
        #expect(run.code == 0, "\(run.err)")
        #expect(eventually { self.screen(run.out).contains("claude-got[\(task)]") })
    }

    // MARK: Messages

    @Test("send tags a message for an agent, never for a shell, and refuses one waiting for an answer")
    func sendRules() throws {
        try startServer()
        let app = try connect()
        self.app = app
        let pane = try makePane(app)
        let agent = paw("run", "--bg", "--name", "agent", "\(folder.path)/agent.sh", in: pane)
        #expect(agent.code == 0)
        #expect(eventually { self.list(app).first { $0.name == "agent" }?.status.program?.state == .idle })
        #expect(paw("send", "agent", "hello there", in: pane).code == 0)
        #expect(eventually { self.screen("agent").contains(#"got: <paw from="t1">hello there</paw>"#) })
        // A shell runs what it is sent: no tag.
        #expect(paw("send", "t1", "echo sum-$((40+2))", in: nil).code == 0)
        #expect(eventually { self.screen("t1").contains("sum-42") })
        // --raw: no tag for an agent either; --wait: back once it has taken it in and settled.
        let waited = paw("send", "agent", "--raw", "--wait", "plain words", in: pane)
        #expect(waited.code == 0, "\(waited.err)")
        #expect(waited.out.contains("agent: idle"))
        #expect(screen("agent").contains("got: plain words"))
        // Waiting for an answer: refused (6), unless forced.
        #expect(paw("send", "agent", "please-block", in: pane).code == 0)
        #expect(eventually { self.list(app).first { $0.name == "agent" }?.status.program?.state == .blocked })
        let refused = paw("send", "agent", "yes", in: pane)
        #expect(refused.code == PawExit.blocked.rawValue)
        #expect(refused.err.contains("waiting for an answer (permission)"))
        #expect(paw("send", "agent", "--force", "--raw", "forced-answer", in: pane).code == 0)
        #expect(eventually { self.screen("agent").contains("answer: forced-answer") })
        // No such terminal: 3. An ended one: 7.
        #expect(paw("send", "t99", "hi", in: pane).code == PawExit.notFound.rawValue)
        #expect(paw("send", "agent", "--raw", "please-quit", in: pane).code == 0)
        #expect(eventually { self.list(app).first { $0.name == "agent" }?.exited == true })
        #expect(paw("send", "agent", "hi", in: pane).code == PawExit.exited.rawValue)
    }

    @Test("A message never lands in what a person is typing: it waits until they send it")
    func waitsForADraft() throws {
        try startServer()
        let app = try connect()
        self.app = app
        let pane = try makePane(app)
        #expect(paw("run", "--bg", "--name", "agent", "\(folder.path)/agent.sh", in: pane).code == 0)
        let agent = try #require(list(app).first { $0.name == "agent" })
        #expect(eventually { self.list(app).first { $0.name == "agent" }?.status.program?.state == .idle })
        // A person starts typing into it (through a viewer, as the app would carry their keys).
        let person = try connect()
        defer { person.close() }
        person.type(Data("half a thou".utf8), into: agent.id)
        let sent = Lines()
        let started = Date()
        // `paw` as a second process would run it, on a thread of its own while the person types.
        let socket = socket, environment = environment
        let folder = folder
        DispatchQueue.global().async {
            var env = environment
            env["PAW_SOCKET"] = socket.path
            env["PAW_ID"] = pane.address
            let code = Paw(environment: env, currentFolder: folder.path, io: PawIO(out: { _ in }, err: { _ in }, input: { "" })).run(["send", "agent", "--raw", "from-a-helper"])
            sent.add("\(code)")
        }
        usleep(1_200_000)
        #expect(sent.all.isEmpty)
        #expect(!screen("agent").contains("from-a-helper"))
        person.type(Data("ght\r".utf8), into: agent.id)
        #expect(eventually { sent.all == ["0"] })
        #expect(eventually { self.screen("agent").contains("got: half a thought") && self.screen("agent").contains("got: from-a-helper") })
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: Notes and lifetimes

    @Test("A parent hears when its helper needs an answer, stops on an error, or ends")
    func notesToTheParent() throws {
        try startServer()
        let app = try connect()
        self.app = app
        let pane = try makePane(app)
        // The parent is an agent itself (notes are never typed into a shell).
        let boss = paw("run", "--bg", "--name", "boss", "\(folder.path)/agent.sh", in: pane)
        #expect(boss.code == 0)
        let bossInfo = try #require(list(app).first { $0.name == "boss" })
        #expect(eventually { self.list(app).first { $0.name == "boss" }?.status.program?.state == .idle })
        let helper = paw("run", "--bg", "--name", "kid", "\(folder.path)/agent.sh", "please-block", in: bossInfo)
        #expect(helper.code == 0, "\(helper.err)")
        #expect(eventually { self.screen("boss").contains(#"note="blocked">t3 kid is waiting for an answer (permission). Look with: paw read t3</paw>"#) })
        #expect(paw("send", "kid", "--force", "--raw", "ok", in: bossInfo).code == 0)
        #expect(paw("send", "kid", "--raw", "please-fail", in: bossInfo).code == 0)
        #expect(eventually { self.screen("boss").contains(#"note="error">t3 kid stopped on an error"#) })
        #expect(paw("send", "kid", "--raw", "please-quit", in: bossInfo).code == 0)
        #expect(eventually { self.screen("boss").contains(#"note="exited">t3 kid has ended (exit code 3).</paw>"#) })
        // With --no-notify it hears nothing.
        let quiet = paw("run", "--bg", "--no-notify", "\(folder.path)/agent.sh", "please-block", in: bossInfo)
        #expect(quiet.code == 0)
        usleep(1_500_000)
        #expect(!screen("boss").contains("\(quiet.out) is waiting"))
    }

    @Test("Helpers end with whoever started them, unless told to outlive it")
    func helpersEndWithTheirParent() throws {
        try startServer()
        let app = try connect()
        self.app = app
        let pane = try makePane(app)
        let bound = paw("run", "--bg", "sleep 600", in: pane)
        let free = paw("run", "--bg", "--outlive-parent", "sleep 600", in: pane)
        #expect(bound.code == 0 && free.code == 0)
        // Closing the parent ends its shell, and so its helper; the one told to outlive it stays.
        app.send(.close(terminal: pane.id, after: 0))
        #expect(eventually(8) { self.list(app).first { $0.address == bound.out }.map(\.exited) ?? true })
        #expect(list(app).first { $0.address == free.out }?.exited == false)
        #expect(paw("kill", free.out, in: nil).code == 0)
        #expect(eventually(8) { self.list(app).first { $0.address == free.out }.map(\.exited) ?? true })
    }

    // MARK: Waits, reads, keys

    @Test("wait: until it settles, ends, prints something, or its helpers are done; with a timeout")
    func waits() throws {
        try startServer()
        let app = try connect()
        self.app = app
        let pane = try makePane(app)
        let agent = paw("run", "--bg", "--name", "agent", "\(folder.path)/agent.sh", in: pane)
        #expect(agent.code == 0)
        // Settled already (idle): back at once.
        let settled = paw("wait", "agent", "--timeout", "5", in: pane)
        #expect(settled.code == 0 && settled.out == "t2 agent: idle")
        // Output already printed counts; new output too.
        #expect(paw("send", "agent", "--raw", "marker-one", in: pane).code == 0)
        #expect(paw("wait", "agent", "--output", "got: marker-one", "--timeout", "5", in: pane).code == 0)
        #expect(paw("wait", "agent", "--output", "never printed", "--timeout", "1", in: pane).code == PawExit.timedOut.rawValue)
        // Blocked: 6.
        #expect(paw("send", "agent", "--raw", "please-block", in: pane).code == 0)
        #expect(paw("wait", "agent", "--timeout", "5", in: pane).code == PawExit.blocked.rawValue)
        #expect(paw("keys", "agent", "o", "k", "enter", in: pane).code == 0)
        // A plain command: working while it runs, settled when the shell is back.
        let sleeper = paw("run", "--bg", "sleep 1.5", in: pane)
        #expect(sleeper.code == 0)
        #expect(paw("wait", sleeper.out, "--timeout", "0.3", in: pane).code == PawExit.timedOut.rawValue)
        // A helper without a tab ends with its program: "it ended" (7) rather than "it stopped working".
        #expect(paw("wait", sleeper.out, "--timeout", "8", in: pane).code == PawExit.exited.rawValue)
        // Children: all of the pane's helpers have stopped working.
        let children = paw("wait", "--children", "all", "--timeout", "8", "--json", in: pane)
        #expect(children.code == 0, "\(children.err)")
        let object = try JSONSerialization.jsonObject(with: Data(children.out.utf8)) as? [String: Any]
        #expect((object?["children"] as? [[String: Any]])?.count == 2)
        // A quick command has run (not "ended before it started"), and stays readable after it ended.
        let quick = paw("run", "--bg", "--name", "quick", "echo quick-$((6*7))", in: pane)
        #expect(quick.code == 0, "\(quick.err)")
        #expect(paw("wait", "quick", "--exit", "--timeout", "5", in: pane).code == 0)
        #expect(eventually { self.screen("quick").contains("quick-42") })
        // Until it ends.
        #expect(paw("send", "agent", "--raw", "please-quit", in: pane).code == 0)
        let ended = paw("wait", "agent", "--exit", "--timeout", "5", in: pane)
        #expect(ended.code == 0 && ended.out.contains("exited (3)"))
        #expect(paw("wait", "t99", in: pane).code == PawExit.notFound.rawValue)
    }

    @Test("read prints the screen and its history as text; keys and interrupt reach the program")
    func readKeysAndInterrupt() throws {
        try startServer()
        let app = try connect()
        self.app = app
        _ = try makePane(app)
        #expect(paw("send", "t1", "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35; do echo line-$i; done", in: nil).code == 0)
        #expect(eventually { self.screen("t1").contains("line-35") })
        let visible = paw("read", "t1", in: nil).out
        #expect(visible.contains("line-35") && !visible.contains("line-2\n"))
        let all = paw("read", "t1", "--lines", "100", in: nil).out
        #expect(all.contains("line-1\n") && all.contains("line-35"))
        // keys: unknown names press nothing.
        #expect(paw("keys", "t1", "esc", "teleport", in: nil).code == PawExit.failed.rawValue)
        #expect(paw("send", "t1", "--no-enter", "echo typed-$((2+3))", in: nil).code == 0)
        #expect(paw("keys", "t1", "enter", in: nil).code == 0)
        #expect(eventually { self.screen("t1").contains("typed-5") })
        // interrupt: ⌃C to a plain program.
        #expect(paw("send", "t1", "sleep 600", in: nil).code == 0)
        #expect(eventually { self.list(app).first?.status.foreground?.name == "sleep" })
        #expect(paw("interrupt", "t1", in: nil).code == 0)
        #expect(eventually { self.list(app).first?.status.foreground == nil })
        // kill ends only what paw started, unless forced.
        #expect(paw("kill", "t1", in: nil).code == PawExit.failed.rawValue)
        #expect(paw("kill", "t1", "--force", in: nil).code == 0)
        #expect(eventually(8) { self.list(app).first?.exited ?? true })
    }

    // MARK: Versions

    @Test("An older host: paw says so (exit 4), and protocol-2 requests are unknown to it")
    func olderHost() throws {
        try startServer(speaks: HostVersion(version: 1, oldest: 1))
        let app = try connect()
        self.app = app
        let pane = try makePane(app)
        #expect(pane.address == "t1")
        let said = paw("ls", in: pane)
        #expect(said.code == PawExit.noHost.rawValue)
        #expect(said.err.contains("older"))
        guard case .failed(let failure)? = app.requestAndWait(.run(RunRequest(terminal: UUID(), parent: nil, command: nil, task: nil, name: nil, directory: folder.path, background: true)), timeout: 5) else {
            Issue.record("an older host answered run")
            return
        }
        #expect(failure.code == .unknownRequest)
    }

    @Test("An older client on this host: it creates, attaches and lists as before, and cannot ask what it does not speak")
    func olderClient() throws {
        try startServer()
        let old = try connect(version: HostVersion(version: 1, oldest: 1))
        self.app = old
        let pane = try makePane(old)
        guard case .attached(let info, _, _)? = old.requestAndWait(.attach(terminal: pane.id), timeout: 5) else { Issue.record("no attach"); return }
        #expect(info.id == pane.id)
        #expect(list(old).map(\.id) == [pane.id])
        guard case .failed(let failure)? = old.requestAndWait(.wait(WaitRequest(terminal: pane.id, until: .settled, timeout: 1)), timeout: 5) else {
            Issue.record("a v1 client was answered a wait")
            return
        }
        #expect(failure.code == .unknownRequest)
    }

    @Test("The host answers a program's status probe, unless an older viewer's own terminal will")
    func probes() throws {
        try startServer()
        // The terminal echoes what it is sent: an answer typed in shows as ^[]7501;?.
        let probe = "printf '\\033]7501;?\\007'; sleep 1; echo probe-$((40+2))\n"
        let heard = Heard()
        let app = try connect(heard: heard)
        self.app = app
        let pane = try makePane(app)
        app.type(Data(probe.utf8), into: pane.id)
        #expect(eventually { heard.text.contains("probe-42") })
        #expect(heard.text.contains("^[]7501;?"))
        // A terminal shown by a v1 viewer: that viewer's terminal answers, so the host does not.
        let oldHeard = Heard()
        let old = try connect(version: HostVersion(version: 1, oldest: 1), heard: oldHeard)
        defer { old.close() }
        let older = try makePane(old)
        old.type(Data(probe.utf8), into: older.id)
        #expect(eventually { oldHeard.text.contains("probe-42") })
        #expect(!oldHeard.text.contains("^[]7501;?"))
    }
}

/// What a test's connection has heard.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()

    var handlers: HostConnection.Handlers {
        HostConnection.Handlers(output: { [self] _, bytes in lock.withLock { output.append(bytes) } })
    }

    var text: String { lock.withLock { String(decoding: output, as: UTF8.self) } }
}

func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}
