import Darwin
import Foundation
import WhiskrKit

/// A client's connection to the session host: asks, hears the answers, and carries a terminal's bytes
/// both ways. The app opens one for itself and one per terminal on screen, so each terminal is read on
/// a thread of its own and a busy one never holds up another.
///
/// What arrives is handed over on the connection's reading thread, in order. What is sent goes out in
/// order and never makes the caller (the main thread, typing) wait on the socket.
/// The connection lives until `close()` is called or the host goes.
public final class HostConnection: @unchecked Sendable {
    public struct Handlers: Sendable {
        /// What a terminal printed.
        public var output: @Sendable (UUID, Data) -> Void
        public var event: @Sendable (HostEvent) -> Void
        /// The connection ended: the host has gone, or `close()` was called.
        public var closed: @Sendable () -> Void

        public init(output: @escaping @Sendable (UUID, Data) -> Void = { _, _ in }, event: @escaping @Sendable (HostEvent) -> Void = { _ in },
                    closed: @escaping @Sendable () -> Void = {}) {
            self.output = output
            self.event = event
            self.closed = closed
        }
    }

    private let fd: Int32
    private let handlers: Handlers
    private let writing = DispatchQueue(label: "app.whiskr.host.client", qos: .userInteractive)
    private let state = NSLock()
    /// Guarded by `state`.
    private var waiting: [Int: @Sendable (HostReply) -> Void] = [:]
    private var nextID = 1
    /// `close()` was called; `closed` once the reading thread has seen the connection end.
    private var closing = false
    private var closed = false
    /// Pieces waiting on the writing queue.
    private var queued = 0

    /// Connects to the host listening at `path` and starts reading. Throws when nothing listens there.
    public init(socketPath path: String, handlers: Handlers = Handlers()) throws {
        do {
            fd = try UnixSocket.connect(to: path)
        } catch {
            throw HostFailure(.connectionLost, "\(error)")
        }
        self.handlers = handlers
        let thread = Thread { [self] in read() }
        thread.name = "host connection"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: Sending

    /// Asks; `answer` is called once on the reading thread, with a failure if the connection ends first.
    public func request(_ request: HostRequest, answer: @escaping @Sendable (HostReply) -> Void) {
        let id: Int? = state.withLock {
            guard !closing, !closed else { return nil }
            nextID += 1
            waiting[nextID] = answer
            return nextID
        }
        guard let id else { return answer(.failed(HostFailure(.connectionLost))) }
        write(HostFrame.message(HostCall(id: id, request: request)).encoded)
    }

    public func request(_ request: HostRequest) async -> HostReply {
        await withCheckedContinuation { continuation in
            self.request(request) { continuation.resume(returning: $0) }
        }
    }

    /// Asks and waits, for callers that are not on the main thread. nil when no answer came in time.
    public func requestAndWait(_ request: HostRequest, timeout: TimeInterval) -> HostReply? {
        let answered = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        self.request(request) { reply in
            box.set(reply)
            answered.signal()
        }
        return answered.wait(timeout: .now() + timeout) == .success ? box.reply : nil
    }

    /// Says something whose answer nobody needs (a resize, a close).
    public func send(_ request: HostRequest) {
        self.request(request) { _ in }
    }

    /// What was typed into a terminal.
    public func type(_ bytes: Data, into terminal: UUID) {
        write(HostFrame.input(terminal: terminal, bytes).encoded)
    }

    /// Sends at once when the socket has room, which for a keystroke it always has: no thread has to
    /// wake first. What does not fit (a large paste while the host is busy) goes out from the writing
    /// queue, and until that is empty so does everything after it, so the order holds.
    private func write(_ data: Data) {
        let rest: Data? = state.withLock {
            guard !closed else { return nil }
            var sent = 0
            if queued == 0 {
                sent = max(data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }, 0)
                if sent == data.count { return nil }
            }
            queued += 1
            return sent == 0 ? data : data.subdata(in: data.startIndex + sent..<data.endIndex)
        }
        guard let rest else { return }
        writing.async { [self] in
            defer { state.withLock { queued -= 1 } }
            guard !state.withLock({ closed }) else { return }
            rest.withUnsafeBytes { bytes in
                var position = 0
                while position < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress! + position, bytes.count - position)
                    if count > 0 {
                        position += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        // The host has gone; the reading thread says so.
                        return
                    }
                }
            }
        }
    }

    /// Ends the connection, after everything already sent has gone out. The host keeps every terminal.
    public func close() {
        let already = state.withLock {
            defer { closing = true }
            return closing
        }
        guard !already else { return }
        writing.async { [self] in
            // Wakes the reading thread, which closes the descriptor.
            if !state.withLock({ closed }) { shutdown(fd, SHUT_RDWR) }
        }
    }

    // MARK: Reading

    private func read() {
        var decoder = HostFrameDecoder()
        let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 1)
        defer { chunk.deallocate() }
        reading: while true {
            let count = Darwin.read(fd, chunk.baseAddress, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            decoder.append(UnsafeRawBufferPointer(rebasing: chunk[0..<count]))
            // A terminal's output read in one go is handed over as one piece (`OutputBatch`).
            var batch = OutputBatch()
            do {
                while let frame = try decoder.next() {
                    if case .output(let terminal, let bytes) = frame {
                        if let ready = batch.add(bytes, for: terminal) { handlers.output(ready.0, ready.1) }
                    } else {
                        if let ready = batch.take() { handlers.output(ready.0, ready.1) }
                        deliver(frame)
                    }
                }
                if let ready = batch.take() { handlers.output(ready.0, ready.1) }
            } catch {
                break reading
            }
        }
        let unanswered = state.withLock {
            closed = true
            defer { waiting = [:] }
            return waiting.values.map { $0 }
        }
        for answer in unanswered { answer(.failed(HostFailure(.connectionLost))) }
        handlers.closed()
        // After any write already under way.
        writing.async { [fd] in Darwin.close(fd) }
    }

    private func deliver(_ frame: HostFrame) {
        switch frame {
        case .output(let terminal, let bytes):
            handlers.output(terminal, bytes)
        case .input:
            break
        case .message(let json):
            guard let message = try? JSONDecoder().decode(HostMessage.self, from: json) else { return }
            switch message {
            case .reply(let id, let reply):
                state.withLock { waiting.removeValue(forKey: id) }?(reply)
            case .event(let event):
                handlers.event(event)
            }
        }
    }
}

/// An answer handed from the reading thread to a caller that waits for it.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HostReply?

    func set(_ reply: HostReply) { lock.withLock { value = reply } }
    var reply: HostReply? { lock.withLock { value } }
}
