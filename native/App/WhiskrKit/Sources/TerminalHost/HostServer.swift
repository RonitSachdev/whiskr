import Darwin
import Foundation
import WhiskrKit

/// The session host: listens on its socket, holds the terminals, and does what connected clients ask
/// (`HostProtocol`). It runs in a small process of its own (`HostMain`), started by the app and left
/// running when the app goes; with no terminal running and no client connected it exits by itself.
///
/// Everything here runs on one serial queue, which is what makes the unchecked Sendable sound.
public final class HostServer: @unchecked Sendable {
    public struct Options: Sendable {
        public var socket: HostSocket
        /// The app version this host was built with, for people reading `hello`.
        public var build: String
        public var idleGrace: TimeInterval
        /// Test runs: leave, ending every terminal, once no client has been connected this long.
        public var abandonedAfter: TimeInterval?
        /// The protocol versions it speaks: this build's, except in tests of how versions meet.
        public var speaks: HostVersion

        public init(socket: HostSocket, build: String, idleGrace: TimeInterval = HostLifecycle.idleGrace, abandonedAfter: TimeInterval? = nil,
                    speaks: HostVersion = HostProtocol.current) {
            self.socket = socket
            self.build = build
            self.idleGrace = idleGrace
            self.abandonedAfter = abandonedAfter
            self.speaks = speaks
        }
    }

    public enum StartFailure: Error {
        /// Another host holds this socket's lock.
        case alreadyRunning
        case socket(String)
    }

    private let options: Options
    /// At the priority of the typing it carries: a keystroke and its echo each pass through here.
    private let queue = DispatchQueue(label: "app.whiskr.host", qos: .userInteractive)
    private var lock: Int32 = -1
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var links: [ClientLink] = []
    private var terminals: [UUID: HostedTerminal] = [:]
    private var looking: DispatchSourceTimer?
    private var lookingPaused = true
    private var leaving: DispatchSourceTimer?
    private var lastClient = Date()
    private var lastTerminal = Date()
    private var stopped = false
    /// The number in the next address given ("t1", "t2", …): never reused while the host runs.
    private var nextAddress = 1
    /// Agents starting and steering agents: helpers' first tasks, messages, notes, waits.
    private lazy var desk: AgentDesk = {
        let desk = AgentDesk(terminal: { [unowned self] in terminals[$0] }, allTerminals: { [unowned self] in Array(terminals.values) },
                             passed: { [unowned self] message in
                                 for link in links where link.subscribed { link.send(.message(.event(.passed(message)))) }
                             })
        desk.afterGap = { [queue] seconds, work in queue.asyncAfter(deadline: .now() + seconds, execute: work) }
        return desk
    }()
    /// How long a terminal a program started is remembered after it ended, for `paw wait` and `paw ls`.
    static let endedKept: TimeInterval = 300
    /// Called once, on the host's queue, when the host has nothing left to do: its process exits.
    private let onFinished: @Sendable () -> Void
    private let log: @Sendable (String) -> Void

    public init(options: Options, log: @escaping @Sendable (String) -> Void = { _ in }, onFinished: @escaping @Sendable () -> Void) {
        self.options = options
        self.log = log
        self.onFinished = onFinished
    }

    // MARK: Starting and stopping

    /// Takes the socket's lock and starts listening. Throws `alreadyRunning` when another host has it.
    public func start() throws {
        try queue.sync {
            let socket = options.socket
            do {
                try UnixSocket.makePrivateFolder(URL(fileURLWithPath: socket.lock).deletingLastPathComponent().path)
                try UnixSocket.makePrivateFolder(URL(fileURLWithPath: socket.path).deletingLastPathComponent().path)
            } catch {
                throw StartFailure.socket("\(error)")
            }
            lock = open(socket.lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw StartFailure.socket("lock: \(String(cString: strerror(errno)))") }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                close(lock)
                lock = -1
                throw StartFailure.alreadyRunning
            }
            do {
                listener = try UnixSocket.listen(at: socket.path)
            } catch {
                throw StartFailure.socket("\(error)")
            }
            let accepting = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            accepting.setEventHandler { [weak self] in self?.accept() }
            accepting.resume()
            self.accepting = accepting

            let looking = DispatchSource.makeTimerSource(queue: queue)
            looking.schedule(deadline: .now() + HostLifecycle.lookInterval, repeating: HostLifecycle.lookInterval, leeway: .milliseconds(20))
            looking.setEventHandler { [weak self] in self?.look() }
            self.looking = looking
            considerLeaving()
            log("listening on \(socket.path), protocol \(options.speaks.version)")
        }
    }

    /// Ends every terminal (a hang-up, then a kill for what ignored it) and finishes. For SIGTERM, and
    /// for tests.
    public func stop() {
        queue.async { self.shutDown(then: nil) }
    }

    private func shutDown(then answer: (@Sendable () -> Void)?) {
        guard !stopped else {
            answer?()
            return
        }
        stopped = true
        log("stopping \(terminals.values.filter { !$0.exited }.count) terminals")
        accepting?.cancel()
        accepting = nil
        unlink(options.socket.path)
        for terminal in terminals.values { terminal.end() }
        let deadline = Date().addingTimeInterval(HostLifecycle.shutdownGrace)
        waitForTerminals(until: deadline) { [self] in
            for terminal in terminals.values { terminal.kill() }
            answer?()
            // The answer is on its way out before the process goes.
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                for link in links { link.close() }
                looking?.cancel()
                if lookingPaused { looking?.resume() }
                leaving?.cancel()
                onFinished()
            }
        }
    }

    private func waitForTerminals(until deadline: Date, then done: @escaping @Sendable () -> Void) {
        if Date() >= deadline || terminals.values.allSatisfy(\.exited) { return done() }
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in waitForTerminals(until: deadline, then: done) }
    }

    // MARK: Leaving by itself

    /// Arms the timer for the moment the host would exit if nothing changes (`HostLifecycle`).
    private func considerLeaving() {
        leaving?.cancel()
        leaving = nil
        guard !stopped else { return }
        let running = terminals.values.filter { !$0.exited }.count
        guard let delay = HostLifecycle.exitDelay(runningTerminals: running, clients: links.count, lastClient: lastClient, lastTerminal: lastTerminal,
                                                  now: Date(), idleGrace: options.idleGrace, abandonedAfter: options.abandonedAfter) else { return }
        if delay == 0 {
            log(running == 0 ? "idle: leaving" : "abandoned with \(running) terminals: leaving")
            return shutDown(then: nil)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.considerLeaving() }
        timer.resume()
        leaving = timer
    }

    // MARK: Connections

    private func accept() {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard UnixSocket.peerIsSameUser(fd) else {
                close(fd)
                continue
            }
            UnixSocket.prepare(fd)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let link = ClientLink(fd: fd, queue: queue)
            link.onFrame = { [weak self] link, frame in self?.handle(frame, from: link) }
            link.onPace = { [weak self] link in
                for id in link.attached { self?.terminals[id]?.viewersChangedPace() }
            }
            link.onClosed = { [weak self] link in self?.closed(link) }
            links.append(link)
            link.start()
            updateLooking()
            considerLeaving()
        }
    }

    private func closed(_ link: ClientLink) {
        links.removeAll { $0 === link }
        desk.dropWaits(of: ObjectIdentifier(link))
        for id in link.attached {
            guard let terminal = terminals[id] else { continue }
            terminal.detach(link)
            forgetIfDone(terminal)
        }
        lastClient = Date()
        updateLooking()
        considerLeaving()
    }

    // MARK: Requests

    private func handle(_ frame: HostFrame, from link: ClientLink) {
        switch frame {
        case .input(let id, let bytes):
            if link.greeted { terminals[id]?.type(bytes) }
        case .output:
            break
        case .message(let json):
            guard let call = try? JSONDecoder().decode(HostCall.self, from: json) else { return link.close() }
            answer(call, from: link)
        }
    }

    private func answer(_ call: HostCall, from link: ClientLink) {
        @Sendable func reply(_ reply: HostReply) { link.send(.message(.reply(id: call.id, reply))) }
        if case .hello(let speaks, let client) = call.request {
            link.greeted = HostProtocol.compatibility(client: speaks, host: options.speaks) == .compatible
            link.spoken = HostProtocol.spoken(client: speaks, host: options.speaks)
            if !link.greeted { log("a client (\(client)) speaks protocol \(speaks.version), not ours") }
            return reply(.hello(HostInfo(version: options.speaks.version, oldest: options.speaks.oldest, build: options.build, pid: getpid(),
                                         terminals: terminals.values.filter { !$0.exited }.count)))
        }
        guard link.greeted else { return reply(.failed(HostFailure(.incompatible, "say hello first"))) }
        // Only what both sides speak: a request from a newer version than this conversation's is unknown.
        guard call.introducedIn <= link.spoken else { return reply(.failed(HostFailure(.unknownRequest, "not in protocol \(link.spoken)"))) }
        func terminal(_ id: UUID) -> HostedTerminal? {
            if let terminal = terminals[id] { return terminal }
            reply(.failed(HostFailure(.noSuchTerminal)))
            return nil
        }
        switch call.request {
        case .hello:
            break
        case .create(let spec):
            guard terminals[spec.terminal] == nil else { return reply(.failed(HostFailure(.terminalExists))) }
            guard !stopped else { return reply(.failed(HostFailure(.launchFailed, "the host is stopping"))) }
            do {
                let terminal = try start(spec, name: nil, origin: nil)
                link.attached.insert(spec.terminal)
                _ = terminal.attach(link)
                updateLooking()
                reply(.created(terminal.info))
            } catch {
                reply(.failed(error))
            }
        case .run(let request):
            run(request, reply: reply)
        case .send(let request):
            desk.send(request) { reply($0) }
        case .keys(let id, let names):
            guard let terminal = terminal(id) else { return }
            guard !terminal.exited else { return reply(.failed(HostFailure(.exited, "\(terminal.label) has ended"))) }
            guard let bytes = TerminalKeys.encode(names, applicationCursor: terminal.modes.applicationCursorKeys) else {
                let unknown = names.filter { TerminalKeys.encode($0) == nil }
                return reply(.failed(HostFailure(.invalid, "unknown key: \(unknown.joined(separator: ", "))")))
            }
            terminal.typeForAgent(bytes)
            reply(.done)
        case .interrupt(let id):
            guard let terminal = terminal(id) else { return }
            guard !terminal.exited else { return reply(.failed(HostFailure(.exited, "\(terminal.label) has ended"))) }
            // Esc stops an agent's turn (Claude Code's own key); ⌃C stops anything else.
            terminal.typeForAgent(Data([terminal.isAgentNow ? 0x1B : 0x03]))
            reply(.done)
        case .wait(let request):
            desk.wait(request, link: ObjectIdentifier(link)) { reply($0) }
            updateLooking()
        case .read(let id):
            guard let terminal = terminal(id) else { return }
            let (bytes, truncated) = terminal.snapshot()
            terminal.noteExitSeen()
            reply(.snapshot(terminal.info, bytes: bytes.count, truncated: truncated))
            if !bytes.isEmpty { link.send(.output(terminal: id, bytes)) }
        case .subscribe:
            link.subscribed = true
            reply(.done)
        case .attach(let id):
            guard let terminal = terminal(id) else { return }
            link.attached.insert(id)
            let (replay, truncated) = terminal.attach(link)
            updateLooking()
            reply(.attached(terminal.info, replay: replay.count, truncated: truncated))
            if !replay.isEmpty { link.send(.output(terminal: id, replay)) }
            if terminal.exited { link.send(.message(.event(.exited(terminal: id, exitCode: terminal.info.exitCode)))) }
        case .detach(let id):
            guard let terminal = terminal(id) else { return }
            link.attached.remove(id)
            terminal.detach(link)
            updateLooking()
            reply(.done)
            forgetIfDone(terminal)
        case .resize(let id, let size):
            guard let terminal = terminal(id) else { return }
            terminal.resize(to: size)
            reply(.done)
        case .redraw(let id):
            guard let terminal = terminal(id) else { return }
            terminal.redraw()
            reply(.done)
        case .signal(let id, let number):
            guard let terminal = terminal(id) else { return }
            terminal.signal(number)
            reply(.done)
        case .close(let id, let after):
            guard let terminal = terminal(id) else { return }
            // A helper that has ended by itself is kept a while for `paw wait` and `paw read`, even when
            // the app lets go of its tab.
            if terminal.exited, terminal.origin != nil, !terminal.closing { return reply(.done) }
            terminal.close(after: after)
            reply(.done)
            forgetIfDone(terminal)
        case .keep(let id):
            guard let terminal = terminal(id) else { return }
            reply(terminal.keep() ? .done : .failed(HostFailure(.noSuchTerminal, "already ending")))
        case .list:
            for terminal in terminals.values { terminal.look() }
            reply(.list(terminals.values.map(\.info).sorted { $0.id.uuidString < $1.id.uuidString }))
        case .shutdown:
            log("asked to stop")
            shutDown { reply(.done) }
        case .unknown(let op):
            reply(.failed(HostFailure(.unknownRequest, op)))
        }
    }

    // MARK: Terminals

    /// Starts a terminal: given its address, and told who it is (`paw` reads these), in protocol 2.
    private func start(_ spec: TerminalSpec, name: String?, origin: TerminalOrigin?) throws(HostFailure) -> HostedTerminal {
        var spec = spec
        let address = "t\(nextAddress)"
        if options.speaks.version >= HostProtocol.agents {
            for key in Array(spec.environment.keys) where key.hasPrefix("PAW_") && key != AgentText.taskVariable { spec.environment[key] = nil }
            spec.environment[Self.addressVariable] = address
            spec.environment[Self.socketVariable] = options.socket.path
            if let name { spec.environment[Self.nameVariable] = name }
            if let parent = origin?.parent.flatMap({ terminals[$0] }) { spec.environment[Self.parentVariable] = parent.address }
        }
        let terminal = try HostedTerminal(spec, address: address, name: name, origin: origin, queue: queue)
        nextAddress += 1
        terminal.onExit = { [weak self] terminal in self?.ended(terminal) }
        terminal.onReport = { [weak self] terminal in self?.desk.changed(terminal) }
        terminal.onOutput = { [weak self] terminal in
            guard let self, self.desk.isBusy else { return }
            self.desk.changed(terminal)
        }
        let speaks = options.speaks.version
        terminal.answersProbes = { [weak terminal] in
            speaks >= HostProtocol.agents && (terminal?.viewers.allSatisfy { $0.spoken >= HostProtocol.agents } ?? true)
        }
        terminals[spec.terminal] = terminal
        considerLeaving()
        return terminal
    }

    /// What every terminal is told of itself (protocol 2): its address, the host's socket, its name and
    /// its parent's address.
    static let addressVariable = "PAW_ID"
    static let socketVariable = "PAW_SOCKET"
    static let nameVariable = "PAW_NAME"
    static let parentVariable = "PAW_PARENT"

    /// `paw run`: a terminal started from another, with the other's shell and environment (so it is a
    /// terminal like any of the app's: `claude` in it reports to the app), its command typed once its
    /// prompt is up and its task handed over once the program is ready (`AgentDesk`).
    private func run(_ request: RunRequest, reply: @escaping @Sendable (HostReply) -> Void) {
        guard terminals[request.terminal] == nil else { return reply(.failed(HostFailure(.terminalExists))) }
        guard !stopped else { return reply(.failed(HostFailure(.launchFailed, "the host is stopping"))) }
        if let name = request.name {
            guard AgentText.isValidName(name) else {
                return reply(.failed(HostFailure(.invalid, "a name is a lower-case letter, then letters, digits, - or _ (at most 32)")))
            }
            if let taken = terminals.values.first(where: { $0.name == name && !$0.exited }) {
                return reply(.failed(HostFailure(.invalid, "the name \(name) is taken by \(taken.address)")))
            }
        }
        let parent = request.parent.flatMap { terminals[$0] }
        var process: ProcessSpec
        if let parent {
            let base = parent.spec
            process = ProcessSpec(executable: base.executable, arguments: base.arguments, argv0: base.argv0, environment: base.environment, directory: request.directory)
        } else {
            let environment = Launch.withoutNoise(request.environment)
            let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
            process = Launch.shell(shell, directory: request.directory, environment: environment)
        }
        // Its own identity: the app's hooks know a terminal by this.
        process.environment[ShellIntegration.Key.pane] = request.terminal.uuidString
        process.environment[AgentText.taskVariable] = nil
        if let task = request.task, let command = request.command, AgentText.delivery(for: command) == .argument {
            process.environment[AgentText.taskVariable] = task
        }
        let size = request.size ?? parent?.size ?? TerminalSize(columns: 100, rows: 30)
        let origin = TerminalOrigin(parent: parent?.id, background: request.background, outlivesParent: request.outlivesParent,
                                    notifiesParent: request.notifiesParent)
        do {
            let terminal = try start(TerminalSpec(terminal: request.terminal, process: process, size: size), name: request.name, origin: origin)
            log("\(terminal.address) started by \(parent?.address ?? "a client")")
            desk.started(terminal.id, command: request.command, task: request.task, parent: parent?.id, endsWithProgram: request.background)
            updateLooking()
            reply(.created(terminal.info))
            for link in links where link.subscribed { link.send(.message(.event(.added(terminal.info)))) }
        } catch {
            reply(.failed(error))
        }
    }

    private func ended(_ terminal: HostedTerminal) {
        lastTerminal = Date()
        // Helpers end with whoever started them, unless told to outlive it.
        for child in terminals.values where child.origin?.parent == terminal.id && child.origin?.outlivesParent == false && !child.exited {
            log("\(child.address) ends with \(terminal.address)")
            child.end()
        }
        desk.changed(terminal)
        forgetIfDone(terminal)
        if terminal.origin != nil {
            // Remembered a while for `paw wait` and `paw ls`, then let go even if nobody looked.
            queue.asyncAfter(deadline: .now() + Self.endedKept) { [weak self, weak terminal] in
                guard let self, let terminal, self.terminals[terminal.id] === terminal, terminal.viewers.isEmpty else { return }
                self.forget(terminal)
            }
        }
        updateLooking()
        considerLeaving()
    }

    /// A terminal that has ended is forgotten once it was closed, or once a client has seen it end and
    /// none is watching; until then a window that attaches can still show how it ended.
    /// One a program started is kept (for `paw wait` and `paw ls`) until it was closed, or `endedKept` has
    /// passed with nobody watching it.
    private func forgetIfDone(_ terminal: HostedTerminal) {
        guard terminal.exited, terminal.closing || (terminal.origin == nil && terminal.exitSeen && terminal.viewers.isEmpty) else { return }
        forget(terminal)
    }

    private func forget(_ terminal: HostedTerminal) {
        for link in terminal.viewers { link.attached.remove(terminal.id) }
        terminals[terminal.id] = nil
        terminal.dispose()
        desk.forget(terminal.id)
    }

    /// The foreground of every terminal, ten times a second, and the agents' work that waits on the
    /// clock; nothing while no client is connected and no agent work is pending.
    private func look() {
        for terminal in terminals.values where !terminal.exited { terminal.look() }
        if desk.isBusy { desk.tick() }
        updateLooking()
    }

    private func updateLooking() {
        let live = terminals.values.contains { !$0.exited }
        let pause = !(live && !links.isEmpty) && !desk.isBusy
        guard pause != lookingPaused else { return }
        lookingPaused = pause
        if pause { looking?.suspend() } else { looking?.resume() }
    }
}

/// One connected client, on the host's side.
final class ClientLink: @unchecked Sendable {
    /// Past this much unsent output a client is not keeping up; below a quarter of it, it is again.
    static let congestedBacklog = 1024 * 1024

    private let fd: Int32
    private let queue: DispatchQueue
    private var decoder = HostFrameDecoder()
    private let writer: DescriptorWriter
    private var reading: DispatchSourceRead?
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    private var closed = false
    /// It said `hello` in a protocol this host speaks, and the version the two speak together.
    var greeted = false
    var spoken = 1
    /// It asked to hear of terminals programs start and messages passed (`subscribe`).
    var subscribed = false
    var attached: Set<UUID> = []
    private(set) var congested = false
    var onFrame: ((ClientLink, HostFrame) -> Void)?
    var onPace: ((ClientLink) -> Void)?
    var onClosed: ((ClientLink) -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        writer = DescriptorWriter(fd: fd, queue: queue)
    }

    func start() {
        writer.onFailure = { [weak self] in self?.close() }
        writer.onBacklog = { [weak self] in self?.paceChanged() }
        let reading = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reading.setEventHandler { [weak self] in self?.read() }
        reading.setCancelHandler { [writer, fd] in writer.cancel { Darwin.close(fd) } }
        reading.resume()
        self.reading = reading
    }

    func send(_ frame: HostFrame) {
        guard !closed else { return }
        writer.write(frame.encoded)
    }

    private func paceChanged() {
        let now = congested ? writer.backlog > Self.congestedBacklog / 4 : writer.backlog > Self.congestedBacklog
        guard now != congested else { return }
        congested = now
        onPace?(self)
    }

    private func read() {
        for _ in 0..<8 {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                chunk.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
                do {
                    while !closed, let frame = try decoder.next() { onFrame?(self, frame) }
                } catch {
                    return close()
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { close() }
                return
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        congested = false
        reading?.cancel()
        reading = nil
        onClosed?(self)
    }
}
