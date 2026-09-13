import Darwin
import Foundation

/// Writes to a non-blocking descriptor from the host's queue without ever waiting: what the descriptor
/// will not take now is kept and sent when it has room. `backlog` says how much is waiting, which is
/// how the host knows to stop reading a terminal whose viewer cannot keep up.
///
/// Used only on its queue, which is what makes the unchecked Sendable sound.
final class DescriptorWriter: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var pending: [Data] = []
    /// How much of `pending[0]` has been written.
    private var offset = 0
    private(set) var backlog = 0
    private(set) var failed = false
    private var source: DispatchSourceWrite?
    private var waiting = false
    /// The backlog grew or shrank.
    var onBacklog: (() -> Void)?
    /// The other side has gone.
    var onFailure: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func write(_ data: Data) {
        guard !failed, !data.isEmpty else { return }
        guard pending.isEmpty else {
            pending.append(data)
            backlog += data.count
            onBacklog?()
            return
        }
        let written = push(data, from: 0)
        guard !failed, written < data.count else { return }
        pending.append(data)
        offset = written
        backlog = data.count - written
        wait()
        onBacklog?()
    }

    /// Writes as much of `data` past `start` as the descriptor takes now; returns how far it got.
    private func push(_ data: Data, from start: Int) -> Int {
        var position = start
        data.withUnsafeBytes { bytes in
            while position < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress! + position, bytes.count - position)
                if count > 0 {
                    position += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { fail() }
                    return
                }
            }
        }
        return position
    }

    private func drain() {
        while let first = pending.first, !failed {
            let reached = push(first, from: offset)
            backlog -= reached - offset
            if reached < first.count {
                offset = reached
                break
            }
            pending.removeFirst()
            offset = 0
        }
        if pending.isEmpty || failed { rest() }
        if !failed { onBacklog?() }
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        pending = []
        backlog = 0
        queue.async { [weak self] in self?.onFailure?() }
    }

    private func wait() {
        if source == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            self.source = source
        }
        guard !waiting else { return }
        waiting = true
        source?.resume()
    }

    private func rest() {
        guard waiting else { return }
        waiting = false
        source?.suspend()
    }

    /// Stops for good; `done` runs once the descriptor is no longer watched and may be closed.
    func cancel(_ done: @escaping @Sendable () -> Void) {
        failed = true
        pending = []
        backlog = 0
        guard let source else { return queue.async(execute: done) }
        self.source = nil
        source.setCancelHandler(handler: done)
        // A suspended source never delivers its cancellation.
        if !waiting { source.resume() }
        waiting = false
        source.cancel()
    }
}
