import Darwin
import Foundation
import Testing
@testable import TerminalHost
import WhiskrKit

/// What a client heard, in the order it heard it: output as text, an event as "event", the end as "closed".
final class Ordered: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var handlers: HostConnection.Handlers {
        HostConnection.Handlers(
            output: { [self] _, bytes in lock.withLock { entries.append(String(decoding: bytes, as: UTF8.self)) } },
            event: { [self] _ in lock.withLock { entries.append("event") } },
            closed: { [self] in lock.withLock { entries.append("closed") } })
    }

    var log: [String] { lock.withLock { entries } }
}

/// A folder of its own under /tmp (a socket's address holds 103 bytes), removed by the test.
private func scratchFolder() throws -> URL {
    let folder = URL(fileURLWithPath: "/tmp/wko-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A listening socket and the one connection it accepts: a stand-in host that says exactly what a test
/// writes, and reads nothing.
private final class StandInHost {
    let path: String
    private let listener: Int32
    private(set) var peer: Int32 = -1

    init(in folder: URL) throws {
        path = folder.appendingPathComponent("h.sock").path
        listener = try UnixSocket.listen(at: path)
    }

    deinit {
        if peer >= 0 { close(peer) }
        close(listener)
    }

    func accept() -> Bool {
        eventually {
            if self.peer < 0 { self.peer = Darwin.accept(self.listener, nil, nil) }
            return self.peer >= 0
        }
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { _ = Darwin.write(peer, $0.baseAddress, $0.count) }
    }
}

@Suite("Output keeps its order through the host and the client", .serialized)
struct OutputOrderTests {
    let terminal = UUID()

    @Test("The client hands over joined output before a message that came after it, and before it gives up on a broken frame")
    func clientFlushes() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try StandInHost(in: folder)
        let heard = Ordered()
        let connection = try HostConnection(socketPath: host.path, handlers: heard.handlers)
        defer { connection.close() }
        #expect(host.accept())
        // One write, so one read on the client: two pieces, an event, one more piece, then a frame of length 0.
        var frames = HostFrame.output(terminal: terminal, Data("ab".utf8)).encoded
        frames += HostFrame.output(terminal: terminal, Data("cd".utf8)).encoded
        frames += HostFrame.message(HostMessage.event(.exited(terminal: terminal, exitCode: 0))).encoded
        frames += HostFrame.output(terminal: terminal, Data("ef".utf8)).encoded
        frames += Data([0, 0, 0, 0])
        host.write(frames)
        #expect(eventually { heard.log.last == "closed" })
        #expect(heard.log == ["abcd", "event", "ef", "closed"])
    }

    @Test("Closing a connection whose host has stopped reading ends it within the grace, a large paste and all")
    func closeDoesNotWaitOnAStuckHost() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try StandInHost(in: folder)
        let heard = Ordered()
        let connection = try HostConnection(socketPath: host.path, handlers: heard.handlers)
        #expect(host.accept())
        // Far more than both sockets' buffers hold: the writing queue blocks on it.
        connection.type(Data(repeating: UInt8(ascii: "x"), count: 8 * 1024 * 1024), into: terminal)
        let closing = Date()
        connection.close()
        #expect(eventually(HostConnection.closeGrace + 3) { heard.log.last == "closed" })
        #expect(Date().timeIntervalSince(closing) >= HostConnection.closeGrace - 0.5)
    }

    @Test("The host sends what a terminal printed before anything its printing sets off, in pieces of at most a batch")
    func hostSendsOutputFirst() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        UnixSocket.prepare(pair[0])
        _ = fcntl(pair[0], F_SETFL, O_NONBLOCK)
        defer { close(pair[1]) }
        let queue = DispatchQueue(label: "test host")
        let process = Launch.shell("/bin/sh", directory: folder.path, environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": folder.path])
        let spec = TerminalSpec(terminal: terminal, process: process, size: TerminalSize(columns: 100, rows: 30))
        let hosted = try queue.sync { try HostedTerminal(spec, address: "t1", queue: queue) }
        let viewer = ClientLink(fd: pair[0], queue: queue)
        queue.sync {
            viewer.start()
            _ = hosted.attach(viewer)
            // What the host's agent work does when a terminal prints: says something about it (here a mark
            // no terminal sends, to tell it from the status the host tells a viewer as it attaches).
            hosted.onOutput = { terminal in
                for viewer in terminal.viewers { viewer.send(.message(.event(.exited(terminal: terminal.id, exitCode: 99)))) }
            }
            hosted.type(Data("head -c 400000 /dev/zero | tr '\\0' y; echo; echo done-$((6*7))\n".utf8))
        }
        // The host busy for a moment, as with many terminals: the program's output waits in the terminal.
        queue.async { usleep(300_000) }
        defer {
            queue.sync { hosted.end() }
            _ = eventually { queue.sync { hosted.info.exited } }
            queue.sync {
                hosted.dispose()
                viewer.close()
            }
        }

        // Each frame as it arrives: "o" with its size, or "e".
        var decoder = HostFrameDecoder()
        var frames: [(kind: Character, size: Int)] = []
        var text = ""
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let deadline = Date().addingTimeInterval(20)
        while !text.contains("done-42"), Date() < deadline {
            var poll = pollfd(fd: pair[1], events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poll, 1, 500) > 0 else { continue }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(pair[1], $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            decoder.append(Data(chunk[0..<count]))
            while let frame = try decoder.next() {
                switch frame {
                case .output(_, let bytes):
                    frames.append(("o", bytes.count))
                    text += String(decoding: bytes, as: UTF8.self)
                case .message(let json):
                    if case .event(.exited(_, 99))? = try? JSONDecoder().decode(HostMessage.self, from: json) { frames.append(("e", 0)) }
                case .input: break
                }
            }
        }
        #expect(text.contains("done-42"))
        // Each read of the terminal: its output, then what it set off; never the other way round.
        let kinds = String(frames.map(\.kind))
        #expect(kinds.first == "o")
        #expect(!kinds.contains("ee"))
        // One turn reads at most a batch (and the read that passes it).
        #expect((frames.map(\.size).max() ?? 0) <= OutputBatch.defaultLimit + 64 * 1024)
    }
}
