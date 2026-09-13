import Darwin
import Foundation
import WhiskrKit

/// One terminal the host holds: its pseudo-terminal and the program on it, the output kept for whoever
/// attaches later, and the clients watching it now. It lives as long as its program does, whoever is
/// or is not connected.
///
/// It also reads what its program says of itself (OSC 7501: working, blocked, idle), answering the
/// program's question whether anyone listens, and notes when a person last typed into it, so that
/// nothing is pasted into a half-written message (`AgentDesk`).
///
/// Used only on the host's queue, which is what makes the unchecked Sendable sound.
final class HostedTerminal: @unchecked Sendable {
    let id: UUID
    let pid: pid_t
    /// What it was started with: a terminal started from this one (`paw run`) starts the same shell.
    let spec: TerminalSpec
    /// The short name it is reached by ("t4"), and the one it was given, if any.
    let address: String
    let name: String?
    let origin: TerminalOrigin?
    private let descriptor: Int32
    private let queue: DispatchQueue
    private(set) var size: TerminalSize
    private var history = ReplayBuffer()
    private(set) var modes = TerminalModes()
    private var status = TerminalStatus()
    private var scanner = ProgramStatusScanner()
    /// What it printed, as text, while something waits for text (`watchText`).
    private var text: OutputText?
    private(set) var exited = false
    private(set) var exitedAt: Date?
    private var exitCode: Int32?
    /// Asked to close; `ending` once its programs have been told to end.
    private(set) var closing = false
    private var ending = false
    /// A client has been told it ended, so the record need not be kept for a later one.
    private(set) var exitSeen = false
    private(set) var viewers: [ClientLink] = []

    /// When it last printed anything, and whether its shell has said its prompt is up (OSC 7).
    private(set) var lastOutput: Date?
    private(set) var sawPrompt = false
    /// When a person last typed into it, and whether what they typed is still unsent (no Return since).
    private(set) var lastTyped: Date?
    private(set) var draftOpen = false

    private var reading: DispatchSourceRead?
    private var readingPaused = false
    private var watching: DispatchSourceProcess?
    private let writer: DescriptorWriter
    private var closeTimer: DispatchSourceTimer?
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    /// Empty once nothing watches the descriptor any more: only then may it be closed.
    private let unwatched = DispatchGroup()
    /// Called once, when the program has ended and all its output has been read.
    var onExit: ((HostedTerminal) -> Void)?
    /// Its program's report changed (or went with it).
    var onReport: ((HostedTerminal) -> Void)?
    /// It printed something (only while `watchText` or the host's agent work wants to know).
    var onOutput: ((HostedTerminal) -> Void)?
    /// Whether the host should answer the program's probe for status reports itself: when no viewer
    /// attached will (a v1 app's terminal answers it; a v2 app's leaves it to the host).
    var answersProbes: () -> Bool = { true }

    init(_ spec: TerminalSpec, address: String, name: String? = nil, origin: TerminalOrigin? = nil, queue: DispatchQueue) throws(HostFailure) {
        let started = try PseudoTerminal.start(spec)
        id = spec.terminal
        pid = started.pid
        self.spec = spec
        self.address = address
        self.name = name
        self.origin = origin
        descriptor = started.descriptor
        size = spec.size
        self.queue = queue
        writer = DescriptorWriter(fd: started.descriptor, queue: queue)
        status.folder = spec.directory
        history.resized(to: spec.size)

        let reading = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reading.setEventHandler { [weak self] in self?.read(rounds: 8) }
        unwatched.enter()
        reading.setCancelHandler { [unwatched] in unwatched.leave() }
        reading.resume()
        self.reading = reading
        let watching = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        watching.setEventHandler { [weak self] in self?.programEnded() }
        watching.resume()
        self.watching = watching
    }

    var info: TerminalInfo {
        TerminalInfo(id: id, pid: pid, size: size, status: status, exited: exited, exitCode: exitCode, closing: closing,
                     address: address, name: name, origin: origin, directory: spec.directory)
    }

    /// "t4 review", or "t4".
    var label: String { info.label }

    var report: ProgramReport? { status.program }

    // MARK: Output

    /// Takes what the program has printed: kept for later, and passed to everyone watching, as one piece
    /// for all that could be read now (`OutputBatch`): a pseudo-terminal gives at most a kilobyte a read.
    private func read(rounds: Int) {
        var batch = OutputBatch()
        // Before anything else is said about the terminal (a status, its end), what it printed first.
        func pass() {
            if let ready = batch.take() { for viewer in viewers { viewer.send(.output(terminal: ready.0, ready.1)) } }
        }
        defer { pass() }
        for _ in 0..<rounds {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let data = Data(chunk[0..<count])
                history.append(data)
                modes.scan(data)
                if let ready = batch.add(data, for: id) { for viewer in viewers { viewer.send(.output(terminal: ready.0, ready.1)) } }
                lastOutput = Date()
                text?.append(data)
                let findings = scanner.scan(data)
                if !findings.isEmpty { pass() }
                for finding in findings { take(finding) }
                onOutput?(self)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                // Nothing more for now; or the last program holding the terminal has gone.
                pass()
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { stopReading() }
                return
            }
        }
    }

    private func take(_ finding: ProgramStatusScanner.Finding) {
        switch finding {
        case .probe(let reply):
            if answersProbes() { writer.write(reply) }
        case .prompt:
            sawPrompt = true
        case .report(let fields):
            let next = ProgramReport.next(after: status.program, fields: fields)
            guard next != status.program else { return }
            status.program = next
            tellStatus()
            onReport?(self)
        }
    }

    private func stopReading() {
        guard let reading else { return }
        self.reading = nil
        if readingPaused { reading.resume() }
        reading.cancel()
    }

    /// A viewer that cannot keep up stops the reading, and so, in time, the program: the same
    /// backpressure a slow terminal gives. With nobody watching the output only fills the history.
    func viewersChangedPace() {
        let pause = viewers.contains(where: \.congested)
        guard pause != readingPaused, let reading else { return }
        readingPaused = pause
        if pause { reading.suspend() } else { reading.resume() }
    }

    /// The kept output as it would be replayed, for reading the screen without attaching.
    func snapshot() -> (bytes: Data, truncated: Bool) {
        var replay = history.replay
        guard history.truncated else { return (replay, false) }
        // The size first (a viewer resizes for it, which may reset modes), then the modes, then the lines.
        var bytes = Data()
        if let first = ReplaySize.split(replay).first, first.size != nil, let end = replay.firstIndex(of: 0x07) {
            bytes.append(replay.subdata(in: replay.startIndex..<end + 1))
            replay = replay.subdata(in: end + 1..<replay.endIndex)
        }
        bytes.append(modes.restoring)
        bytes.append(replay)
        return (bytes, true)
    }

    /// Starts keeping its output as text, beginning with the last of what it has printed already.
    func watchText() {
        guard text == nil else { return }
        var kept = OutputText()
        let replay = history.replay
        kept.append(replay.count > 256 * 1024 ? replay.suffix(256 * 1024) : replay)
        text = kept
    }

    func stopWatchingText() { text = nil }

    func printed(_ needle: String) -> Bool { text?.contains(needle) ?? false }

    // MARK: Viewers

    /// Adds a viewer; returns what to send it first so its terminal shows what this one does.
    func attach(_ viewer: ClientLink) -> (replay: Data, truncated: Bool) {
        if !viewers.contains(where: { $0 === viewer }) { viewers.append(viewer) }
        look()
        if exited { exitSeen = true }
        let kept = snapshot()
        return (kept.bytes, kept.truncated)
    }

    func detach(_ viewer: ClientLink) {
        viewers.removeAll { $0 === viewer }
        viewersChangedPace()
    }

    // MARK: Input

    /// What a person typed (through a client): kept track of, so a message never lands in their draft.
    func type(_ bytes: Data) {
        guard !exited else { return }
        lastTyped = Date()
        if bytes.contains(0x0D) || bytes.contains(0x0A) || bytes.contains(0x03) {
            draftOpen = false
        } else if bytes.contains(where: { $0 >= 0x20 && $0 != 0x7F }) {
            draftOpen = true
        }
        writer.write(bytes)
    }

    /// What the host types on a program's behalf (a message, a task, keys).
    func typeForAgent(_ bytes: Data) {
        guard !exited else { return }
        writer.write(bytes)
    }

    /// Text as a paste: between markers when the program asked for them, so its lines are not each
    /// taken as Return.
    func paste(_ text: String) {
        var bytes = Data()
        if modes.bracketedPaste { bytes.append(contentsOf: Array("\u{1B}[200~".utf8)) }
        bytes.append(contentsOf: Array(text.utf8))
        if modes.bracketedPaste { bytes.append(contentsOf: Array("\u{1B}[201~".utf8)) }
        typeForAgent(bytes)
    }

    func resize(to size: TerminalSize) {
        guard !exited, size.columns > 0, size.rows > 0 else { return }
        self.size = size
        history.resized(to: size)
        PseudoTerminal.resize(descriptor, to: size)
    }

    /// Makes the program in front draw everything again: programs redraw when their terminal's size
    /// changes, so it is made one row taller for a moment.
    func redraw() {
        guard !exited else { return }
        var taller = size
        taller.rows += 1
        PseudoTerminal.resize(descriptor, to: taller)
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.exited else { return }
            PseudoTerminal.resize(self.descriptor, to: self.size)
        }
    }

    func signal(_ number: Int32) {
        guard !exited else { return }
        let front = ProcessControl.foregroundGroup(terminalFD: descriptor)
        killpg(front > 0 ? front : pid, number)
    }

    // MARK: Status

    /// Something other than its shell is in front now (asked of the terminal, not remembered).
    var programInFront: Bool {
        guard !exited else { return false }
        let group = ProcessControl.foregroundGroup(terminalFD: descriptor)
        return group > 0 && group != pid
    }

    /// Its program reports its own status and is still in front: what a message to an agent needs
    /// before it is typed (a report outlives no program: back at the shell, it is gone).
    var isAgentNow: Bool {
        guard status.program != nil else { return false }
        if programInFront { return true }
        forgetReport()
        return false
    }

    /// Looks at what is in the terminal's foreground and where its shell is; tells the viewers when
    /// either changed. The program's report goes once its shell is back in front.
    func look() {
        guard !exited else { return }
        let group = ProcessControl.foregroundGroup(terminalFD: descriptor)
        var front: ForegroundProcess?
        if group > 0, group != pid {
            // The same process can become another program (a wrapper script that execs the real one).
            let name = ProcessControl.name(of: group) ?? ""
            if let known = status.foreground, known.pid == group, known.name == name {
                front = known
            } else {
                front = ForegroundProcess(pid: group, name: name, executable: ProcessControl.executablePath(of: group) ?? "",
                                          arguments: ProcessControl.arguments(of: group))
            }
        }
        var next = TerminalStatus(foreground: front, folder: ProcessControl.currentDirectory(of: pid) ?? status.folder, program: status.program)
        if front == nil, group == pid { next.program = nil }
        guard next != status else { return }
        let reportChanged = next.program != status.program
        status = next
        tellStatus()
        if reportChanged { onReport?(self) }
    }

    private func forgetReport() {
        guard status.program != nil else { return }
        status.program = nil
        tellStatus()
        onReport?(self)
    }

    private func tellStatus() {
        for viewer in viewers { viewer.send(.message(.event(.status(terminal: id, status)))) }
    }

    // MARK: Ending

    /// Ends everything in the terminal `delay` seconds from now, unless `keep` comes first.
    func close(after delay: TimeInterval) {
        guard !ending else { return }
        closing = true
        closeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(delay, 0))
        timer.setEventHandler { [weak self] in self?.end() }
        timer.resume()
        closeTimer = timer
    }

    /// Takes a close back; false when its programs have already been told to end.
    func keep() -> Bool {
        guard !ending else { return false }
        closeTimer?.cancel()
        closeTimer = nil
        closing = false
        return true
    }

    /// Asks everything in the terminal to end, as closing a terminal window does, then kills what is
    /// left a moment later.
    func end() {
        closing = true
        guard !ending else { return }
        ending = true
        closeTimer?.cancel()
        closeTimer = nil
        guard !exited else { return }
        ProcessControl.hangUp(shell: pid, terminalFD: descriptor)
        queue.asyncAfter(deadline: .now() + HostLifecycle.killGrace) { [weak self] in self?.kill() }
    }

    /// Kills whatever is still in the terminal's session.
    func kill() {
        // Only while the shell lives is its session's number certainly its own.
        guard !exited else { return }
        ProcessControl.killSession(pid)
    }

    private func programEnded() {
        guard !exited else { return }
        // Whatever it printed last.
        if reading != nil { read(rounds: 64) }
        stopReading()
        // A terminal being closed takes its stragglers with it. Done before the shell is reaped, while
        // its process (and so its session's number) cannot have been given to anyone else.
        if ending { ProcessControl.killSession(pid) }
        var state: Int32 = 0
        while waitpid(pid, &state, 0) < 0, errno == EINTR {}
        exited = true
        exitedAt = Date()
        exitCode = state & 0x7F == 0 ? (state >> 8) & 0xFF : nil
        status.foreground = nil
        status.program = nil
        watching?.cancel()
        watching = nil
        exitSeen = !viewers.isEmpty
        for viewer in viewers { viewer.send(.message(.event(.exited(terminal: id, exitCode: exitCode)))) }
        onExit?(self)
    }

    /// A client has heard how it ended (`paw wait`, `paw ls`), as a viewer would have.
    func noteExitSeen() {
        if exited { exitSeen = true }
    }

    /// Lets go of the pseudo-terminal. Called once, when the host forgets the terminal.
    func dispose() {
        closeTimer?.cancel()
        closeTimer = nil
        watching?.cancel()
        watching = nil
        viewers = []
        stopReading()
        unwatched.enter()
        writer.cancel { [unwatched] in unwatched.leave() }
        unwatched.notify(queue: queue) { [descriptor] in Darwin.close(descriptor) }
    }
}
