import Foundation
import TerminalHost
import WhiskrKit

/// How `paw` ends: each exit code means one thing, so an agent can act on it without reading.
public enum PawExit: Int32, Sendable {
    case ok = 0
    case failed = 1
    case usage = 2
    case notFound = 3
    /// Not inside the app's terminals, or the session host there is too old for `paw`.
    case noHost = 4
    case timedOut = 5
    /// The terminal waits for an answer (a permission, a question).
    case blocked = 6
    /// The terminal has ended.
    case exited = 7
    /// `send --wait`: the terminal showed no sign of taking the message in.
    case stalled = 8

    /// The app `paw` comes with, as its messages name it.
    public static let appName = "Whiskr"
}

/// Where `paw` writes and what it reads: the process's own streams, or a test's.
public struct PawIO: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    public var input: @Sendable () -> String

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void, input: @escaping @Sendable () -> String) {
        self.out = out
        self.err = err
        self.input = input
    }

    public static let standard = PawIO(
        out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        err: { FileHandle.standardError.write(Data(("paw: " + $0 + "\n").utf8)) },
        input: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) })
}

/// `paw` itself: reads its command line, talks to the session host it finds in its environment
/// (`PAW_SOCKET`, which the host sets in every terminal it starts), and says what happened.
public struct Paw: Sendable {
    let environment: [String: String]
    let currentFolder: String
    let io: PawIO

    public init(environment: [String: String], currentFolder: String, io: PawIO = .standard) {
        self.environment = environment
        self.currentFolder = currentFolder
        self.io = io
    }

    /// Runs `arguments` (without the program's name) and returns the exit code.
    public func run(_ arguments: [String]) -> Int32 {
        // Not a command of yours: the `claude` shim asks for your --settings with the pane's hooks added
        // (`merge-settings <hooks file> <yours>`), and gets the path of the merged file. When that cannot
        // be done, the one line said here is all the user hears of it.
        if arguments.first == "merge-settings" {
            guard arguments.count == 3 else {
                io.err("merge-settings takes the hooks file and your --settings")
                return PawExit.usage.rawValue
            }
            do {
                io.out(try HookSettings.mergedFile(hooks: arguments[1], with: arguments[2]))
                return PawExit.ok.rawValue
            } catch {
                io.err("\(PawExit.appName)'s hooks were not added to your --settings (\(error.reason)), so \(PawExit.appName) will not see this session")
                return PawExit.failed.rawValue
            }
        }
        let command: PawCommand
        do {
            command = try PawCommand.parse(arguments)
        } catch {
            io.err(error.message)
            return PawExit.usage.rawValue
        }
        switch command {
        case .help(let topic):
            guard let text = PawManual.help(topic) else {
                io.err("no help for \(topic ?? "")")
                return PawExit.usage.rawValue
            }
            io.out(text)
            return PawExit.ok.rawValue
        case .skill:
            io.out(PawManual.skill)
            return PawExit.ok.rawValue
        case .version:
            io.out("paw \(PawManual.version) (host protocol \(HostProtocol.version))")
            return PawExit.ok.rawValue
        default:
            break
        }
        do throws(PawFailure) {
            let session = try PawSession(environment: environment, io: io)
            defer { session.close() }
            return try Commands(session: session, paw: self).perform(command).rawValue
        } catch {
            io.err(error.message)
            return error.exit.rawValue
        }
    }
}

/// A failure, with the exit code it ends `paw` with.
struct PawFailure: Error {
    let exit: PawExit
    let message: String

    init(_ exit: PawExit, _ message: String) {
        self.exit = exit
        self.message = message
    }

    init(_ failure: HostFailure, target: String? = nil) {
        let message = failure.message.isEmpty ? failure.code.rawValue : failure.message
        switch failure.code {
        case .noSuchTerminal: self.init(.notFound, "no terminal \(target ?? "")".trimmingCharacters(in: .whitespaces))
        case .blocked: self.init(.blocked, message)
        case .exited: self.init(.exited, message)
        case .connectionLost: self.init(.noHost, "the session host went away")
        case .unknownRequest, .incompatible: self.init(.noHost, "the session host does not know this (\(message)); it is from an older \(PawExit.appName)")
        default: self.init(.failed, message)
        }
    }
}

/// One connection to the session host, greeted, with the terminals it holds at hand.
final class PawSession: @unchecked Sendable {
    let connection: HostConnection
    let host: HostInfo
    private let collected = Collected()
    /// The terminal `paw` runs in, when it is one of the host's.
    private(set) var caller: TerminalInfo?
    private(set) var terminals: [TerminalInfo] = []

    init(environment: [String: String], io: PawIO) throws(PawFailure) {
        guard let path = environment["PAW_SOCKET"], !path.isEmpty else {
            throw PawFailure(.noHost, "not inside a terminal of \(PawExit.appName) (PAW_SOCKET is not set)")
        }
        let collected = collected
        do {
            connection = try HostConnection(socketPath: path, handlers: HostConnection.Handlers(output: { _, bytes in collected.add(bytes) }))
        } catch {
            throw PawFailure(.noHost, "the session host is not running (\(path))")
        }
        guard case .hello(let info)? = connection.requestAndWait(.hello(HostProtocol.current, client: "paw"), timeout: 5) else {
            connection.close()
            throw PawFailure(.noHost, "the session host did not answer")
        }
        host = info
        guard HostProtocol.compatibility(client: HostProtocol.current, host: info.speaks) == .compatible else {
            connection.close()
            throw PawFailure(.noHost, "the session host speaks protocol \(info.version), which this paw cannot")
        }
        guard info.version >= HostProtocol.agents else {
            connection.close()
            throw PawFailure(.noHost, "the session host is from an older \(PawExit.appName) (protocol \(info.version)); terminals started after it is replaced (Quit and Stop All Terminals, or a restart) have paw")
        }
        try refresh()
        if let me = environment["PAW_ID"] { caller = terminals.first { $0.address == me && !$0.exited } }
    }

    func close() { connection.close() }

    /// Asks and waits for the answer (a little longer than any wait it asks for).
    func ask(_ request: HostRequest, waiting seconds: Double = 10) throws(PawFailure) -> HostReply {
        guard let reply = connection.requestAndWait(request, timeout: seconds + 10) else { throw PawFailure(.noHost, "the session host did not answer") }
        if case .failed(let failure) = reply, failure.code == .connectionLost { throw PawFailure(failure) }
        return reply
    }

    func refresh() throws(PawFailure) {
        guard case .list(let list) = try ask(.list) else { throw PawFailure(.failed, "the session host did not list its terminals") }
        terminals = list
    }

    /// A terminal by its address ("t4"), its name, or its id.
    func resolve(_ target: String) throws(PawFailure) -> TerminalInfo {
        let live = terminals.filter { !$0.exited }
        if let found = terminals.first(where: { $0.address == target }) ?? live.first(where: { $0.name == target })
            ?? terminals.first(where: { $0.name == target }) ?? UUID(uuidString: target).flatMap({ id in terminals.first { $0.id == id } }) {
            return found
        }
        throw PawFailure(.notFound, "no terminal \(target) (paw ls lists them)")
    }

    func info(_ id: UUID?) -> TerminalInfo? { id.flatMap { id in terminals.first { $0.id == id } } }

    /// The bytes of a `read`: they follow its answer on the connection.
    func readBytes(_ count: Int) -> Data { collected.take(count, within: 5) }
}

/// Output frames as they arrive on the connection's thread, for `read`.
private final class Collected: @unchecked Sendable {
    private let lock = NSCondition()
    private var bytes = Data()

    func add(_ data: Data) {
        lock.lock()
        bytes.append(data)
        lock.broadcast()
        lock.unlock()
    }

    func take(_ count: Int, within seconds: TimeInterval) -> Data {
        let deadline = Date().addingTimeInterval(seconds)
        lock.lock()
        defer { lock.unlock() }
        while bytes.count < count, lock.wait(until: deadline) {}
        let taken = bytes.prefix(count)
        bytes.removeFirst(taken.count)
        return Data(taken)
    }
}
