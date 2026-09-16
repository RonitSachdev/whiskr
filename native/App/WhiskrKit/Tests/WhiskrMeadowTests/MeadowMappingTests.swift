import Foundation
import MeadowScene
import Testing
import WhiskrKit
@testable import WhiskrMeadow

/// A session's agents as the app would see them, from real hook events.
private func family(_ events: [(String, [String: JSONValue])]) -> (agents: [AgentSnapshot], session: SessionSnapshot) {
    var world = AgentWorld()
    let now = Date(timeIntervalSince1970: 1_000_000)
    for (event, extra) in events {
        var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": "s1", "cwd": "/code/shop", "transcript_path": "/t/s1.jsonl"]
        payload.merge(extra) { _, new in new }
        _ = world.ingest(.object(payload), account: "personal", paneID: "pane", now: now)
    }
    let session = world.snapshots[0]
    return (session.agents.familyOrder, session)
}

private let prompt: (String, [String: JSONValue]) = ("UserPromptSubmit", [:])
private let launch: (String, [String: JSONValue]) = ("PreToolUse", ["tool_name": "Agent", "tool_use_id": "t1", "tool_input": ["subagent_type": "Explore", "description": "Map the cart"]])
private let helperStarts: (String, [String: JSONValue]) = ("SubagentStart", ["agent_id": "a1", "agent_type": "Explore"])
private let helperAsks: (String, [String: JSONValue]) = ("PermissionRequest", ["tool_name": "Bash", "agent_id": "a1", "tool_input": ["command": "npm test"]])

@Suite("The model as the meadow's world")
struct MeadowMappingTests {
    let space = UUID(), tab = UUID(), claude = UUID(), shell = UUID(), server = UUID()
    let colors: [UInt32] = [0x2fb39a, 0xf0606e]

    func snapshot(agent: SceneSnapshot.Kind, lanterns: [(UUID, SceneSnapshot.Lantern)] = [], focused: UUID? = nil, helper: String? = nil, title: String = "Fix rounding") -> SceneSnapshot {
        var panes = [SceneSnapshot.Pane(id: claude, name: "Fix rounding", kind: agent)]
        panes += lanterns.map { SceneSnapshot.Pane(id: $0.0, name: "npm run dev", kind: .terminal(lantern: $0.1, command: .idle)) }
        let blanket = SceneSnapshot.Blanket(id: tab, title: title, status: .working, panes: panes)
        return SceneSnapshot(spaces: [SceneSnapshot.Space(id: space, name: "shop", folder: "/code/shop", status: .working, blankets: [blanket])],
                             selectedSpace: space, selectedBlanket: tab, focusedPane: focused ?? claude, focusedAgent: helper)
    }

    @Test("one machine, a space per space, a blanket per tab with its title and account colour")
    func structure() {
        let (agents, _) = family([prompt])
        let world = MeadowMapping.world(snapshot(agent: .agent(status: .working, accountIndex: 1, failed: false, agents: agents)), accountColors: colors, machineName: "This Mac")
        #expect(world.machines.count == 1)
        #expect(world.machines[0].isLocal)
        #expect(world.machines[0].spaces.map(\.id) == [space.uuidString])
        let blanket = world.blankets[0]
        #expect(blanket.id == tab.uuidString)
        #expect(blanket.title == "Fix rounding")
        #expect(blanket.color == MeadowColor(hex: 0xf0606e))
        #expect(blanket.state == .live)
    }

    @Test("a tab with no agent lies on plain grey; account indexes wrap round the colours")
    func colours() {
        let lanternOnly = SceneSnapshot(spaces: [SceneSnapshot.Space(id: space, name: "shop", folder: "/", status: nil, blankets: [
            SceneSnapshot.Blanket(id: tab, title: "zsh", status: nil, panes: [SceneSnapshot.Pane(id: shell, name: "zsh", kind: .terminal(lantern: .dark, command: .idle))]),
        ])])
        #expect(MeadowMapping.world(lanternOnly, accountColors: colors, machineName: "").blankets[0].color == MeadowColor(hex: MeadowMapping.neutralBlanket))
        let wrapped = MeadowMapping.world(snapshot(agent: .agent(status: .idle, accountIndex: 3, failed: false, agents: [])), accountColors: colors, machineName: "")
        #expect(wrapped.blankets[0].color == MeadowColor(hex: 0xf0606e))
    }

    @Test("ids are the app's own and stay put when unrelated state changes")
    func stableIDs() {
        let before = family([prompt, launch, helperStarts]).agents
        let after = family([prompt, launch, helperStarts, helperAsks]).agents
        let a = MeadowMapping.world(snapshot(agent: .agent(status: .working, accountIndex: 0, failed: false, agents: before), lanterns: [(shell, .lit)]), accountColors: colors, machineName: "")
        let b = MeadowMapping.world(snapshot(agent: .agent(status: .blocked, accountIndex: 0, failed: false, agents: after), lanterns: [(shell, .dark)], title: "Renamed"), accountColors: colors, machineName: "")
        #expect(a.blankets[0].id == b.blankets[0].id)
        #expect(a.blankets[0].agents.map(\.id) == b.blankets[0].agents.map(\.id))
        #expect(a.blankets[0].lanterns.map(\.id) == b.blankets[0].lanterns.map(\.id))
        #expect(a.blankets[0].agents.map(\.id) == [claude.uuidString, "\(claude.uuidString)/a1"])
    }

    @Test("a helper is a cat seated by its boss, and asks with the red bubble")
    func helpers() {
        let (agents, _) = family([prompt, launch, helperStarts, helperAsks])
        let cats = MeadowMapping.world(snapshot(agent: .agent(status: .blocked, accountIndex: 0, failed: false, agents: agents)), accountColors: colors, machineName: "").blankets[0].agents
        #expect(cats.count == 2)
        #expect(cats[0].parentID == nil)
        #expect(cats[0].name == "Fix rounding")
        #expect(cats[1].parentID == claude.uuidString)
        #expect(cats[1].name == "Explore")
        #expect(cats[1].needsYou)
        #expect(cats[1].activity == .asking)
        #expect(!cats[0].needsYou)
    }

    @Test("states: working, done until seen, failed, and a pane not yet reported")
    func states() {
        let working = family([prompt]).agents
        let main = MeadowMapping.world(snapshot(agent: .agent(status: .working, accountIndex: 0, failed: false, agents: working)), accountColors: colors, machineName: "").blankets[0].agents[0]
        #expect(main.activity == .thinking)
        #expect(!main.doneUnseen && !main.failed && !main.needsYou)

        let finished = family([prompt, ("Stop", [:])]).agents
        let done = MeadowMapping.world(snapshot(agent: .agent(status: .done, accountIndex: 0, failed: false, agents: finished)), accountColors: colors, machineName: "").blankets[0].agents[0]
        #expect(done.doneUnseen)

        let failed = MeadowMapping.world(snapshot(agent: .agent(status: .blocked, accountIndex: 0, failed: true, agents: finished)), accountColors: colors, machineName: "").blankets[0].agents[0]
        #expect(failed.failed)
        #expect(!failed.needsYou)

        let starting = MeadowMapping.world(snapshot(agent: .agent(status: .unknown, accountIndex: 0, failed: false, agents: [])), accountColors: colors, machineName: "").blankets[0].agents
        #expect(starting.count == 1)
        #expect(starting[0].id == claude.uuidString)
        #expect(starting[0].activity == .awake)
    }

    @Test("plain terminal panes are lanterns: running, finished, failed")
    func lanterns() {
        let world = MeadowMapping.world(snapshot(agent: .agent(status: .idle, accountIndex: 0, failed: false, agents: []),
                                                 lanterns: [(shell, .lit), (server, .dark), (UUID(), .failed(code: 2))]), accountColors: colors, machineName: "")
        #expect(world.blankets[0].lanterns.map(\.state) == [.running, .finished, .failed])
        #expect(world.blankets[0].lanterns[0].id == shell.uuidString)
    }

    @Test("clicks come back as the tab, the pane, or the helper's boss pane with the helper")
    func clicks() {
        #expect(MeadowMapping.target(of: .blanket(tab.uuidString)) == .blanket(tab))
        #expect(MeadowMapping.target(of: .cat(blanket: tab.uuidString, agent: claude.uuidString)) == .pane(claude, agent: nil))
        #expect(MeadowMapping.target(of: .cat(blanket: tab.uuidString, agent: "\(claude.uuidString)/a1")) == .pane(claude, agent: "a1"))
        #expect(MeadowMapping.target(of: .lantern(blanket: tab.uuidString, lantern: shell.uuidString)) == .pane(shell, agent: nil))
        #expect(MeadowMapping.target(of: .blanket("not-an-id")) == nil)
    }

    @Test("the ring: the focused Claude's cat (a chosen helper's), the focused lantern of several panes, else the blanket")
    func selection() {
        let agents = family([prompt, launch, helperStarts]).agents
        let kind = SceneSnapshot.Kind.agent(status: .working, accountIndex: 0, failed: false, agents: agents)
        let cat = MeadowItem.cat(blanket: tab.uuidString, agent: claude.uuidString)
        // The one Claude on its blanket is ringed too: which terminal is which cat shows at a glance.
        #expect(MeadowMapping.selection(in: snapshot(agent: kind)) == cat)
        #expect(MeadowMapping.selection(in: snapshot(agent: kind, helper: "a1")) == .cat(blanket: tab.uuidString, agent: "\(claude.uuidString)/a1"))
        #expect(MeadowMapping.selection(in: snapshot(agent: kind, helper: "gone")) == cat)
        #expect(MeadowMapping.selection(in: snapshot(agent: kind, lanterns: [(shell, .lit)], focused: shell)) == .lantern(blanket: tab.uuidString, lantern: shell.uuidString))
        #expect(MeadowMapping.selection(in: snapshot(agent: kind, lanterns: [(shell, .lit)])) == cat)
        // Claude just started, not reported yet: its cat all the same.
        let fresh = SceneSnapshot.Kind.agent(status: .idle, accountIndex: 0, failed: false, agents: [])
        #expect(MeadowMapping.selection(in: snapshot(agent: fresh)) == cat)
        var none = snapshot(agent: kind)
        none.selectedBlanket = nil
        #expect(MeadowMapping.selection(in: none) == nil)
    }

    @Test("pointing names the thing pointed at")
    func hover() {
        let agents = family([prompt, launch, helperStarts]).agents
        let s = snapshot(agent: .agent(status: .working, accountIndex: 0, failed: false, agents: agents), lanterns: [(shell, .lit)])
        #expect(MeadowMapping.hover(.blanket(tab.uuidString), in: s)?.name == "Fix rounding")
        #expect(MeadowMapping.hover(.cat(blanket: tab.uuidString, agent: "\(claude.uuidString)/a1"), in: s)?.name == "Explore")
        #expect(MeadowMapping.hover(.lantern(blanket: tab.uuidString, lantern: shell.uuidString), in: s) == MeadowMapping.Hover(name: "npm run dev", kind: .lantern(.lit)))
    }

    @Test("world settings become the scene's settings; weather only while it is on")
    func settings() {
        let weather = MeadowWeather(sky: .rain, cover: 0.9, windKmh: 20, temperatureC: 9)
        var world = WorldSettings(timeOfDay: .night, picnic: .nothing, flagSize: .large, realWeather: false)
        var scene = MeadowMapping.settings(world, weather: weather, chrome: .standard)
        #expect(scene.timeOfDay == .night)
        #expect(scene.picnic == .none)
        #expect(scene.flagSize == 1.3)
        #expect(scene.weather == nil)
        #expect(scene.map == .meadow)
        world.realWeather = true
        scene = MeadowMapping.settings(world, weather: weather, chrome: .standard)
        #expect(scene.weather == weather)
    }

    @Test("each switch becomes the scene's effect; the sun is reckoned where weather found you, else from the time zone")
    func skyEffects() throws {
        var world = WorldSettings()
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var scene = MeadowMapping.settings(world, weather: nil, chrome: .standard, timeZone: tokyo)
        #expect(scene.effects == .all)
        #expect(scene.place == MeadowPlace.estimate(for: tokyo))
        #expect(scene.timeOfDay == .followClock)
        let switches: [(WritableKeyPath<WorldSettings, Bool>, MeadowSettings.Effects)] = [
            (\.sunTimes, .sunTimes), (\.moonPhase, .moonPhase), (\.clouds, .clouds), (\.wind, .wind), (\.rainAndSnow, .rainAndSnow),
            (\.lightning, .lightning), (\.grassColor, .grassColor),
        ]
        for (path, effect) in switches {
            var off = world
            off[keyPath: path] = false
            #expect(MeadowMapping.settings(off, weather: nil, chrome: .standard).effects == MeadowSettings.Effects.all.subtracting(effect), "\(effect)")
        }
        world.place = WorldSettings.Place(latitude: 51.51, longitude: -0.13)
        scene = MeadowMapping.settings(world, weather: nil, chrome: .standard, timeZone: tokyo)
        #expect(scene.place == MeadowPlace(latitude: 51.51, longitude: -0.13))
        // A stopped clock (the harness) applies only while following the clock.
        let moment = Date(timeIntervalSince1970: 1_718_900_000)
        #expect(MeadowMapping.settings(world, weather: nil, chrome: .standard, stoppedAt: moment).timeOfDay == .instant(moment))
        world.timeOfDay = .day
        #expect(MeadowMapping.settings(world, weather: nil, chrome: .standard, stoppedAt: moment).timeOfDay == .day)
    }

    @Test("Settings › Meadow's Cats wander when idle reaches the scene")
    func catsWanderReachesTheScene() {
        #expect(MeadowMapping.settings(WorldSettings(), weather: nil, chrome: .standard).catsWander)
        #expect(!MeadowMapping.settings(WorldSettings(catsWander: false), weather: nil, chrome: .standard).catsWander)
    }

    @Test("a plain terminal's command marks reach its lantern, which the blanket's kettle reads", arguments: [
        (SceneSnapshot.Command.idle, MeadowCommand.idle), (.running, .running), (.finished, .finished), (.failed, .failed),
    ])
    func commandReachesTheKettle(_ given: SceneSnapshot.Command, _ shown: MeadowCommand) {
        let plain = SceneSnapshot(spaces: [SceneSnapshot.Space(id: space, name: "shop", folder: "/", status: nil, blankets: [
            SceneSnapshot.Blanket(id: tab, title: "zsh", status: nil, panes: [SceneSnapshot.Pane(id: shell, name: "zsh", kind: .terminal(lantern: .dark, command: given))]),
        ])])
        let blanket = MeadowMapping.world(plain, accountColors: colors, machineName: "").blankets[0]
        #expect(blanket.agents.isEmpty)
        #expect(blanket.lanterns.map(\.command) == [shown])
    }

    @Test("the kettle VoiceOver reads: running and failed at once, finished only when neither; none beside a Claude")
    func kettleWords() {
        func blanket(_ commands: [SceneSnapshot.Command], claude: Bool = false) -> SceneSnapshot.Blanket {
            var panes = commands.map { SceneSnapshot.Pane(id: UUID(), name: "zsh", kind: .terminal(lantern: .dark, command: $0)) }
            if claude { panes.append(SceneSnapshot.Pane(id: UUID(), name: "Claude", kind: .agent(status: .working, accountIndex: 0, failed: false, agents: []))) }
            return SceneSnapshot.Blanket(id: UUID(), title: "w", status: nil, panes: panes)
        }
        #expect(MeadowMapping.kettle(of: blanket([.idle]))! == (false, false, false))
        #expect(MeadowMapping.kettle(of: blanket([.running, .failed]))! == (true, true, false))
        #expect(MeadowMapping.kettle(of: blanket([.finished, .idle]))! == (false, false, true))
        #expect(MeadowMapping.kettle(of: blanket([.running], claude: true)) == nil)
        #expect(MeadowMapping.kettle(of: blanket([])) == nil)
    }

    @Test("the theme's surface, text and red become the scene's chrome")
    func chrome() throws {
        let theme = try #require(BuiltInThemes.theme(id: BuiltInThemes.defaultID))
        let variant = theme.variant(dark: true)
        let chrome = MeadowMapping.chrome(variant)
        let surface = variant.app[.surface]
        #expect(chrome.surface == MeadowColor(red: Float(surface.red), green: Float(surface.green), blue: Float(surface.blue)))
        #expect(chrome != MeadowMapping.chrome(theme.variant(dark: false)))
    }

    @Test("a workspace's branch and pin reach its flag; the accent colour becomes the focus ring")
    func flagAndFocus() throws {
        let id = UUID()
        let blanket = SceneSnapshot.Blanket(id: id, title: "shop-web", status: nil, panes: [], colorIndex: 0, branch: "fix-cart", pinned: true)
        let mapped = MeadowMapping.blanket(blanket, accountColors: [0x112233])
        #expect(mapped.detail == "fix-cart" && mapped.pinned)
        #expect(MeadowMapping.blanket(SceneSnapshot.Blanket(id: id, title: "a", status: nil, panes: []), accountColors: []).detail == nil)
        let theme = try #require(BuiltInThemes.theme(id: BuiltInThemes.defaultID))
        #expect(MeadowMapping.chrome(theme.variant(dark: false), focus: (1, 0, 0)).focus == MeadowColor(red: 1, green: 0, blue: 0))
    }
}

@Suite("Helper terminals and worktrees in the meadow")
struct MeadowHelperTerminalTests {
    let boss = UUID(), child = UUID(), grandchild = UUID(), shell = UUID(), repo = UUID(), worktree = UUID()

    @Test("A terminal an agent started is a helper cat of that agent's, met after its boss whatever the order")
    func helperTerminals() {
        let (agents, _) = family([prompt])
        let working = SceneSnapshot.Kind.agent(status: .working, accountIndex: 0, failed: false, agents: agents)
        let blanket = SceneSnapshot.Blanket(id: repo, title: "shop", status: .working, panes: [
            SceneSnapshot.Pane(id: grandchild, name: "Tests", kind: .agent(status: .blocked, accountIndex: 0, failed: false, agents: []), parent: child),
            SceneSnapshot.Pane(id: child, name: "Review", kind: working, parent: boss),
            SceneSnapshot.Pane(id: boss, name: "Fix", kind: working),
            SceneSnapshot.Pane(id: shell, name: "npm test", kind: .terminal(lantern: .lit, command: .running), parent: boss),
        ])
        let meadow = MeadowMapping.blanket(blanket, accountColors: [0x2fb39a])
        #expect(meadow.agents.map(\.id) == [boss.uuidString, child.uuidString, grandchild.uuidString])
        #expect(meadow.agents.map(\.parentID) == [nil, boss.uuidString, child.uuidString])
        #expect(meadow.agents.last?.needsYou == true)
        #expect(meadow.lanterns.map(\.id) == [shell.uuidString])
        // A boss that is not an agent (or not on this blanket) leaves the cat a main cat of its own.
        let orphan = SceneSnapshot.Blanket(id: repo, title: "shop", status: .working, panes: [SceneSnapshot.Pane(id: child, name: "Review", kind: working, parent: shell)])
        #expect(MeadowMapping.blanket(orphan, accountColors: []).agents.first?.parentID == nil)
    }

    @Test("A worktree's blanket is joined to its repository's; the flag shows the branch, ahead, behind and changes")
    func worktreesAndFlags() {
        let blanket = SceneSnapshot.Blanket(id: worktree, title: "fix-cart", status: nil, panes: [], branch: "fix-cart",
                                            changes: SceneSnapshot.BranchChanges(ahead: 2, behind: 1, dirty: true), joinedTo: repo)
        let meadow = MeadowMapping.blanket(blanket, accountColors: [])
        #expect(meadow.joinedTo == repo.uuidString)
        #expect(meadow.detail == "↑2 ↓1 •")
        #expect(MeadowMapping.flagDetail(title: "shop", branch: "main", changes: nil) == "main")
        #expect(MeadowMapping.flagDetail(title: "shop", branch: "main", changes: SceneSnapshot.BranchChanges(ahead: 0, behind: 0, dirty: false)) == "main")
        #expect(MeadowMapping.flagDetail(title: "shop", branch: "main", changes: SceneSnapshot.BranchChanges(ahead: 3, behind: 0, dirty: false)) == "main ↑3")
        #expect(MeadowMapping.flagDetail(title: "fix", branch: "fix", changes: nil) == nil)
        #expect(MeadowMapping.flagDetail(title: "shop", branch: nil, changes: SceneSnapshot.BranchChanges(ahead: 1, behind: 0, dirty: true)) == nil)
    }
}
