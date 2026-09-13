import Darwin
import Foundation
import WhiskrKit

/// Finds the session host for an app, starting one when none is running. The host is started as a
/// process of its own, in its own session, with nothing of the app's but its environment: it is not
/// the app's to end, and it stays when the app quits, crashes or is replaced by an update.
public struct HostLauncher: Sendable {
    public struct Found: Sendable {
        public let socket: HostSocket
        public let info: HostInfo
        /// Running terminals held by hosts this app cannot talk to (another version's), left alone.
        public let strangers: Int
    }

    public enum Failure: Error, Equatable {
        /// Every socket is held by a host of another version.
        case onlyStrangers(terminals: Int)
        case couldNotStart(String)
    }

    public let places: HostPlaces
    /// The host's executable, inside the app.
    public let executable: URL
    /// The app's version, which the host reports as its build.
    public let build: String
    /// Further arguments for a host this launcher starts (test runs).
    public let extraArguments: [String]
    /// Where a host of the app's earlier name may still be running (`HostPlaces.legacy`). Never used: its
    /// terminals rely on that app's own support folder. They are counted with the strangers, left alone.
    public let legacyPlaces: HostPlaces?

    /// How long a host gets to answer `hello`, and to come up after being started.
    static let answerTimeout: TimeInterval = 2
    static let startTimeout: TimeInterval = 5

    public init(places: HostPlaces, executable: URL, build: String, extraArguments: [String] = [], legacyPlaces: HostPlaces? = nil) {
        self.places = places
        self.executable = executable
        self.build = build
        self.extraArguments = extraArguments
        self.legacyPlaces = legacyPlaces
    }

    /// The host to use, started first if need be. Waits on the host; not for the main thread.
    public func find() throws(Failure) -> Found {
        let primary = Self.probe(places.primary)
        let alternateSocket = places.alternate(for: HostProtocol.version)
        // The alternate matters only when the primary cannot be used as it is.
        let alternate = primary.probe == .compatible ? (probe: HostProbe.absent, info: nil) : Self.probe(alternateSocket)
        let strangers = HostChoice.strangers(primary: primary.probe, alternate: alternate.probe) + legacyTerminals()
        guard case .use(let place, let start) = HostChoice.choose(primary: primary.probe, alternate: alternate.probe) else {
            throw .onlyStrangers(terminals: strangers)
        }
        let socket = place == .primary ? places.primary : alternateSocket
        if !start, let info = place == .primary ? primary.info : alternate.info {
            return Found(socket: socket, info: info, strangers: strangers)
        }
        try self.start(at: socket)
        let deadline = Date().addingTimeInterval(Self.startTimeout)
        while Date() < deadline {
            let (probe, info) = Self.probe(socket)
            if probe == .compatible, let info { return Found(socket: socket, info: info, strangers: strangers) }
            usleep(20_000)
        }
        throw .couldNotStart("the host did not answer")
    }

    /// Running terminals held by a host of the app's earlier name, if one is still running.
    func legacyTerminals() -> Int {
        guard let legacyPlaces else { return 0 }
        return [legacyPlaces.primary, legacyPlaces.alternate(for: HostProtocol.version)].reduce(0) { total, socket in
            switch Self.probe(socket) {
            case (.absent, _): total
            case (.compatible, let info): total + (info?.terminals ?? 0)
            case (.stranger(let terminals), _): total + terminals
            }
        }
    }

    /// Whether any host answers on one of `places`' sockets.
    public static func anyHostRunning(at places: HostPlaces) -> Bool {
        [places.primary, places.alternate(for: HostProtocol.version)].contains { probe($0).probe != .absent }
    }

    /// Knocks on a socket: who is there, if anyone.
    public static func probe(_ socket: HostSocket) -> (probe: HostProbe, info: HostInfo?) {
        guard let connection = try? HostConnection(socketPath: socket.path) else { return (.absent, nil) }
        defer { connection.close() }
        guard case .hello(let info)? = connection.requestAndWait(.hello(HostProtocol.current, client: "probe"), timeout: answerTimeout) else {
            // Something listens but does not answer as a host of any version we know.
            return (.stranger(terminals: 0), nil)
        }
        let compatible = HostProtocol.compatibility(client: HostProtocol.current, host: info.speaks) == .compatible
        return (compatible ? .compatible : .stranger(terminals: info.terminals), info)
    }

    /// Starts a host on `socket`. If another app starts one at the same moment, one of the two wins
    /// the socket's lock and the other leaves at once; either way a host is then listening.
    private func start(at socket: HostSocket) throws(Failure) {
        do {
            try UnixSocket.makePrivateFolder(places.folder.path)
        } catch {
            throw .couldNotStart("\(error)")
        }
        // The log is for diagnosis, not a record: it starts again once it has grown.
        if let size = try? FileManager.default.attributesOfItem(atPath: socket.log)[.size] as? Int, size > 1024 * 1024 {
            try? FileManager.default.removeItem(atPath: socket.log)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, socket.log, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), unblocked = sigset_t()
        sigemptyset(&defaults)
        sigemptyset(&unblocked)
        for number in 1..<NSIG where number != SIGKILL && number != SIGSTOP { sigaddset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        // A session of its own: no terminal, no process group shared with the app, none of its descriptors.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        // It carries every keystroke and its echo: scheduled as the app's own interactive work is.
        posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE)

        let arguments = [executable.path, "--socket", socket.path, "--lock", socket.lock, "--log", socket.log, "--build", build] + extraArguments
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard result == 0 else { throw .couldNotStart("\(executable.path): \(String(cString: strerror(result)))") }
        Self.reapWhenDone(pid)
    }

    /// The host is this process's child until this process ends; if the host ends first, its exit is
    /// collected so nothing of it lingers.
    private static func reapWhenDone(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            var state: Int32 = 0
            waitpid(pid, &state, WNOHANG)
            source.cancel()
        }
        source.resume()
    }
}
