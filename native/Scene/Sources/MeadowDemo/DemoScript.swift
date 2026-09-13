import AppKit
import MeadowScene

// A made-up afternoon, played into the meadow the way `npm run simulate` plays one into the web version:
// two spaces on this Mac and a devbox across the stream, helpers launching helpers, a permission wait,
// a failure, lanterns for dev servers and tests, a finished turn waiting to be seen, a nap.

@MainActor
final class DemoScript {
    private(set) var world: MeadowWorld
    private var step = 0
    private var timer: Timer?
    private let crowd: Bool

    static func single(_ activity: AgentActivity, needsYou: Bool = false, doneUnseen: Bool = false) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "mac", name: "This Mac", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "playground", title: "Playground", color: .account(0),
                          agents: [MeadowAgent(id: "main", activity: activity, needsYou: needsYou, doneUnseen: doneUnseen)]),
        ])])])
    }

    private let fixed: MeadowWorld?
    init(crowd: Bool, web: Bool = false, officeOnly: Bool = false) {
        self.crowd = crowd
        fixed = web ? Self.webComparison(officeOnly: officeOnly) : nil
        world = fixed ?? (crowd ? Self.crowdWorld(0) : Self.afternoon(0))
    }

    func start(_ show: @escaping @MainActor (MeadowWorld) -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.fixed != nil { return }
                self.step += 1
                self.world = self.crowd ? Self.crowdWorld(self.step) : Self.afternoon(self.step)
                show(self.world)
            }
        }
    }

    private static let work: [AgentActivity] = [.reading, .searching, .editing, .running, .thinking, .tidying]

    nonisolated(unsafe) static var twoMachines = false

    static func afternoon(_ step: Int) -> MeadowWorld {
        let s = step % 24
        func cycle(_ offset: Int) -> AgentActivity { work[(s + offset) % work.count] }

        // shop: the main cat and two helpers, the mapper with two of its own.
        var shopAgents = [MeadowAgent(id: "main", activity: s < 18 ? (s > 6 ? .supervising : cycle(0)) : .awake, doneUnseen: s >= 18, name: "Main")]
        if s >= 2 && s < 16 {
            shopAgents.append(MeadowAgent(id: "mapper", parentID: "main", activity: s > 4 && s < 12 ? .supervising : cycle(1), name: "Explore"))
            shopAgents.append(MeadowAgent(id: "reviewer", parentID: "main", activity: s == 8 || s == 9 ? .asking : cycle(3),
                                          needsYou: s == 8 || s == 9, name: "code-reviewer"))
        }
        if s >= 5 && s < 12 {
            shopAgents.append(MeadowAgent(id: "payments", parentID: "mapper", activity: s == 6 ? .error : cycle(2), failed: s == 6, name: "Explore"))
            shopAgents.append(MeadowAgent(id: "taxes", parentID: "mapper", activity: cycle(4), name: "Explore"))
        }
        let shop = MeadowBlanket(id: "sim-shop", title: "Fix checkout rounding", color: .account(0), agents: shopAgents, lanterns: [
            MeadowLantern(id: "dev", title: "npm run dev", state: .running),
            MeadowLantern(id: "tests", title: "vitest --watch", state: s % 12 == 7 ? .failed : .running),
        ])
        let docs = MeadowBlanket(id: "sim-docs", title: "Write the release notes", color: .account(0),
                                 agents: [MeadowAgent(id: "main", activity: s % 6 < 3 ? .editing : .reading)])
        let api = MeadowBlanket(id: "sim-api", title: "Advisory locks for migrations", color: .account(1), agents: [
            MeadowAgent(id: "main", activity: s < 4 ? .searching : s < 10 ? .editing : s < 14 ? .running : s < 16 ? .tidying : .napping),
        ], lanterns: [MeadowLantern(id: "psql", title: "psql api_dev", state: s < 14 ? .running : .finished)])
        let dotfiles = MeadowBlanket(id: "sim-dotfiles", title: "Tidy dotfiles", color: .account(2), state: .watchOnly,
                                     agents: [MeadowAgent(id: "main", activity: .napping)])
        let importer = MeadowBlanket(id: "sim-import", title: "Nightly data import", color: .account(3), agents: [
            MeadowAgent(id: "main", activity: s % 8 < 4 ? .running : .thinking),
        ], lanterns: [MeadowLantern(id: "log", title: "tail -f importer.log", state: .running)])
        // Remote machines are a later step; a second machine (across a stream) only with --two-machines.
        var machines = [MeadowMachine(id: "mac", name: "This Mac", isLocal: true, spaces: [
            MeadowSpace(id: "shop-web", name: "shop-web", blankets: [shop, docs]),
            MeadowSpace(id: "api-server", name: "api-server", blankets: [api]),
            MeadowSpace(id: "dotfiles", name: "dotfiles", blankets: [dotfiles]),
        ])]
        if twoMachines {
            machines.append(MeadowMachine(id: "devbox", name: "devbox", isLocal: false, spaces: [MeadowSpace(id: "importer", name: "importer", blankets: [importer])]))
        }
        return MeadowWorld(machines: machines)
    }

    /// The three sessions the web version was showing when the comparison shots were taken (same ids, so
    /// the same seats and places), all in one space so the spacing between blankets is the web's.
    static func webComparison(officeOnly: Bool = false) -> MeadowWorld {
        let run = "mwdkqm93"   // the web demo run the comparison shots were taken from
        let office = MeadowBlanket(id: "office", title: "Three.js agent office visualization", color: .account(0), agents: [
            MeadowAgent(id: "main", activity: .supervising), MeadowAgent(id: "a6f6d2315fad607ad", parentID: "main", activity: .running),
        ])
        let shop = MeadowBlanket(id: "sim-shop-\(run)", title: "shop", color: .account(1), agents: [
            MeadowAgent(id: "main", activity: .thinking), MeadowAgent(id: "mapper", parentID: "main", activity: .supervising),
            MeadowAgent(id: "reviewer", parentID: "main", activity: .thinking),
            MeadowAgent(id: "payments", parentID: "mapper", activity: .running), MeadowAgent(id: "taxes", parentID: "mapper", activity: .thinking),
        ])
        let api = MeadowBlanket(id: "sim-api-\(run)", title: "api-server", color: .account(2), agents: [MeadowAgent(id: "main", activity: .tidying)])
        return MeadowWorld(machines: [MeadowMachine(id: "mac", name: "This Mac", spaces: [MeadowSpace(id: "all", name: "all", blankets: officeOnly ? [office] : [office, shop, api])])])
    }

    /// One blanket with twenty helpers, some nested three deep (`npm run simulate -- crowd`).
    static func crowdWorld(_ step: Int) -> MeadowWorld {
        let packages = ["web", "api", "auth", "billing", "search", "mailer", "admin", "docs", "cli", "sdk", "worker", "cache", "ui-kit", "metrics"]
        var agents = [MeadowAgent(id: "main", activity: .supervising)]
        for (i, name) in packages.enumerated() {
            agents.append(MeadowAgent(id: "audit-\(name)", parentID: "main", activity: work[(i + step) % work.count]))
        }
        for (boss, part) in [("audit-web", "styles"), ("audit-api", "tests"), ("audit-api", "db"), ("audit-billing", "stripe")] {
            agents.append(MeadowAgent(id: "\(boss)-\(part)", parentID: boss, activity: work[(part.count + step) % work.count]))
        }
        agents.append(MeadowAgent(id: "audit-api-tests-e2e", parentID: "audit-api-tests", activity: .reading))
        let blanket = MeadowBlanket(id: "sim-crowd", title: "Audit dependencies", color: .account(0), agents: agents)
        return MeadowWorld(machines: [MeadowMachine(id: "mac", name: "This Mac", spaces: [MeadowSpace(id: "monorepo", name: "monorepo", blankets: [blanket])])])
    }

    /// Branches for the sidebar's workspaces (`--branches`), and long names and branches (`--long`).
    static let branches = ["fix-cart", "main", "release-notes", "auth-migration", "main"]
    static let longTitles = ["shop-web-storefront-checkout", "api", "documentation-site", "auth", "dotfiles-and-machine-setup"]
    static let longBranches = ["feature/fix-cart-rounding-errors", "alice/rate-limiter-for-public-api", "main", "auth-migration-phase-two", "main"]

    /// The app's sidebar with every state a workspace can show, top to bottom: a request ("!"), an
    /// error ("×"), finished and not yet seen ("✓"), working with three helpers (the current one), and
    /// an idle Claude beside a napping one.
    /// Git worktrees beside their repositories (`--worktrees`): two of shop-web's and one of auth's, each
    /// joined to its repository's blanket by a path.
    static func withWorktrees(_ world: MeadowWorld) -> MeadowWorld {
        var world = world
        var spaces: [MeadowSpace] = []
        for space in world.machines[0].spaces {
            spaces.append(space)
            let extra: [(String, String, [MeadowAgent], Int)] = switch space.id {
            case "shop-web": [("wt-cart", "fix-cart", [MeadowAgent(id: "w1", activity: .editing, name: "Cart")], 5),
                              ("wt-tax", "tax-rules", [MeadowAgent(id: "w2", activity: .thinking, name: "Tax")], 3)]
            case "auth": [("wt-sso", "sso-login", [MeadowAgent(id: "w3", activity: .reading, name: "SSO")], 1)]
            default: []
            }
            for (id, branch, agents, color) in extra {
                spaces.append(MeadowSpace(id: id, name: branch, blankets: [
                    MeadowBlanket(id: id, title: branch, color: .account(color), agents: agents, detail: branch, joinedTo: space.id),
                ]))
            }
        }
        world.machines[0].spaces = spaces
        return world
    }

    /// One boss and, with `helper`, a helper it launched; a neighbour's blanket beside them (`--event`).
    static func team(helper: Bool) -> MeadowWorld {
        var agents = [MeadowAgent(id: "boss", activity: .supervising, name: "Boss")]
        if helper { agents.append(MeadowAgent(id: "kid", parentID: "boss", activity: .reading, name: "Explore")) }
        return MeadowWorld(machines: [MeadowMachine(id: "mac", name: "This Mac", spaces: [
            MeadowSpace(id: "team", name: "team", blankets: [MeadowBlanket(id: "team", title: "shop-web", color: .account(0), agents: agents, detail: "main")]),
            MeadowSpace(id: "pals", name: "pals", blankets: [MeadowBlanket(id: "pals", title: "api", color: .account(1),
                                                                          agents: [MeadowAgent(id: "pal", activity: .thinking)])]),
        ])])
    }

    static var sidebarStates: MeadowWorld {
        func space(_ id: String, _ agents: [MeadowAgent], color: Int) -> MeadowSpace {
            MeadowSpace(id: id, name: id, blankets: [MeadowBlanket(id: id, title: id, color: .account(color), agents: agents)])
        }
        return MeadowWorld(machines: [MeadowMachine(id: "mac", name: "This Mac", spaces: [
            space("shop-web", [MeadowAgent(id: "c1", activity: .running, needsYou: true, name: "Fix cart rounding")], color: 0),
            space("api", [MeadowAgent(id: "c2", activity: .error, failed: true, name: "Rate limiter")], color: 1),
            space("docs", [MeadowAgent(id: "c3", activity: .awake, doneUnseen: true, name: "Release notes")], color: 2),
            space("auth", [
                MeadowAgent(id: "c4", activity: .supervising, name: "Migrate auth"),
                MeadowAgent(id: "h1", parentID: "c4", activity: .reading, name: "Explore"),
                MeadowAgent(id: "h2", parentID: "c4", activity: .searching, name: "Explore"),
                MeadowAgent(id: "h3", parentID: "c4", activity: .running, name: "general-purpose"),
            ], color: 3),
            space("dotfiles", [MeadowAgent(id: "c5", activity: .idle, name: "Tidy dotfiles"), MeadowAgent(id: "c6", activity: .napping, name: "Old chat")], color: 4),
        ])])
    }
}
