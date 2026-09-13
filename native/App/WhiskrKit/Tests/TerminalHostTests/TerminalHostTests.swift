import Darwin
import Foundation
import Testing
@testable import TerminalHost
import WhiskrKit

/// What a test's client has heard, shared with the connection's reading thread.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var events: [HostEvent] = []
    private var closed = false

    var handlers: HostConnection.Handlers {
        HostConnection.Handlers(
            output: { [self] _, bytes in lock.withLock { output.append(bytes) } },
            event: { [self] event in lock.withLock { events.append(event) } },
            closed: { [self] in lock.withLock { closed = true } })
    }

    var text: String { lock.withLock { String(decoding: output, as: UTF8.self) } }
    var allEvents: [HostEvent] { lock.withLock { events } }
    var isClosed: Bool { lock.withLock { closed } }
}

/// Waits until `condition` holds; false when it has not within `seconds`.
func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

/// A host of its own on a socket of its own, with real pseudo-terminals running `/bin/sh`.
@Suite("Session host: real terminals over a real socket", .serialized)
final class TerminalHostTests {
    let folder: URL
    let socket: HostSocket
    let finished = DispatchSemaphore(value: 0)
    var server: HostServer?

    init() throws {
        // A short path: a socket's address holds 103 bytes.
        folder = URL(fileURLWithPath: "/tmp/wkh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        socket = HostSocket(path: folder.appendingPathComponent("h.sock").path, lock: folder.appendingPathComponent("h.lock").path, log: "")
        try startServer()
    }

    deinit {
        server?.stop()
        _ = finished.wait(timeout: .now() + 5)
        try? FileManager.default.removeItem(at: folder)
    }

    func startServer(idleGrace: TimeInterval = 600, abandonedAfter: TimeInterval? = nil) throws {
        let finished = finished
        let server = HostServer(options: .init(socket: socket, build: "test", idleGrace: idleGrace, abandonedAfter: abandonedAfter)) { finished.signal() }
        try server.start()
        self.server = server
    }

    func connect(_ heard: Heard = Heard(), version: HostVersion = HostProtocol.current) throws -> HostConnection {
        let connection = try HostConnection(socketPath: socket.path, handlers: heard.handlers)
        guard case .hello? = connection.requestAndWait(.hello(version, client: "test"), timeout: 5) else { throw HostFailure(.connectionLost, "no hello") }
        return connection
    }

    func spec(_ id: UUID, executable: String = "/bin/sh") -> TerminalSpec {
        let process = Launch.shell(executable, directory: folder.path, environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": folder.path])
        return TerminalSpec(terminal: id, process: process, size: TerminalSize(columns: 100, rows: 30))
    }

    func create(_ connection: HostConnection, _ id: UUID) throws -> TerminalInfo {
        guard case .created(let info)? = connection.requestAndWait(.create(spec(id)), timeout: 5) else { throw HostFailure(.launchFailed) }
        return info
    }

    func list(_ connection: HostConnection) -> [TerminalInfo] {
        guard case .list(let terminals)? = connection.requestAndWait(.list, timeout: 5) else { return [] }
        return terminals
    }

    func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    @Test("A program runs on a real terminal: typed input reaches it, its output comes back, a resize is felt")
    func runsAProgram() throws {
        let heard = Heard(), id = UUID()
        let connection = try connect(heard)
        defer { connection.close() }
        let info = try create(connection, id)
        #expect(info.pid > 0 && alive(info.pid))
        // The terminal is the shell's controlling terminal (job control depends on it), at the size asked.
        connection.type(Data("echo sum-$((6*7)); stty size; echo controlled-by-$(ps -o tty= -p $$)\n".utf8), into: id)
        #expect(eventually { heard.text.contains("sum-42") && heard.text.contains("30 100") && heard.text.contains("controlled-by-ttys") })
        connection.send(.resize(terminal: id, TerminalSize(columns: 132, rows: 43)))
        connection.type(Data("stty size\n".utf8), into: id)
        #expect(eventually { heard.text.contains("43 132") })
        // It starts in the folder it was given.
        connection.type(Data("pwd -P\n".utf8), into: id)
        #expect(eventually { heard.text.contains("wkh-") })
    }

    @Test("The program outlives its client: a new client finds it, with the same process and its screen")
    func survivesItsClient() throws {
        let id = UUID()
        let first = try connect()
        let info = try create(first, id)
        first.type(Data("echo before-$((40+2)); sleep 600\n".utf8), into: id)
        #expect(eventually { self.list(first).first?.status.foreground?.name == "sleep" })
        first.close()
        usleep(200_000)
        #expect(alive(info.pid))

        let heard = Heard()
        let second = try connect(heard)
        defer { second.close() }
        let terminals = list(second)
        #expect(terminals.map(\.id) == [id])
        #expect(terminals.first?.pid == info.pid)
        guard case .attached(let again, let replay, let truncated)? = second.requestAndWait(.attach(terminal: id), timeout: 5) else {
            Issue.record("attach failed")
            return
        }
        #expect(again.pid == info.pid)
        #expect(again.status.foreground?.name == "sleep")
        #expect(!truncated)
        #expect(eventually { heard.text.utf8.count >= replay })
        #expect(heard.text.contains("before-42"))
        // Still the same live program: Ctrl-C through the new client ends the sleep.
        second.type(Data([0x03]), into: id)
        #expect(eventually {
            heard.allEvents.contains { if case .status(_, let status) = $0 { status.foreground == nil } else { false } }
        })
        second.type(Data("echo after-$((50+5))\n".utf8), into: id)
        #expect(eventually { heard.text.contains("after-55") })
    }

    @Test("The foreground program is reported within a quarter of a second of starting")
    func reportsTheForeground() throws {
        let heard = Heard(), id = UUID()
        let connection = try connect(heard)
        defer { connection.close() }
        _ = try create(connection, id)
        connection.type(Data("echo up-$((1+1))\n".utf8), into: id)
        #expect(eventually { heard.text.contains("up-2") })
        let typed = Date()
        connection.type(Data("sleep 600\n".utf8), into: id)
        #expect(eventually(2) {
            heard.allEvents.contains { if case .status(_, let status) = $0 { status.foreground?.name == "sleep" } else { false } }
        })
        #expect(Date().timeIntervalSince(typed) < 0.25)
        connection.send(.signal(terminal: id, SIGINT))
        #expect(eventually {
            if case .status(_, let status)? = heard.allEvents.last { status.foreground == nil } else { false }
        })
    }

    @Test("Closing ends everything in the terminal; a close can be taken back until then")
    func closesAndKeeps() throws {
        let connection = try connect()
        defer { connection.close() }
        let kept = UUID(), closed = UUID()
        let keptInfo = try create(connection, kept), closedInfo = try create(connection, closed)
        // A child that ignores the hang-up is killed after the grace.
        connection.type(Data("trap '' HUP; sh -c 'trap \"\" HUP; sleep 600' & sleep 600\n".utf8), into: closed)
        #expect(eventually { self.list(connection).first { $0.id == closed }?.status.foreground != nil })
        // The shell, the background child (and the shell it may keep for its trap), and the sleep.
        #expect(ProcessControl.sessionMembers(closedInfo.pid).count >= 3)

        #expect(connection.requestAndWait(.close(terminal: kept, after: 30), timeout: 5) == .done)
        #expect(list(connection).first { $0.id == kept }?.closing == true)
        #expect(connection.requestAndWait(.keep(terminal: kept), timeout: 5) == .done)
        #expect(list(connection).first { $0.id == kept }?.closing == false)

        #expect(connection.requestAndWait(.close(terminal: closed, after: 0), timeout: 5) == .done)
        #expect(eventually(HostLifecycle.killGrace + 4) { !self.alive(closedInfo.pid) && self.list(connection).map(\.id) == [kept] })
        #expect(alive(keptInfo.pid))
        #expect(connection.requestAndWait(.keep(terminal: closed), timeout: 5) == .failed(HostFailure(.noSuchTerminal)))
        // The stragglers went with it: the background child that ignored the hang-up too.
        #expect(ProcessControl.sessionMembers(closedInfo.pid).isEmpty)
    }

    @Test("A program that ends says how; a later client can still read its last words")
    func reportsTheExit() throws {
        let heard = Heard(), id = UUID()
        let connection = try connect(heard)
        _ = try create(connection, id)
        connection.type(Data("echo last-$((1+1))words; exit 3\n".utf8), into: id)
        #expect(eventually { heard.allEvents.contains(.exited(terminal: id, exitCode: 3)) })
        #expect(heard.text.contains("last-2words"))
        #expect(list(connection).first?.exited == true)
        connection.close()

        // Nobody had seen a second one end: its record waits for whoever attaches next.
        let unseen = UUID()
        let starter = try connect()
        _ = try create(starter, unseen)
        starter.send(.detach(terminal: unseen))
        starter.type(Data("echo unseen-$((2+2)); exit 0\n".utf8), into: unseen)
        #expect(eventually { self.list(starter).first { $0.id == unseen }?.exited == true })
        starter.close()
        let later = Heard()
        let reader = try connect(later)
        defer { reader.close() }
        guard case .attached(let info, _, _)? = reader.requestAndWait(.attach(terminal: unseen), timeout: 5) else {
            Issue.record("attach failed")
            return
        }
        #expect(info.exited && info.exitCode == 0)
        #expect(eventually { later.text.contains("unseen-4") && later.allEvents.contains(.exited(terminal: unseen, exitCode: 0)) })
    }

    @Test("A client of a version the host cannot speak is told who the host is, and nothing more")
    func refusesAStranger() throws {
        let connection = try HostConnection(socketPath: socket.path)
        defer { connection.close() }
        guard case .hello(let info)? = connection.requestAndWait(.hello(HostVersion(version: 99, oldest: 99), client: "future"), timeout: 5) else {
            Issue.record("no answer to hello")
            return
        }
        #expect(info.version == HostProtocol.version && info.pid == getpid())
        guard case .failed(let failure)? = connection.requestAndWait(.list, timeout: 5) else {
            Issue.record("a stranger was answered")
            return
        }
        #expect(failure.code == .incompatible)
        // And one that never said hello.
        let silent = try HostConnection(socketPath: socket.path)
        defer { silent.close() }
        #expect(silent.requestAndWait(.list, timeout: 5) == .failed(HostFailure(.incompatible, "say hello first")))
        #expect(HostLauncher.probe(socket).probe == .compatible)
    }

    @Test("What cannot be started, and what is asked of a terminal that is not there, fail plainly")
    func failsPlainly() throws {
        let connection = try connect()
        defer { connection.close() }
        guard case .failed(let failure)? = connection.requestAndWait(.create(spec(UUID(), executable: "/nonexistent/shell")), timeout: 5) else {
            Issue.record("a missing program was started")
            return
        }
        #expect(failure.code == .launchFailed)
        #expect(connection.requestAndWait(.attach(terminal: UUID()), timeout: 5) == .failed(HostFailure(.noSuchTerminal)))
        let id = UUID()
        _ = try create(connection, id)
        #expect(connection.requestAndWait(.create(spec(id)), timeout: 5) == .failed(HostFailure(.terminalExists)))
        #expect(list(connection).count == 1)
    }

    @Test("Only one host owns a socket")
    func oneHostPerSocket() {
        let second = HostServer(options: .init(socket: socket, build: "test")) {}
        #expect(throws: HostServer.StartFailure.self) { try second.start() }
        #expect(HostLauncher.probe(socket).probe == .compatible)
    }

    @Test("Asked to stop, the host ends every terminal and finishes; its clients hear the connection end")
    func shutsDown() throws {
        let heard = Heard()
        let connection = try connect(heard)
        let info = try create(connection, UUID())
        connection.type(Data("sleep 600\n".utf8), into: info.id)
        #expect(connection.requestAndWait(.shutdown, timeout: 10) == .done)
        #expect(finished.wait(timeout: .now() + 5) == .success)
        server = nil
        finished.signal()
        #expect(eventually { !self.alive(info.pid) && heard.isClosed })
        #expect(HostLauncher.probe(socket).probe == .absent)
    }

    @Test("Output larger than the kept history replays from a line break, with the terminal's modes first")
    func replaysATruncatedHistory() throws {
        let id = UUID()
        let first = try connect()
        _ = try create(first, id)
        // Bracketed paste on, then far more output than is kept.
        first.type(Data("printf '\\033[?2004h'; i=0; while [ $i -lt 60000 ]; do echo \"row $i 0123456789012345678901234567890123456789012345678901234567890123456789\"; i=$((i+1)); done; echo finished-$((3*3))\n".utf8), into: id)
        let watcher = Heard()
        let watching = try connect(watcher)
        defer { watching.close() }
        _ = watching.requestAndWait(.attach(terminal: id), timeout: 5)
        #expect(eventually(60) { watcher.text.contains("finished-9") })
        first.close()

        let heard = Heard()
        let second = try connect(heard)
        defer { second.close() }
        guard case .attached(_, let replay, let truncated)? = second.requestAndWait(.attach(terminal: id), timeout: 5) else {
            Issue.record("attach failed")
            return
        }
        #expect(truncated)
        #expect(replay <= ReplayBuffer.defaultCapacity + 128 * 1024)
        #expect(eventually { heard.text.utf8.count >= replay })
        // The size it was printed at comes first, then the modes (the shell's own among them), then whole lines.
        let mark = String(decoding: ReplaySize.mark(TerminalSize(columns: 100, rows: 30)), as: UTF8.self)
        #expect(heard.text.hasPrefix(mark))
        let start = heard.text.dropFirst(mark.count).prefix(64)
        #expect(start.hasPrefix("\u{1B}[?") && start.contains("\u{1B}[?2004h"))
        #expect(start.split(separator: "h").last?.hasPrefix("row ") == true)
        #expect(heard.text.contains("finished-9"))
    }
}

@Suite("Session host: another version's host", .serialized)
struct HostStrangerTests {
    @Test("An app finds a host of a version it cannot speak, counts its terminals, and leaves them running")
    func aStrangerIsLeftAlone() throws {
        let folder = URL(fileURLWithPath: "/tmp/wkh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let places = HostPlaces(supportFolder: folder, temporaryFolder: folder)
        let finished = DispatchSemaphore(value: 0)
        let future = HostVersion(version: HostProtocol.version + 5, oldest: HostProtocol.version + 3)
        let stranger = HostServer(options: .init(socket: places.primary, build: "future", speaks: future)) { finished.signal() }
        try stranger.start()
        defer {
            stranger.stop()
            _ = finished.wait(timeout: .now() + 5)
        }
        // Its own app starts a terminal in it.
        let theirs = try HostConnection(socketPath: places.primary.path)
        defer { theirs.close() }
        _ = theirs.requestAndWait(.hello(future, client: "their app"), timeout: 5)
        let process = Launch.shell("/bin/sh", directory: "/tmp", environment: ["PATH": "/usr/bin:/bin"])
        guard case .created(let info)? = theirs.requestAndWait(.create(TerminalSpec(terminal: UUID(), process: process, size: TerminalSize(columns: 80, rows: 24))), timeout: 5) else {
            Issue.record("create failed")
            return
        }
        // This build knocks: a stranger with one terminal, so it would start its own host beside it.
        let probe = HostLauncher.probe(places.primary).probe
        #expect(probe == .stranger(terminals: 1))
        #expect(HostChoice.choose(primary: probe, alternate: HostLauncher.probe(places.alternate(for: HostProtocol.version)).probe) == .use(.alternate, start: true))
        // With no host program to start, finding fails without touching the stranger.
        let launcher = HostLauncher(places: places, executable: URL(fileURLWithPath: "/nonexistent/host"), build: "test")
        #expect(throws: HostLauncher.Failure.self) { try launcher.find() }
        #expect(kill(info.pid, 0) == 0)
        #expect(HostLauncher.probe(places.primary).probe == .stranger(terminals: 1))
    }
}

@Suite("Session host: one left by the app's earlier name", .serialized)
struct HostLegacyTests {
    @Test("A host of the old name still running is counted with the strangers and never used or ended")
    func legacyHostIsLeftAlone() throws {
        let folder = URL(fileURLWithPath: "/tmp/wkh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = HostPlaces.legacy(applicationSupport: folder, temporaryFolder: folder)
        #expect(legacy.folder.path.hasSuffix("/Workers Factory/host"))
        let ours = HostPlaces(supportFolder: folder.appendingPathComponent("Whiskr", isDirectory: true), temporaryFolder: folder)
        #expect(ours.primary != legacy.primary)
        let launcher = HostLauncher(places: ours, executable: URL(fileURLWithPath: "/nonexistent/host"), build: "test", legacyPlaces: legacy)
        #expect(launcher.legacyTerminals() == 0)
        #expect(!HostLauncher.anyHostRunning(at: legacy))

        // The old app's host speaks the same protocol and holds a running terminal.
        try FileManager.default.createDirectory(at: legacy.folder, withIntermediateDirectories: true)
        let finished = DispatchSemaphore(value: 0)
        let old = HostServer(options: .init(socket: legacy.primary, build: "old")) { finished.signal() }
        try old.start()
        defer {
            old.stop()
            _ = finished.wait(timeout: .now() + 5)
        }
        let theirs = try HostConnection(socketPath: legacy.primary.path)
        defer { theirs.close() }
        _ = theirs.requestAndWait(.hello(HostProtocol.current, client: "old app"), timeout: 5)
        let process = Launch.shell("/bin/sh", directory: "/tmp", environment: ["PATH": "/usr/bin:/bin"])
        guard case .created(let info)? = theirs.requestAndWait(.create(TerminalSpec(terminal: UUID(), process: process, size: TerminalSize(columns: 80, rows: 24))), timeout: 5) else {
            Issue.record("create failed")
            return
        }
        #expect(HostLauncher.anyHostRunning(at: legacy))
        #expect(launcher.legacyTerminals() == 1)
        // Finding a host never picks the old one: with no host program to start, it fails, and the old
        // host and its terminal are as they were.
        #expect(throws: HostLauncher.Failure.self) { try launcher.find() }
        #expect(kill(info.pid, 0) == 0)
        #expect(HostLauncher.probe(legacy.primary).probe == .compatible)
    }
}

@Suite("Session host: leaving by itself", .serialized)
struct HostLeavingTests {
    func socket() -> (URL, HostSocket) {
        let folder = URL(fileURLWithPath: "/tmp/wkh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return (folder, HostSocket(path: folder.appendingPathComponent("h.sock").path, lock: folder.appendingPathComponent("h.lock").path, log: ""))
    }

    @Test("With nothing running and nobody connected it finishes after its grace, not before")
    func leavesWhenIdle() throws {
        let (folder, socket) = socket()
        defer { try? FileManager.default.removeItem(at: folder) }
        let finished = DispatchSemaphore(value: 0)
        let server = HostServer(options: .init(socket: socket, build: "test", idleGrace: 0.6)) { finished.signal() }
        try server.start()
        // A connected client keeps it; so does a running terminal after the client has gone.
        let connection = try HostConnection(socketPath: socket.path)
        _ = connection.requestAndWait(.hello(HostProtocol.current, client: "test"), timeout: 5)
        let process = Launch.shell("/bin/sh", directory: "/tmp", environment: ["PATH": "/usr/bin:/bin"])
        guard case .created(let info)? = connection.requestAndWait(.create(TerminalSpec(terminal: UUID(), process: process, size: TerminalSize(columns: 80, rows: 24))), timeout: 5) else {
            Issue.record("create failed")
            return
        }
        #expect(finished.wait(timeout: .now() + 1.2) == .timedOut)
        connection.close()
        #expect(finished.wait(timeout: .now() + 1.2) == .timedOut)
        #expect(kill(info.pid, 0) == 0)
        // The program ends: now nothing holds the host.
        kill(info.pid, SIGKILL)
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(HostLauncher.probe(socket).probe == .absent)
    }

    @Test("A test run's host gives up on terminals nobody comes back for")
    func leavesWhenAbandoned() throws {
        let (folder, socket) = socket()
        defer { try? FileManager.default.removeItem(at: folder) }
        let finished = DispatchSemaphore(value: 0)
        let server = HostServer(options: .init(socket: socket, build: "test", idleGrace: 600, abandonedAfter: 0.8)) { finished.signal() }
        try server.start()
        let connection = try HostConnection(socketPath: socket.path)
        _ = connection.requestAndWait(.hello(HostProtocol.current, client: "test"), timeout: 5)
        let process = Launch.shell("/bin/sh", directory: "/tmp", environment: ["PATH": "/usr/bin:/bin"])
        guard case .created(let info)? = connection.requestAndWait(.create(TerminalSpec(terminal: UUID(), process: process, size: TerminalSize(columns: 80, rows: 24))), timeout: 5) else {
            Issue.record("create failed")
            return
        }
        connection.close()
        #expect(finished.wait(timeout: .now() + 8) == .success)
        #expect(eventually { kill(info.pid, 0) != 0 })
    }
}
