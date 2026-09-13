import Darwin
import Foundation
import WhiskrKit

/// The host process itself: what its `main` runs.
///
///   --socket <path>           where to listen
///   --lock <path>             the file whose lock says a host owns that socket
///   --log <path>              named in the first log line (the launcher points standard error at it)
///   --build <version>         the app version that started it
///   --idle-exit <seconds>     how long to stay with no terminal and no client (default 30)
///   --abandoned-after <s>     test runs: stop everything once no client has been connected that long
public enum HostMain {
    public static func run(arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let path = value("--socket"), let lock = value("--lock") else {
            FileHandle.standardError.write(Data("usage: --socket <path> --lock <path> [--log <path>] [--build <version>]\n".utf8))
            exit(64)
        }
        // The host outlives whoever started it: a hang-up is not for it, and a client that has gone
        // is an error to handle, not a signal.
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        // Never inside a folder someone may want to unmount or delete.
        chdir(NSHomeDirectory())

        let options = HostServer.Options(
            socket: HostSocket(path: path, lock: lock, log: value("--log") ?? ""), build: value("--build") ?? "",
            idleGrace: value("--idle-exit").flatMap(TimeInterval.init) ?? HostLifecycle.idleGrace,
            abandonedAfter: value("--abandoned-after").flatMap(TimeInterval.init))
        let server = HostServer(options: options, log: log) { exit(0) }
        do {
            try server.start()
        } catch HostServer.StartFailure.alreadyRunning {
            // Another host won the race for this socket; the app uses that one.
            exit(0)
        } catch {
            log("could not start: \(error)")
            exit(1)
        }
        // Logging out, shutting down, `kill`: every terminal is asked to end first.
        signal(SIGTERM, SIG_IGN)
        let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminated.setEventHandler { server.stop() }
        terminated.resume()
        withExtendedLifetime(terminated) { dispatchMain() }
    }

    private static let log: @Sendable (String) -> Void = { line in
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) [\(getpid())] \(line)\n".utf8))
    }
}
