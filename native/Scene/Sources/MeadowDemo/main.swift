import AppKit
import MeadowScene

// The meadow in a window, fed by a scripted demo, or the cat on its own (`--playground`), or one frame
// drawn offscreen to a PNG (`--shot`). Write outputs outside ~/Desktop, ~/Documents and ~/Downloads.
//
//   MeadowDemo [--playground] [--activity reading] [--size 1280x800]
//              [--shot out.png --after 3] [--time day|night|clock|<hour>] [--picnic none|hamper|spread]
//              [--crowd] [--measure seconds --out report.json]
//   The sidebar (`--sidebar`, 300×820; any --size): [--rows n] [--more n] [--dark] [--branches] [--long] [--pin id]
//              [--focus blanket[/agent]] [--select blanket[/agent]] [--reveal blanket] [--seed text] [--report]

struct Options {
    var playground = false
    var activity: AgentActivity = .awake
    var size = CGSize(width: 1280, height: 800)
    var shot: String?
    var after = 3.0
    var time: MeadowSettings.TimeOfDay = .day
    var picnic: MeadowSettings.Picnic = .hamper
    var crowd = false
    var web = false
    var officeOnly = false
    var panel: CGFloat = 0
    var measure: Double?
    var out: String?
    var interact: String?
    var needsYou = false
    var select: String?
    var cat: String?
    var weather: MeadowWeather?
    var bearing: Float?
    var doneUnseen = false
    /// The app's sidebar: the column, with every state in five workspaces (`--sidebar`), in the app's
    /// dark colours with `--dark`.
    var sidebar = false
    var dark = false
    /// With --sidebar: only the first this many workspaces.
    var rows = 5
    /// With --sidebar: this many more workspaces after the five, each with a cat at work.
    var more = 0
    /// With --sidebar: every workspace on a git branch; long names and branches; pinned, keyboard focus.
    var branches = false
    var long = false
    var pins: [String] = []
    var focus: String?
    var reveal: String?
    /// With --sidebar: cats' ids get this suffix, so each sits and turns differently.
    var seed = ""
    /// Print where things are on screen and what is out of view.
    var report = false
    /// Worktrees beside their repositories, joined by paths.
    var worktrees = false
    /// A moment of cats dealing with each other: handover, report, farewell or note, shot `at` seconds in.
    var event: String?
    var at = 0.6

    static func parse() -> Options {
        var o = Options()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--playground": o.playground = true
            case "--activity": o.activity = AgentActivity(rawValue: args.next() ?? "") ?? .awake
            case "--needs-you": o.needsYou = true
            case "--select": o.select = args.next()
            case "--cat": o.cat = args.next()
            case "--bearing": o.bearing = Float(args.next() ?? "")
            case "--weather":
                let sky = MeadowWeather.Sky(rawValue: args.next() ?? "") ?? .clear
                o.weather = MeadowWeather(sky: sky, cover: sky == .clear ? 0.2 : 0.9, windKmh: 18, temperatureC: sky == .snow ? -2 : 14)
            case "--done": o.doneUnseen = true
            case "--sidebar": o.sidebar = true; o.size = CGSize(width: 300, height: 820)
            case "--dark": o.dark = true
            case "--rows": o.rows = Int(args.next() ?? "") ?? 5
            case "--more": o.more = Int(args.next() ?? "") ?? 0
            case "--branches": o.branches = true
            case "--long": o.long = true; o.branches = true
            case "--pin": o.pins.append(args.next() ?? "")
            case "--focus": o.focus = args.next()
            case "--reveal": o.reveal = args.next()
            case "--seed": o.seed = args.next() ?? ""
            case "--report": o.report = true
            case "--worktrees": o.worktrees = true
            case "--event": o.event = args.next()
            case "--at": o.at = Double(args.next() ?? "") ?? o.at
            case "--size":
                let p = (args.next() ?? "").split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { o.size = CGSize(width: p[0], height: p[1]) }
            case "--shot": o.shot = args.next()
            case "--after": o.after = Double(args.next() ?? "") ?? o.after
            case "--time":
                let v = args.next() ?? ""
                o.time = v == "night" ? .night : v == "clock" ? .followClock : Double(v).map { .hour($0) } ?? .day
            case "--picnic": o.picnic = MeadowSettings.Picnic(rawValue: args.next() ?? "") ?? .hamper
            case "--crowd": o.crowd = true
            case "--two-machines": DemoScript.twoMachines = true
            case "--web": o.web = true
            case "--office": o.web = true; o.officeOnly = true
            case "--panel": o.panel = CGFloat(Double(args.next() ?? "") ?? 0)
            case "--measure": o.measure = Double(args.next() ?? "")
            case "--out": o.out = args.next()
            case "--interact": o.interact = args.next()   // orbit, pan or zoom, during a measurement
            default: break
            }
        }
        return o
    }
}

@MainActor
final class DemoApp: NSObject, NSApplicationDelegate {
    let options = Options.parse()
    var window: NSWindow?
    var view: MeadowView!
    var script: DemoScript?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let o = options
        view = MeadowView(frame: NSRect(origin: .zero, size: o.size), mode: o.playground ? .catPlayground : .meadow)
        let chrome = o.dark ? MeadowChrome(surface: MeadowColor(hex: 0x2a2a2e), ink: MeadowColor(hex: 0xececee), alert: MeadowColor(hex: 0xd55e00))
                            : MeadowChrome(surface: MeadowColor(hex: 0xfcfcfb), ink: MeadowColor(hex: 0x232327), alert: MeadowColor(hex: 0xd55e00))
        view.settings = MeadowSettings(arrangement: o.sidebar ? .column : .picnic, timeOfDay: o.time, weather: o.weather, picnic: o.picnic,
                                       chrome: o.sidebar ? chrome : .standard)
        if o.sidebar {
            var world = o.event.map { DemoScript.team(helper: $0 != "handover") } ?? DemoScript.sidebarStates
            world.machines[0].spaces = Array(world.machines[0].spaces.prefix(o.rows))
            if o.rows == 0 {
                world.machines[0].spaces = [MeadowSpace(id: "home", name: "~", blankets: [MeadowBlanket(id: "home", title: "~", color: .account(0))])]
            }
            for k in 0..<o.more {
                let id = "more-\(k + 1)"
                world.machines[0].spaces.append(MeadowSpace(id: id, name: id, blankets: [
                    MeadowBlanket(id: id, title: id, color: .account(k), agents: [MeadowAgent(id: "c", activity: .reading)]),
                ]))
            }
            for s in world.machines[0].spaces.indices {
                var b = world.machines[0].spaces[s].blankets[0]
                if o.branches { b.detail = DemoScript.branches[s % DemoScript.branches.count] }
                if o.long { b.title = DemoScript.longTitles[s % DemoScript.longTitles.count]; b.detail = DemoScript.longBranches[s % DemoScript.longBranches.count] }
                b.pinned = o.pins.contains(b.id)
                b.agents = b.agents.map { a in var a = a; a.id += o.seed; a.parentID = a.parentID.map { $0 + o.seed }; return a }
                world.machines[0].spaces[s].blankets[0] = b
            }
            view.world = world
            if o.worktrees { view.world = DemoScript.withWorktrees(view.world) }
        } else if o.event != nil {
            view.world = DemoScript.team(helper: o.event != "handover")
        } else if o.worktrees {
            var world = DemoScript.withWorktrees(DemoScript.sidebarStates)
            world.machines[0].spaces = world.machines[0].spaces.filter { ["shop-web", "wt-cart", "wt-tax", "api", "docs"].contains($0.id) }
            view.world = world
        } else if o.playground {
            view.world = DemoScript.single(o.activity, needsYou: o.needsYou, doneUnseen: o.doneUnseen)
        } else {
            let script = DemoScript(crowd: o.crowd, web: o.web, officeOnly: o.officeOnly)
            self.script = script
            view.world = script.world
        }

        if let seconds = o.measure {
            // Offscreen, no window: at the pixel size the window would have on a Retina display.
            view.frame(nil, besidePanelWidth: o.panel, animated: false)
            Measure.run(view: view, pixels: CGSize(width: o.size.width * 2, height: o.size.height * 2), seconds: seconds, out: o.out, interact: o.interact)
            NSApp.terminate(nil)
            return
        }

        if let shot = o.shot {
            // Offscreen: settle the scene, draw one frame at 2× and write it out.
            if o.sidebar {
                view.advance(seconds: 0.5)
                view.selection = o.select.map { Self.item($0, seed: o.seed) } ?? .blanket("auth")
                view.keyboardFocus = o.focus.map { Self.item($0, seed: o.seed) }
                view.frame(nil, besidePanelWidth: 0, animated: false)
                if let reveal = o.reveal {
                    view.advance(seconds: 1.5)
                    view.reveal(.blanket(reveal), animated: false)
                }
            } else if !o.playground {
                view.advance(seconds: 0.5)
                if let b = o.bearing { view.turn(toBearing: b) }
                let item: MeadowItem? = o.select.map { b in o.cat.map { .cat(blanket: b, agent: $0) } ?? .blanket(b) }
                view.selection = item
                view.frame(item, besidePanelWidth: o.panel, animated: false)
            }
            view.advance(seconds: o.after)
            if let event = o.event {
                // The moment itself, `--at` seconds after it began.
                switch event {
                case "handover": view.world = DemoScript.team(helper: true)
                case "farewell": view.world = DemoScript.team(helper: false)
                case "report": view.passNote(from: .cat(blanket: "team", agent: "kid"), to: .cat(blanket: "team", agent: "boss"))
                default: view.passNote(from: .cat(blanket: "team", agent: "boss"), to: .cat(blanket: "pals", agent: "pal"))
                }
                view.advance(seconds: o.at)
            }
            if o.report {
                print("out of view: above \(view.blanketsOutOfView.above), below \(view.blanketsOutOfView.below)")
                for space in view.world.machines.flatMap(\.spaces) {
                    for b in space.blankets {
                        print("\(b.id): \(view.screenRect(of: .blanket(b.id)).map { "\($0)" } ?? "nil")")
                        for a in b.agents { print("  \(a.id): \(view.screenRect(of: .cat(blanket: b.id, agent: a.id)).map { "\($0)" } ?? "nil")") }
                    }
                }
            }
            let scale = 2.0
            if let image = view.renderImage(width: Int(o.size.width * scale), height: Int(o.size.height * scale)) {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
                print("wrote \(shot)")
            } else {
                print("could not render")
            }
            NSApp.terminate(nil)
            return
        }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: o.size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = o.playground ? "Cat playground" : "Meadow"
        window.contentView = view
        window.center()
        window.collectionBehavior = [.fullScreenPrimary]
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        view.onSelect = { [weak self] item in
            guard let self else { return }
            self.view.frame(item, besidePanelWidth: item == nil ? 0 : 560)
        }
        if o.playground {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let n = Int(e.charactersIgnoringModifiers ?? ""), n >= 1, n <= AgentActivity.allCases.count else { return e }
                self.view.world = DemoScript.single(AgentActivity.allCases[n - 1])
                return nil
            }
        } else {
            script?.start { [weak self] world in self?.view.world = world }
        }
    }

    /// "blanket" or "blanket/agent" (the agent's id given without the seed).
    static func item(_ text: String, seed: String) -> MeadowItem {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count > 1 ? .cat(blanket: parts[0], agent: parts[1] + seed) : .blanket(parts[0])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
// Shots and measurements show no window and never activate (no Dock icon); the demo itself is an
// ordinary app, and only shows its window when run without them.
let headless = CommandLine.arguments.contains("--measure") || CommandLine.arguments.contains("--shot")
app.setActivationPolicy(headless ? .prohibited : .regular)
let delegate = DemoApp()
app.delegate = delegate
app.run()
