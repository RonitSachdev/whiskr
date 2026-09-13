import Foundation

/// One thing the command palette (⇧⌘P) or Go to (⌘P) can find: a place (a workspace, tab, Claude or
/// helper) or a menu command. The app builds these from its model and menus; this decides their order
/// (docs/DESIGN.md, herdr's palette and go-to picker).
public struct PaletteEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Int, Sendable, CaseIterable {
        case workspace, tab, claude, helper, command
        /// A file in the workspace (Go to finds them through `PathIndex`, as you type).
        case file

        public var isPlace: Bool { self != .command }
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// Searched after the title: a place's folder and branch, a command's menu.
    public let detail: String
    /// Searched last, never shown: a Claude's state in words ("needs you", "finished"), so typing the
    /// state finds everything in it.
    public let keywords: [String]
    public let status: AgentStatus?
    public let pinned: Bool
    /// Since when a request or a finished turn has waited, for the waiting queue's order.
    public let since: Date?
    /// The id of the tab entry this place is in (a tab's own id for a tab): one place is listed once,
    /// so a tab whose Claude is already under Waiting is not under Recent too.
    public let tab: String?

    public init(id: String, kind: Kind, title: String, detail: String = "", keywords: [String] = [], status: AgentStatus? = nil,
                pinned: Bool = false, since: Date? = nil, tab: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.keywords = keywords
        self.status = status; self.pinned = pinned; self.since = since; self.tab = tab
    }
}

/// How often and how lately each entry was chosen ("frecency"), kept between launches.
public struct PaletteUsage: Sendable, Equatable, Codable {
    struct Use: Sendable, Equatable, Codable {
        var count: Int
        var last: Date
    }

    var uses: [String: Use] = [:]
    static let limit = 200

    public init() {}

    public mutating func record(_ id: String, now: Date) {
        var use = uses[id] ?? Use(count: 0, last: now)
        use.count += 1
        use.last = now
        uses[id] = use
        if uses.count > Self.limit, let oldest = uses.min(by: { $0.value.last < $1.value.last })?.key { uses[oldest] = nil }
    }

    /// Uses, each worth less the longer ago the last one was (halving every week).
    public func score(_ id: String, now: Date) -> Double {
        guard let use = uses[id] else { return 0 }
        let weeks = max(0, now.timeIntervalSince(use.last)) / (7 * 86_400)
        return Double(use.count) * pow(0.5, weeks)
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(PaletteUsage.self, from: $0) } ?? PaletteUsage()
    }
}

public enum PaletteRanking {
    public struct Ranked: Sendable, Equatable, Identifiable {
        public let entry: PaletteEntry
        /// The title's matched characters, to draw bold.
        public let offsets: [Int]
        public var id: String { entry.id }
    }

    /// Entries matching `query`, best first: the title starting with it, then the title matching it
    /// loosely, then the folder, branch or menu matching it, then the state's words (Raycast's order);
    /// within each, the better match, then pinned, then the most used lately.
    public static func rank(_ entries: [PaletteEntry], query: String, usage: PaletteUsage, now: Date) -> [Ranked] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries.map { Ranked(entry: $0, offsets: []) } }
        struct Scored { let ranked: Ranked; let tier: Int; let score: Int; let frecency: Double }
        let scored = entries.compactMap { entry -> Scored? in
            let frecency = usage.score(entry.id, now: now)
            if let title = FuzzyMatch.match(trimmed, in: entry.title) {
                return Scored(ranked: Ranked(entry: entry, offsets: title.offsets), tier: title.isPrefix ? 0 : 1, score: title.score, frecency: frecency)
            }
            if !entry.detail.isEmpty, let detail = FuzzyMatch.match(trimmed, in: entry.detail) {
                return Scored(ranked: Ranked(entry: entry, offsets: []), tier: 2, score: detail.score, frecency: frecency)
            }
            if let word = entry.keywords.compactMap({ FuzzyMatch.match(trimmed, in: $0) }).filter(\.isPrefix).max(by: { $0.score < $1.score }) {
                return Scored(ranked: Ranked(entry: entry, offsets: []), tier: 3, score: word.score, frecency: frecency)
            }
            return nil
        }
        return scored.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.score != b.score { return a.score > b.score }
            if a.ranked.entry.pinned != b.ranked.entry.pinned { return a.ranked.entry.pinned }
            if a.frecency != b.frecency { return a.frecency > b.frecency }
            return a.ranked.entry.title.localizedStandardCompare(b.ranked.entry.title) == .orderedAscending
        }.map(\.ranked)
    }

    /// What shows before anything is typed (§9.3): **waiting** (requests and errors, oldest first, then
    /// finished, oldest first), **pinned** Claudes, **recent** places (`recent`, newest first, at most
    /// 8), and the **commands** used most lately (at most 6), each entry once.
    public struct Sections: Sendable, Equatable {
        public var waiting: [PaletteEntry] = []
        public var pinned: [PaletteEntry] = []
        public var recent: [PaletteEntry] = []
        public var commands: [PaletteEntry] = []
    }

    public static func sections(_ entries: [PaletteEntry], recent: [String], usage: PaletteUsage, now: Date) -> Sections {
        var sections = Sections()
        var used: Set<String> = []
        func oldest(_ status: AgentStatus) -> [PaletteEntry] {
            entries.filter { $0.kind == .claude && $0.status == status }.sorted { ($0.since ?? now) < ($1.since ?? now) }
        }
        // An entry already listed, or one in a tab already listed, is not listed again.
        func unused(_ entry: PaletteEntry) -> Bool { !used.contains(entry.id) && !(entry.tab.map(used.contains) ?? false) }
        func use(_ listed: [PaletteEntry]) { used.formUnion(listed.flatMap { [$0.id] + ($0.tab.map { [$0] } ?? []) }) }
        sections.waiting = oldest(.blocked) + oldest(.done)
        use(sections.waiting)
        sections.pinned = entries.filter { $0.pinned && unused($0) }
        use(sections.pinned)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sections.recent = Array(recent.compactMap { byID[$0] }.filter(unused).prefix(8))
        sections.commands = Array(entries.filter { $0.kind == .command }
            .map { ($0, usage.score($0.id, now: now)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(6)
            .map(\.0))
        return sections
    }
}
