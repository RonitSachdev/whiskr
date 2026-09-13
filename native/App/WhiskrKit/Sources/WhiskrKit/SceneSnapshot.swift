import Foundation

/// What the meadow scene shows of the workbench, as plain values: the app builds it from its model
/// (`Workbench.scene`) and `WhiskrMeadow` turns it into the scene's own world.
///
/// Mapping (docs/DESIGN.md): a space is a mown patch, a tab a blanket, an agent pane a cat (with
/// its helpers huddled by it), a plain terminal pane a lantern.
public struct SceneSnapshot: Equatable, Sendable {
    public var spaces: [Space]
    public var selectedSpace: UUID?
    public var selectedBlanket: UUID?
    public var focusedPane: UUID?
    /// The agent of the focused pane's session that was last chosen (a helper's id, from clicking its
    /// cat); nil for the session's own main agent.
    public var focusedAgent: String?

    public init(spaces: [Space], selectedSpace: UUID? = nil, selectedBlanket: UUID? = nil, focusedPane: UUID? = nil, focusedAgent: String? = nil) {
        self.spaces = spaces
        self.selectedSpace = selectedSpace
        self.selectedBlanket = selectedBlanket
        self.focusedPane = focusedPane
        self.focusedAgent = focusedAgent
    }

    public struct Space: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let folder: String
        /// The most urgent state of its agents; nil when it has none.
        public let status: AgentStatus?
        public let blankets: [Blanket]

        public init(id: UUID, name: String, folder: String, status: AgentStatus?, blankets: [Blanket]) {
            self.id = id; self.name = name; self.folder = folder; self.status = status; self.blankets = blankets
        }
    }

    public struct Blanket: Equatable, Identifiable, Sendable {
        public let id: UUID
        /// The flag by the blanket: the workspace's name.
        public let title: String
        public let status: AgentStatus?
        public let panes: [Pane]
        /// Its own colour, one of the six blanket colours, kept for its life; nil to take the first
        /// cat's account colour (grey with no cat).
        public let colorIndex: Int?
        /// The git branch checked out where the workspace is, for its flag; nil outside a repository.
        public let branch: String?
        /// A Claude on it is pinned.
        public let pinned: Bool
        /// The branch's commits not yet pushed and not yet pulled, and whether files have changed, when
        /// known (read off the main thread); nil outside a repository.
        public let changes: BranchChanges?
        /// The workspace of the repository this one is a worktree of, when that is open too: its blanket
        /// lies beside that one's, joined by a path.
        public let joinedTo: UUID?

        public init(id: UUID, title: String, status: AgentStatus?, panes: [Pane], colorIndex: Int? = nil, branch: String? = nil, pinned: Bool = false,
                    changes: BranchChanges? = nil, joinedTo: UUID? = nil) {
            self.id = id; self.title = title; self.status = status; self.panes = panes; self.colorIndex = colorIndex
            self.branch = branch; self.pinned = pinned; self.changes = changes; self.joinedTo = joinedTo
        }
    }

    public struct Pane: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let kind: Kind
        /// The pane whose program started this one's terminal (`paw run`): its cat is a helper of that
        /// pane's cat, on the same blanket.
        public let parent: UUID?

        public init(id: UUID, name: String, kind: Kind, parent: UUID? = nil) {
            self.id = id; self.name = name; self.kind = kind; self.parent = parent
        }
    }

    /// A branch against its upstream, and the working tree's changes.
    public struct BranchChanges: Equatable, Sendable {
        public let ahead: Int
        public let behind: Int
        public let dirty: Bool

        public init(ahead: Int, behind: Int, dirty: Bool) {
            self.ahead = ahead; self.behind = behind; self.dirty = dirty
        }
    }

    public enum Kind: Equatable, Sendable {
        /// A cat. `accountIndex` picks its blanket colour; `failed` is a turn that stopped on an error
        /// not yet seen; `agents` is the session's family (main first, each helper under whoever
        /// launched it), empty until the session first reports.
        case agent(status: AgentStatus, accountIndex: Int, failed: Bool, agents: [AgentSnapshot])
        /// A lantern: lit while a command runs in it, dark while its shell waits or once it has ended
        /// well, red if it ended badly.
        case terminal(lantern: Lantern)
    }

    public enum Lantern: Equatable, Sendable {
        case lit
        case dark
        case failed(code: Int32)
    }
}

public extension SceneSnapshot {
    func blanket(_ id: UUID) -> Blanket? {
        for space in spaces {
            if let blanket = space.blankets.first(where: { $0.id == id }) { return blanket }
        }
        return nil
    }

    /// The pane and the blanket it lies on.
    func pane(_ id: UUID) -> (blanket: Blanket, pane: Pane)? {
        for space in spaces {
            for blanket in space.blankets {
                if let pane = blanket.panes.first(where: { $0.id == id }) { return (blanket, pane) }
            }
        }
        return nil
    }
}
