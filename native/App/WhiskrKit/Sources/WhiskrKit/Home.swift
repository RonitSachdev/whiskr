import Foundation

/// Home (docs/DESIGN.md): the place with no workspace selected, where a launch lands and a closed
/// workspace returns you. Its page lists the workspaces open now, then recent folders.
public enum HomeList {
    /// A workspace as Home reads it.
    public struct Workspace: Sendable {
        public var id: UUID
        public var name: String
        public var folder: String
        public var branch: String?
        public var colorIndex: Int
        /// Each Claude in it (helpers in terminals of their own included): its state, and whether its turn
        /// stopped on an error.
        public var claudes: [(status: AgentStatus, failed: Bool)]

        public init(id: UUID, name: String, folder: String, branch: String?, colorIndex: Int, claudes: [(status: AgentStatus, failed: Bool)]) {
            self.id = id
            self.name = name
            self.folder = folder
            self.branch = branch
            self.colorIndex = colorIndex
            self.claudes = claudes
        }
    }

    /// How a workspace stands, in the app's words: the most urgent of its Claudes.
    public enum State: Sendable, Equatable {
        /// A request, or (`failed`) a turn that stopped on an error and has not been seen.
        case needsYou(failed: Bool)
        case finished
        case working
        /// Nothing waiting: Claudes idle or not reported yet, or no Claude at all.
        case idle
    }

    /// One row under Open.
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var folder: String
        public var branch: String?
        public var colorIndex: Int
        public var state: State
        public var claudes: Int
        /// Its number in Go › Workspace (⌥⌘1…9), while it has one.
        public var number: Int?
    }

    /// The open workspaces, in the meadow's order: the order of their blankets and of ⌥⌘1…9, so a row
    /// never moves because a Claude did something.
    public static func open(_ workspaces: [Workspace]) -> [Row] {
        workspaces.enumerated().map { index, workspace in
            Row(id: workspace.id, name: workspace.name, folder: workspace.folder, branch: workspace.branch, colorIndex: workspace.colorIndex,
                state: state(of: workspace.claudes), claudes: workspace.claudes.count, number: index < 9 ? index + 1 : nil)
        }
    }

    static func state(of claudes: [(status: AgentStatus, failed: Bool)]) -> State {
        guard let most = claudes.map(\.status).min() else { return .idle }
        switch most {
        case .blocked:
            // A request outranks an error: the error mark shows only when every one waiting is an error.
            return .needsYou(failed: claudes.filter { $0.status == .blocked }.allSatisfy(\.failed))
        case .done: return .finished
        case .working: return .working
        case .idle, .unknown: return .idle
        }
    }

    /// The recent folders Home offers under Recent: File › Open Recent's list without the folders already
    /// listed under Open.
    public static func recents(_ recents: [RecentFolder], open: [String]) -> [RecentFolder] {
        let listed = Set(open)
        return recents.filter { !listed.contains($0.path) }
    }

    /// Type-select, as the meadow and Finder have it: the first name (from `start`, wrapping) beginning
    /// with what was typed; nil when none does.
    public static func typeSelect(_ typed: String, in names: [String], from start: Int = 0) -> Int? {
        guard !typed.isEmpty, !names.isEmpty else { return nil }
        let wanted = typed.lowercased()
        let count = names.count
        let first = min(max(start, 0), count - 1)
        return (0..<count).map { (first + $0) % count }.first { names[$0].lowercased().hasPrefix(wanted) }
    }
}

/// Which workspace is selected around closes; nil is Home.
public enum HomeRules {
    /// After `closed` has closed: Home when it was the one shown (you never land in another workspace's
    /// terminal), otherwise whatever was shown stays.
    public static func selection(afterClosing closed: UUID, selected: UUID?) -> UUID? {
        selected == closed ? nil : selected
    }
}

/// What a launch does with each saved pane (docs/ARCHITECTURE.md): nothing is typed into a terminal at
/// launch except to bring back a Claude whose terminal is gone.
public enum ResumePlan {
    public enum Action: Sendable, Equatable {
        /// The session host still holds its terminal: shown as it was, nothing typed.
        case attach
        /// A fresh shell in its folder, nothing typed.
        case freshShell
        /// A fresh shell that types `claude --resume <id>`: its Claude ended with its terminal (a restart).
        case resume
    }

    /// - Parameters:
    ///   - held: the host this app uses holds the pane's terminal.
    ///   - claudeSession: Claude ran in it when the app quit, with a session that can be resumed.
    ///   - resumeEnabled: Settings › Resume Claude in restored panes.
    ///   - otherHosts: another version's or the earlier-named app's session host holds terminals. Its
    ///     Claudes may be this pane's, alive there: resuming would start a second one on the same
    ///     conversation, so none is resumed (the launch notice says why).
    public static func action(held: Bool, claudeSession: Bool, resumeEnabled: Bool, otherHosts: Bool) -> Action {
        if held { return .attach }
        return claudeSession && resumeEnabled && !otherHosts ? .resume : .freshShell
    }
}

extension Places {
    /// A folder short enough for a status bar: home as "~", and anything deeper than two folders below it
    /// (or below "/") as its last two behind "…": `~/…/Developer/shop`.
    public static func short(_ path: String, home: String) -> String {
        let abbreviated = abbreviate(path, home: home)
        let underHome = abbreviated.hasPrefix("~")
        let parts = abbreviated.split(separator: "/", omittingEmptySubsequences: true).map(String.init).dropFirst(underHome ? 1 : 0)
        guard parts.count > 2 else { return abbreviated }
        return (underHome ? "~" : "") + "/…/" + parts.suffix(2).joined(separator: "/")
    }
}
