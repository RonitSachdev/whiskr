import Foundation

/// Pipes to and from a child process that only that child gets. Foundation's `Pipe()` leaves both
/// descriptors open across `exec`, so every other process started meanwhile, from any thread, inherits
/// them: a long-lived one (a shell, a process git leaves behind) then holds the pipe open, and whoever
/// reads it to the end waits forever. Here both ends close on `exec`; the child still gets its own end,
/// because `Process` copies it onto 0, 1 or 2, and that copy stays open.
public enum ProcessPipe {
    public static func make() -> Pipe {
        let pipe = Pipe()
        for descriptor in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
            _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
        }
        return pipe
    }
}

/// Reads a child's output pipes as data arrives, so a chatty stream never fills and stalls the child, and
/// never waits past a deadline for their end: a pipe ends only when every process holding it has let go,
/// which something the child started may never do. Set it up before the child starts, and `finish` once.
public final class PipeReader: @unchecked Sendable {
    private let condition = NSCondition()
    private let handles: [FileHandle]
    private var collected: [Data]
    private var ended: [Bool]

    public init(_ pipes: [Pipe]) {
        handles = pipes.map(\.fileHandleForReading)
        collected = Array(repeating: Data(), count: pipes.count)
        ended = Array(repeating: false, count: pipes.count)
        for (index, handle) in handles.enumerated() {
            handle.readabilityHandler = { [self] handle in
                let data = handle.availableData
                condition.withLock {
                    if data.isEmpty {
                        ended[index] = true
                        handle.readabilityHandler = nil
                    } else {
                        collected[index].append(data)
                    }
                    condition.broadcast()
                }
            }
        }
    }

    /// What each pipe gave, in the order given, once all have ended or at `deadline`, whichever comes
    /// first. Reading then stops.
    public func finish(by deadline: Date) -> [Data] {
        condition.lock()
        while ended.contains(false), condition.wait(until: deadline) {}
        let result = collected
        condition.unlock()
        for handle in handles { handle.readabilityHandler = nil }
        return result
    }
}
