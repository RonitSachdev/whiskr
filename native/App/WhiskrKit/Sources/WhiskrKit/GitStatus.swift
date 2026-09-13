import Foundation

/// What git says about one file, as one of the letters the Changes list and the file tree show.
public enum GitFileState: Sendable, Equatable {
    case unmodified, modified, added, deleted, renamed, copied, typeChanged, untracked, ignored, conflicted

    /// The letter shown beside a file: M A D R C T ? ! U ("" for unmodified).
    public var letter: String {
        switch self {
        case .unmodified: ""
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "?"
        case .ignored: "!"
        case .conflicted: "U"
        }
    }

    /// One side of porcelain's XY: "." is unmodified.
    init(code: Character) {
        switch code {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        case "?": self = .untracked
        case "!": self = .ignored
        default: self = .unmodified
        }
    }

    /// How much a folder's dot should say: a conflict first, then a deletion, then an edit, then a new file.
    var weight: Int {
        switch self {
        case .conflicted: 4
        case .deleted: 3
        case .modified, .renamed, .copied, .typeChanged: 2
        case .added, .untracked: 1
        case .unmodified, .ignored: 0
        }
    }
}

public struct GitStatusEntry: Sendable, Equatable, Identifiable {
    /// Relative to the repository's top folder, '/' separated; an ignored folder ends in "/".
    public var path: String
    /// Where a renamed or copied file came from.
    public var originalPath: String?
    /// What is staged (X).
    public var index: GitFileState
    /// What is changed and not staged (Y).
    public var worktree: GitFileState
    public var isConflicted: Bool
    public var isUntracked: Bool
    public var isIgnored: Bool

    public var id: String { path }

    public init(path: String, originalPath: String? = nil, index: GitFileState, worktree: GitFileState,
                isConflicted: Bool = false, isUntracked: Bool = false, isIgnored: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.worktree = worktree
        self.isConflicted = isConflicted
        self.isUntracked = isUntracked
        self.isIgnored = isIgnored
    }
}

/// A repository's state as `git status --porcelain=v2 -z --branch --untracked-files=all --ignored=matching`
/// prints it: the branch and how far it is from its upstream, and every changed, untracked and ignored
/// path, sorted into what the Changes list and the file tree show.
public struct GitStatus: Sendable, Equatable {
    /// nil when no branch is checked out; `commit` then says where HEAD is.
    public var branch: String?
    /// The first seven characters of HEAD's commit; nil before the first commit.
    public var commit: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var entries: [GitStatusEntry]

    /// Changes in the index, conflicts left out; by path.
    public private(set) var staged: [GitStatusEntry] = []
    /// Changes in the working tree not staged, conflicts first; by path.
    public private(set) var unstaged: [GitStatusEntry] = []
    public private(set) var untracked: [GitStatusEntry] = []
    public private(set) var ignored: [String] = []
    /// What the file tree shows beside each changed path.
    public private(set) var decorations: [String: GitFileState] = [:]
    /// Every folder holding a decorated path, with the most important state inside.
    public private(set) var folderDecorations: [String: GitFileState] = [:]
    public private(set) var changeCount = 0
    private var ignoredSet: Set<String> = []

    public init(branch: String? = nil, commit: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, entries: [GitStatusEntry] = []) {
        self.branch = branch
        self.commit = commit
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.entries = entries
        derive()
    }

    /// Whether a relative path is ignored: listed itself, or inside an ignored folder.
    public func isIgnored(_ relativePath: String) -> Bool {
        guard !ignoredSet.isEmpty else { return false }
        var path = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
        while !path.isEmpty {
            if ignoredSet.contains(path) { return true }
            guard let slash = path.lastIndex(of: "/") else { return false }
            path = String(path[..<slash])
        }
        return false
    }

    // MARK: Reading

    /// Reads porcelain v2 output, records separated by NUL. Anything it does not understand is passed over.
    public static func parse(_ output: Data) -> GitStatus {
        let records = output.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var status = GitStatus()
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                status.readHeader(record)
            case "1":
                guard let fields = Self.fields(record, count: 8) else { continue }
                entries.append(Self.changed(xy: fields.head[1], path: fields.rest))
            case "2":
                guard let fields = Self.fields(record, count: 9) else { continue }
                var entry = Self.changed(xy: fields.head[1], path: fields.rest)
                // The path it came from is the next record.
                if index < records.count {
                    entry.originalPath = records[index]
                    index += 1
                }
                entries.append(entry)
            case "u":
                guard let fields = Self.fields(record, count: 10) else { continue }
                entries.append(GitStatusEntry(path: fields.rest, index: .conflicted, worktree: .conflicted, isConflicted: true))
            case "?":
                guard record.count > 2 else { continue }
                entries.append(GitStatusEntry(path: String(record.dropFirst(2)), index: .unmodified, worktree: .untracked, isUntracked: true))
            case "!":
                guard record.count > 2 else { continue }
                entries.append(GitStatusEntry(path: String(record.dropFirst(2)), index: .unmodified, worktree: .ignored, isIgnored: true))
            default:
                continue
            }
        }
        status.entries = entries
        status.derive()
        return status
    }

    /// The first `count` space-separated fields (the record's kind among them), and the path after them,
    /// which may itself hold spaces.
    private static func fields(_ record: String, count: Int) -> (head: [Substring], rest: String)? {
        var head: [Substring] = []
        var rest = Substring(record)
        for _ in 0..<count {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            head.append(rest[..<space])
            rest = rest[rest.index(after: space)...]
        }
        guard !rest.isEmpty, head.count > 1, head[1].count == 2 else { return nil }
        return (head, String(rest))
    }

    private static let unmerged: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    private static func changed(xy: Substring, path: String) -> GitStatusEntry {
        if unmerged.contains(String(xy)) {
            return GitStatusEntry(path: path, index: .conflicted, worktree: .conflicted, isConflicted: true)
        }
        return GitStatusEntry(path: path, index: GitFileState(code: xy.first!), worktree: GitFileState(code: xy.last!))
    }

    private mutating func readHeader(_ record: String) {
        let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        let value = parts[2]
        switch parts[1] {
        case "branch.oid": commit = value == "(initial)" ? nil : String(value.prefix(7))
        case "branch.head": branch = value == "(detached)" ? nil : value
        case "branch.upstream": upstream = value
        case "branch.ab":
            for number in value.split(separator: " ") {
                if number.hasPrefix("+") { ahead = Int(number.dropFirst()) ?? 0 }
                if number.hasPrefix("-") { behind = Int(number.dropFirst()) ?? 0 }
            }
        default: break
        }
    }

    /// The lists and lookups the views need, worked out once from `entries`.
    private mutating func derive() {
        let byPath: (GitStatusEntry, GitStatusEntry) -> Bool = { $0.path < $1.path }
        staged = entries.filter { !$0.isConflicted && !$0.isUntracked && !$0.isIgnored && $0.index != .unmodified }.sorted(by: byPath)
        let conflicts = entries.filter(\.isConflicted).sorted(by: byPath)
        unstaged = conflicts + entries.filter { !$0.isConflicted && !$0.isUntracked && !$0.isIgnored && $0.worktree != .unmodified }.sorted(by: byPath)
        untracked = entries.filter(\.isUntracked).sorted(by: byPath)
        ignored = entries.filter(\.isIgnored).map(\.path)
        ignoredSet = Set(ignored.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        changeCount = Set((staged + unstaged + untracked).map(\.path)).count

        var decorations: [String: GitFileState] = [:]
        var folders: [String: GitFileState] = [:]
        for entry in entries where !entry.isIgnored {
            let state: GitFileState = entry.isConflicted ? .conflicted : entry.isUntracked ? .untracked
                : entry.worktree != .unmodified ? entry.worktree : entry.index
            guard state != .unmodified else { continue }
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            decorations[path] = state
            var folder = Substring(path)
            while let slash = folder.lastIndex(of: "/") {
                folder = folder[..<slash]
                let key = String(folder)
                if let known = folders[key], known.weight >= state.weight { continue }
                folders[key] = state
            }
        }
        self.decorations = decorations
        folderDecorations = folders
    }
}
