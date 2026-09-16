import Foundation
import MeadowScene
import WhiskrKit

/// The app's model as the meadow sees it, and the meadow's clicks as the app's selections.
///
/// Ids are the app's own, so they never change while a thing exists and the scene can tell what moved,
/// arrived or left: a blanket is its workspace's id, a cat its pane's id (a helper `<pane>/<agent id>`, its
/// agent id being Claude Code's own), a lantern its pane's id.
public enum MeadowMapping {
    public static let machineID = "this-mac"
    /// The blanket of a tab with no agent on it: plain grey gingham, belonging to no account.
    public static let neutralBlanket: UInt32 = 0xa9a9ae

    // MARK: Model → world

    public static func world(_ snapshot: SceneSnapshot, accountColors: [UInt32], machineName: String) -> MeadowWorld {
        let spaces = snapshot.spaces.map { space in
            MeadowSpace(id: space.id.uuidString, name: space.name, blankets: space.blankets.map { blanket($0, accountColors: accountColors) })
        }
        return MeadowWorld(machines: [MeadowMachine(id: machineID, name: machineName, isLocal: true, spaces: spaces)])
    }

    static func blanket(_ blanket: SceneSnapshot.Blanket, accountColors: [UInt32]) -> MeadowBlanket {
        var agents: [MeadowAgent] = []
        var lanterns: [MeadowLantern] = []
        var account: Int?
        let agentPanes = Set(blanket.panes.compactMap { pane -> UUID? in if case .agent = pane.kind { pane.id } else { nil } })
        for pane in helpersAfterBosses(blanket.panes) {
            switch pane.kind {
            case .agent(let status, let accountIndex, let failed, let family):
                if account == nil, pane.parent == nil { account = accountIndex }
                // A terminal an agent started is that agent's helper: its cat sits by its boss's.
                let boss = pane.parent.flatMap { agentPanes.contains($0) ? catID(pane: $0, agent: nil) : nil }
                agents += cats(pane: pane, status: status, failed: failed, family: family, boss: boss)
            case .terminal(let lantern, let shell):
                lanterns.append(MeadowLantern(id: pane.id.uuidString, title: pane.name, state: state(of: lantern), command: command(shell)))
            }
        }
        let pick = blanket.colorIndex ?? account
        let hex = pick.map { accountColors.isEmpty ? neutralBlanket : accountColors[(($0 % accountColors.count) + accountColors.count) % accountColors.count] } ?? neutralBlanket
        return MeadowBlanket(id: blanket.id.uuidString, title: blanket.title, color: MeadowColor(hex: hex), state: .live, agents: agents, lanterns: lanterns,
                             detail: flagDetail(title: blanket.title, branch: blanket.branch, changes: blanket.changes), pinned: blanket.pinned,
                             joinedTo: blanket.joinedTo?.uuidString)
    }

    /// The flag's quieter line: the branch (left out when the workspace is named after it, as a
    /// worktree's is), then ↑ commits to push, ↓ to pull, and • when files have changed.
    static func flagDetail(title: String, branch: String?, changes: SceneSnapshot.BranchChanges?) -> String? {
        guard let branch else { return nil }
        var parts = branch == title ? [] : [branch]
        if let changes {
            var marks = ""
            if changes.ahead > 0 { marks += "↑\(changes.ahead)" }
            if changes.behind > 0 { marks += (marks.isEmpty ? "" : " ") + "↓\(changes.behind)" }
            if changes.dirty { marks += (marks.isEmpty ? "" : " ") + "•" }
            if !marks.isEmpty { parts.append(marks) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The panes in the order the scene needs them: a pane started by another pane's program after it,
    /// so a helper's boss is always met first; otherwise as given.
    static func helpersAfterBosses(_ panes: [SceneSnapshot.Pane]) -> [SceneSnapshot.Pane] {
        let ids = Set(panes.map(\.id))
        var placed: Set<UUID> = []
        var ordered: [SceneSnapshot.Pane] = []
        var waiting = panes
        while !waiting.isEmpty {
            let ready = waiting.filter { pane in pane.parent.map { !ids.contains($0) || placed.contains($0) } ?? true }
            // A loop (it cannot happen, but) is laid as given rather than lost.
            let next = ready.isEmpty ? waiting : ready
            ordered += next
            placed.formUnion(next.map(\.id))
            waiting.removeAll { placed.contains($0.id) }
        }
        return ordered
    }

    /// One pane's cats: its session's main agent and every helper, each by whoever launched it. `boss`:
    /// the cat whose program started this pane's terminal, for whom its main cat is a helper.
    static func cats(pane: SceneSnapshot.Pane, status: AgentStatus, failed: Bool, family: [AgentSnapshot], boss: String? = nil) -> [MeadowAgent] {
        guard !family.isEmpty else {
            // Not reported yet (Claude has just started, or runs without our hooks): awake at its prompt.
            return [MeadowAgent(id: catID(pane: pane.id, agent: nil), parentID: boss, activity: .awake,
                                needsYou: status == .blocked && !failed, doneUnseen: status == .done, failed: failed, name: pane.name)]
        }
        return family.map { agent in
            let main = agent.parentID == nil
            var activity = AgentActivity(rawValue: agent.activity.rawValue) ?? .awake
            // Idle and seen, at its prompt: a loaf (only the main cat; helpers are always busy or gone).
            if main && status == .idle && activity == .awake { activity = .idle }
            return MeadowAgent(
                id: catID(pane: pane.id, agent: agent.id),
                parentID: main ? boss : catID(pane: pane.id, agent: agent.parentID),
                activity: activity,
                needsYou: agent.activity == .asking,
                doneUnseen: main && agent.status == .done,
                failed: main && failed,
                name: main ? pane.name : agent.kind)
        }
    }

    static func state(of lantern: SceneSnapshot.Lantern) -> MeadowLantern.State {
        switch lantern {
        case .lit: .running
        case .dark: .finished
        case .failed: .failed
        }
    }

    static func command(_ command: SceneSnapshot.Command) -> MeadowCommand {
        switch command {
        case .idle: .idle
        case .running: .running
        case .finished: .finished
        case .failed: .failed
        }
    }

    /// What a blanket's kettle says, over all its plain terminals, while no Claude is on it (nil when there
    /// is a Claude, or no plain terminal): a command running in one, a failure not yet seen in one, the last
    /// ending well. For VoiceOver, which reads the blanket as the kettle shows it.
    public static func kettle(of blanket: SceneSnapshot.Blanket) -> (running: Bool, failed: Bool, finished: Bool)? {
        var commands: [SceneSnapshot.Command] = []
        for pane in blanket.panes {
            switch pane.kind {
            case .agent: return nil
            case .terminal(_, let command): commands.append(command)
            }
        }
        guard !commands.isEmpty else { return nil }
        let running = commands.contains(.running), failed = commands.contains(.failed)
        return (running, failed, !running && !failed && commands.contains(.finished))
    }

    /// A cat's id: the pane's for its session's own agent, `<pane>/<agent>` for a helper.
    public static func catID(pane: UUID, agent: String?) -> String {
        guard let agent, agent != AgentWorld.mainAgent else { return pane.uuidString }
        return "\(pane.uuidString)/\(agent)"
    }

    // MARK: Clicks → selections

    /// What a click in the meadow chooses in the app.
    public enum Target: Equatable, Sendable {
        case blanket(UUID)
        /// A pane; `agent` is the helper chosen when its cat was clicked (nil for the pane itself).
        case pane(UUID, agent: String?)
    }

    public static func target(of item: MeadowItem) -> Target? {
        switch item {
        case .blanket(let id):
            return UUID(uuidString: id).map(Target.blanket)
        case .cat(_, let agent):
            let parts = agent.split(separator: "/", maxSplits: 1).map(String.init)
            guard let first = parts.first, let pane = UUID(uuidString: first) else { return nil }
            return .pane(pane, agent: parts.count > 1 ? parts[1] : nil)
        case .lantern(_, let lantern):
            return UUID(uuidString: lantern).map { .pane($0, agent: nil) }
        }
    }

    /// What to ring for the app's selection: the cat of the focused pane's Claude (a helper's when one was
    /// chosen), so you can see which terminal is which cat; the focused lantern when the blanket holds
    /// several panes; else the blanket of the selected tab.
    public static func selection(in snapshot: SceneSnapshot) -> MeadowItem? {
        guard let tab = snapshot.selectedBlanket, let blanket = snapshot.blanket(tab) else { return nil }
        let blanketID = tab.uuidString
        guard let focused = snapshot.focusedPane, let pane = blanket.panes.first(where: { $0.id == focused }) else { return .blanket(blanketID) }
        switch pane.kind {
        case .agent(_, _, _, let family):
            if let helper = snapshot.focusedAgent, helper != AgentWorld.mainAgent, family.contains(where: { $0.id == helper }) {
                return .cat(blanket: blanketID, agent: catID(pane: pane.id, agent: helper))
            }
            return .cat(blanket: blanketID, agent: catID(pane: pane.id, agent: nil))
        case .terminal:
            return blanket.panes.count > 1 ? .lantern(blanket: blanketID, lantern: pane.id.uuidString) : .blanket(blanketID)
        }
    }

    // MARK: Pointing

    /// What the pointer is over, for the name note: the words come from the app (they are translated
    /// there), the facts from here.
    public struct Hover: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case blanket(status: AgentStatus?)
            case agent(status: AgentStatus, line: String?)
            case helper(line: String)
            case lantern(SceneSnapshot.Lantern)
        }
        public let name: String
        public let kind: Kind
        public init(name: String, kind: Kind) { self.name = name; self.kind = kind }
    }

    public static func hover(_ item: MeadowItem, in snapshot: SceneSnapshot) -> Hover? {
        switch target(of: item) {
        case .blanket(let id):
            return snapshot.blanket(id).map { Hover(name: $0.title, kind: .blanket(status: $0.status)) }
        case .pane(let id, let helper):
            guard let (_, pane) = snapshot.pane(id) else { return nil }
            switch pane.kind {
            case .agent(let status, _, _, let family):
                if let helper, let agent = family.first(where: { $0.id == helper }) {
                    return Hover(name: agent.kind, kind: .helper(line: agent.line))
                }
                return Hover(name: pane.name, kind: .agent(status: status, line: family.first?.line))
            case .terminal(let lantern, _):
                return Hover(name: pane.name, kind: .lantern(lantern))
            }
        case nil:
            return nil
        }
    }

    // MARK: Settings and theme

    /// The app's meadow is its sidebar: one column of workspaces. The sun and moon are reckoned for where
    /// real weather last found you, or else a place guessed from `timeZone`. `stoppedAt` stops the clock
    /// there (the debug harness's fixed moments).
    public static func settings(_ world: WorldSettings, weather: MeadowWeather?, chrome: MeadowChrome,
                                arrangement: MeadowSettings.Arrangement = .column, timeZone: TimeZone = .current,
                                stoppedAt: Date? = nil) -> MeadowSettings {
        let time: MeadowSettings.TimeOfDay = switch world.timeOfDay {
        case .followClock: stoppedAt.map { .instant($0) } ?? .followClock
        case .day: .day
        case .night: .night
        }
        let picnic: MeadowSettings.Picnic = switch world.picnic {
        case .nothing: .none
        case .hamper: .hamper
        case .spread: .spread
        }
        var effects = MeadowSettings.Effects()
        for (on, effect) in [(world.sunTimes, MeadowSettings.Effects.sunTimes), (world.moonPhase, .moonPhase), (world.clouds, .clouds),
                             (world.wind, .wind), (world.rainAndSnow, .rainAndSnow), (world.lightning, .lightning), (world.grassColor, .grassColor)] where on {
            effects.insert(effect)
        }
        return MeadowSettings(map: MeadowSettings.Map(rawValue: world.map.rawValue) ?? .meadow, arrangement: arrangement, timeOfDay: time,
                              weather: world.realWeather ? weather : nil, place: place(world, timeZone: timeZone), effects: effects, picnic: picnic,
                              flagSize: Float(world.flagSize.scale), chrome: chrome)
    }

    /// Where the sun and moon are reckoned for: where real weather last found you (kept even while weather
    /// is off; it never leaves the Mac for this), or else a guess from the time zone. Never asks.
    public static func place(_ world: WorldSettings, timeZone: TimeZone = .current) -> MeadowPlace {
        world.place.map { MeadowPlace(latitude: $0.latitude, longitude: $0.longitude) } ?? .estimate(for: timeZone)
    }

    /// The theme's surface, text and "needs you" red, for the scene's flags, rings and bubble, and the
    /// system accent colour (sRGB, 0…1) for the keyboard's focus ring.
    public static func chrome(_ variant: ThemeVariant, focus: (red: Double, green: Double, blue: Double) = (0, 0.478, 1)) -> MeadowChrome {
        func color(_ key: AppColorKey) -> MeadowColor {
            let c = variant.app[key]
            return MeadowColor(red: Float(c.red), green: Float(c.green), blue: Float(c.blue))
        }
        return MeadowChrome(surface: color(.surface), ink: color(.text), alert: color(.needsYou),
                            focus: MeadowColor(red: Float(focus.red), green: Float(focus.green), blue: Float(focus.blue)))
    }
}
