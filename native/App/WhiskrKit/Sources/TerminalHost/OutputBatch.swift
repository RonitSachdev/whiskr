import Foundation

/// Output read in one go, joined into as few pieces as keep their order: pieces for the same terminal one
/// after another become one, up to `limit` bytes. A pseudo-terminal hands over at most a kilobyte per read
/// on macOS, so a program printing fast arrives as thousands of small pieces; each piece passed on costs a
/// frame, a wakeup and a turn of the receiving terminal's lock, which typing and drawing wait for too.
/// Nothing waits to be joined: a batch holds only what had already arrived, and goes as soon as the
/// reading that filled it is done, so a lone keystroke's echo goes alone and at once.
public struct OutputBatch {
    /// A piece is never made larger than this, so the terminal that takes it is not held for long.
    public static let defaultLimit = 64 * 1024

    public let limit: Int
    private var terminal: UUID?
    private var bytes = Data()

    public init(limit: Int = OutputBatch.defaultLimit) {
        self.limit = limit
    }

    /// Adds a piece; returns what must go first (the batch so far, for another terminal or full).
    public mutating func add(_ piece: Data, for terminal: UUID) -> (UUID, Data)? {
        guard !piece.isEmpty else { return nil }
        var out: (UUID, Data)?
        if let current = self.terminal, current != terminal || bytes.count + piece.count > limit {
            out = take()
        }
        self.terminal = terminal
        bytes.append(piece)
        return out
    }

    /// What is held, emptied.
    public mutating func take() -> (UUID, Data)? {
        guard let terminal, !bytes.isEmpty else { return nil }
        defer {
            self.terminal = nil
            bytes = Data()
        }
        return (terminal, bytes)
    }
}
