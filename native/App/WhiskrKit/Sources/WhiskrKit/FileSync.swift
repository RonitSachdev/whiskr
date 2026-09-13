import Foundation

/// What an open file does when its file changes on disk. Claude edits files constantly, often the very
/// file on screen, so this must never lose a keystroke and never nag: a file you have not touched simply
/// follows the disk; one you have changed asks, quietly, once per change on disk.
public enum FileSync {
    public enum Response: Sendable, Equatable {
        /// The disk holds what the editor last read or wrote (our own save, a touch, a rewrite with the
        /// same bytes): nothing to do.
        case nothing
        /// Nothing typed since: take the disk's version, keeping the selection and the scroll.
        case reload
        /// You have unsaved changes and the disk changed under them: offer Reload or Keep Mine.
        case ask
        /// The file is gone (deleted, or moved away).
        case deleted
    }

    /// `disk` is the file's bytes now (nil when it no longer exists), `known` what the editor last read
    /// or wrote, `edited` whether the editor holds changes not yet saved.
    public static func respond(disk: Data?, known: Data, edited: Bool) -> Response {
        guard let disk else { return .deleted }
        if disk == known { return .nothing }
        return edited ? .ask : .reload
    }

    /// Where the selection goes when the text is replaced by the disk's version: the same line and column,
    /// as near as the new text allows (Claude usually changes lines elsewhere in the file).
    public static func carry(offset: Int, from old: LineIndex, to new: LineIndex) -> Int {
        let line = min(old.line(at: offset), new.lineCount - 1)
        let column = offset - old.starts[old.line(at: offset)]
        let range = new.range(ofLine: line)
        return range.lowerBound + min(column, range.count)
    }
}
