import Foundation

/// One thing a helper said, read from its transcript: the task it was given, or text it wrote. `id` is
/// the transcript record's own id, so reading the same record twice never says it twice.
public struct HelperSaid: Sendable, Equatable {
    public enum Kind: Sendable { case task, reply }

    public let kind: Kind
    public let id: String
    public let at: Date?
    public let text: String
}

/// How far into a helper's transcript it has been read. `file` tells a replaced file from the one being
/// read; `partial` is the start of a line still being written, kept as bytes so a character split across
/// two reads is joined whole; `skipping` means the line being written is too long to be worth keeping (a
/// whole file's contents, say) and is passed over.
public struct HelperBookmark: Sendable, Equatable {
    public var file = ""
    public var offset: UInt64 = 0
    public var partial: Data?
    public var skipping = false

    public static let start = HelperBookmark()
}

/// An open transcript file. Behind a protocol so tests can stand in for the disk where they need to.
public protocol HelperTranscriptHandle {
    /// Names this file and no other, so a file replaced at the same path is noticed: device and inode.
    var identity: String { get }
    var size: UInt64 { get }
    /// Up to `count` bytes from `offset`; empty at the end; nil when the read failed.
    func read(at offset: UInt64, count: Int) -> Data?
}

public protocol HelperTranscriptFiles: Sendable {
    /// The file at `path`, or nil when it is not there (yet).
    func open(_ path: String) -> (any HelperTranscriptHandle)?
}

/// The real files, read with plain blocking calls: use it off the main thread.
public struct LocalHelperTranscriptFiles: HelperTranscriptFiles {
    public init() {}

    public func open(_ path: String) -> (any HelperTranscriptHandle)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            try? handle.close()
            return nil
        }
        return LocalHandle(handle: handle, identity: "\(info.st_dev):\(info.st_ino)", size: UInt64(max(0, info.st_size)))
    }

    /// Closes its file when the last reference goes, which is at the end of one read.
    private final class LocalHandle: HelperTranscriptHandle {
        let handle: FileHandle
        let identity: String
        let size: UInt64

        init(handle: FileHandle, identity: String, size: UInt64) {
            self.handle = handle
            self.identity = identity
            self.size = size
        }

        deinit { try? handle.close() }

        func read(at offset: UInt64, count: Int) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: count) ?? Data()
        }
    }
}

/// A read of one helper's transcript that is due: what the app performs off the main thread with
/// `HelperTranscript.read(_:files:)` and hands back with `AgentWorld.hear(_:now:)`.
public struct HelperRead: Sendable, Equatable {
    public let sessionID: String
    public let agentID: String
    public let transcriptPath: String
    public let from: HelperBookmark
}

public struct HelperReadResult: Sendable, Equatable {
    public let read: HelperRead
    public let said: [HelperSaid]
    public let bookmark: HelperBookmark
}

/// Claude Code keeps each helper's whole conversation in `<session>/subagents/agent-<id>.jsonl`, the only
/// place its words can be found: the hook that carries Claude's text does not fire for helpers. Ported
/// from the web prototype's `server/lineage.ts`. This reads what was appended since a bookmark, a slice
/// at a time, and keeps only two things: what the helper was asked (a user record in plain words) and
/// the text it wrote. Tool calls and their results, where file contents live, are dropped as each line
/// is read; so is a line too long to be anything but those.
public enum HelperTranscript {
    static let slice = 1024 * 1024
    static let longestLine = 1024 * 1024

    public static func read(_ request: HelperRead, files: any HelperTranscriptFiles) -> HelperReadResult {
        let (said, bookmark) = read(transcriptPath: request.transcriptPath, agentID: request.agentID, from: request.from, files: files)
        return HelperReadResult(read: request, said: said, bookmark: bookmark)
    }

    /// What the helper has written since `from`, and where to carry on next time. The agent id arrives in
    /// hook payloads, so a path is only built from one that is plainly an id (see `Transcripts.helperFile`).
    static func read(transcriptPath: String, agentID: String, from: HelperBookmark, files: any HelperTranscriptFiles) -> ([HelperSaid], HelperBookmark) {
        // Not written yet: the helper has only just started, or never got going.
        guard let path = Transcripts.helperFile(transcriptPath: transcriptPath, agentID: agentID, ending: ".jsonl"),
              let file = files.open(path) else { return ([], from) }
        var mark = from
        // A different file at the same path, or one that got shorter, is read again from its start;
        // records already heard are recognised by their ids.
        if file.identity != from.file || file.size < from.offset {
            mark = HelperBookmark(file: file.identity)
        }
        var said: [HelperSaid] = []
        while mark.offset < file.size {
            guard let slice = file.read(at: mark.offset, count: Int(min(UInt64(Self.slice), file.size - mark.offset))) else { return ([], from) }
            if slice.isEmpty { break }
            mark.offset += UInt64(slice.count)
            var start = slice.startIndex
            while let end = slice[start...].firstIndex(of: 10) {
                let piece = slice[start..<end]
                start = end + 1
                if mark.skipping {
                    mark.skipping = false
                } else {
                    said += line(mark.partial.map { $0 + piece } ?? Data(piece))
                }
                mark.partial = nil
            }
            // The start of a line still being written waits for the rest.
            if start < slice.endIndex, !mark.skipping {
                let rest = (mark.partial ?? Data()) + slice[start...]
                mark.partial = rest
                if rest.count > longestLine {
                    mark.partial = nil
                    mark.skipping = true
                }
            }
        }
        return (said, mark)
    }

    private static let userMark = Data(#""type":"user""#.utf8)
    private static let assistantMark = Data(#""type":"assistant""#.utf8)

    /// One transcript line, as the helper's task or text, or nothing.
    static func line(_ bytes: Data) -> [HelperSaid] {
        // Most lines are tool traffic and bookkeeping; only these two kinds are worth parsing.
        guard bytes.firstRange(of: userMark) != nil || bytes.firstRange(of: assistantMark) != nil,
              let entry = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return [] }
        let type = entry["type"].text
        let id = entry["uuid"].text
        guard !id.isEmpty, type == "user" || type == "assistant" else { return [] }
        // Claude Code adds notes of its own to a helper's conversation (reminders, compaction summaries)
        // and marks them; a tool's result also arrives as a user record.
        if type == "user", entry["isMeta"].isTrue || entry["isCompactSummary"].isTrue || entry.fields["toolUseResult"] != nil { return [] }
        let content = entry["message"]["content"]
        let blocks: [JSONValue] = if case .string(let text) = content { [["type": "text", "text": .string(text)]] } else { content.items }
        if type == "user", blocks.contains(where: { $0["type"].text == "tool_result" }) { return [] }
        // Thinking is private to the model, and tool calls are already on the timeline.
        let words = blocks.filter { $0["type"].text == "text" }.map { $0["text"].text }.joined(separator: "\n\n")
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        // One character over the limit, so the journal can tell it was cut.
        return [HelperSaid(kind: type == "user" ? .task : .reply, id: id, at: date(entry["timestamp"].text), text: String(words.prefix(Journal.Limits.chatText + 1)))]
    }

    private static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

/// Which helpers' transcripts of one session to read, and when. Only sessions someone is looking at are
/// read, so sessions nobody watches cost no file reads; a watched session's helpers are read when one
/// reports in, every few seconds besides (a helper writes text between tool calls without any hook
/// firing), and for a while after one stops (its last lines can land a moment late). One read at a time
/// per helper: a read wanted while one is out happens as soon as that one is handed back.
struct HelperTranscriptFollower: Sendable {
    static let every: TimeInterval = 4
    static let afterStop: TimeInterval = 15

    private struct Follow: Sendable {
        var bookmark = HelperBookmark.start
        var reading = false
        var again = false
    }

    /// Each helper's transcript, as far as it has been read. Kept while nobody watches, to carry on from.
    private var follows: [String: Follow] = [:]
    /// Helpers that reported in since the last reads were handed out.
    private var wanted: Set<String> = []
    private var followedAt = Date.distantPast

    /// A helper reported in, so it has probably written something since it was last read.
    mutating func want(_ agentID: String) {
        wanted.insert(agentID)
    }

    /// Every helper the session has had, for a session someone has just started watching.
    mutating func wantAll(_ agents: [AgentRecord]) {
        for agent in agents where agent.id != AgentWorld.mainAgent { wanted.insert(agent.id) }
    }

    mutating func due(sessionID: String, transcriptPath: String, agents: [AgentRecord], now: Date) -> [HelperRead] {
        let known = Set(agents.map(\.id))
        // Helpers the journal has let go of are not read again.
        follows = follows.filter { known.contains($0.key) }
        var picked = wanted.intersection(known)
        wanted.removeAll()
        if now.timeIntervalSince(followedAt) >= Self.every {
            followedAt = now
            // Helpers still at work, and those that stopped only just now.
            for agent in agents where agent.endedAt.map({ now.timeIntervalSince($0) < Self.afterStop }) ?? true {
                picked.insert(agent.id)
            }
        }
        picked.remove(AgentWorld.mainAgent)
        guard !transcriptPath.isEmpty else { return [] }
        var reads: [HelperRead] = []
        // In launch order, so the oldest helper's words are asked for first.
        for agent in agents where picked.contains(agent.id) {
            var follow = follows[agent.id] ?? Follow()
            if follow.reading {
                follow.again = true
            } else {
                follow.reading = true
                reads.append(HelperRead(sessionID: sessionID, agentID: agent.id, transcriptPath: transcriptPath, from: follow.bookmark))
            }
            follows[agent.id] = follow
        }
        return reads
    }

    /// A read came back: carry on from where it stopped.
    mutating func finish(_ result: HelperReadResult) {
        guard var follow = follows[result.read.agentID], follow.reading else { return }
        follow.reading = false
        follow.bookmark = result.bookmark
        if follow.again {
            follow.again = false
            wanted.insert(result.read.agentID)
        }
        follows[result.read.agentID] = follow
    }
}
