import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import simd
@testable import MeadowScene

@MainActor
enum Crowd {
    static func lanterns(_ count: Int, failedLast: Bool = false) -> [MeadowLantern] {
        (0..<count).map { i in
            let failed = failedLast ? i == count - 1 : i == 3
            return MeadowLantern(id: "t\(i)", title: "zsh", state: failed ? .failed : i % 3 == 1 ? .finished : .running)
        }
    }
    static func world(_ count: Int, helpers: Bool, failedLast: Bool = false) -> MeadowWorld {
        var agents = [MeadowAgent(id: "main", activity: .editing)]
        if helpers {
            agents += [MeadowAgent(id: "h1", parentID: "main", activity: .reading), MeadowAgent(id: "h2", parentID: "main", activity: .searching)]
        }
        return MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "shop", title: "shop-web", color: .account(0), agents: agents, lanterns: lanterns(count, failedLast: failedLast), detail: "main"),
        ])])])
    }
    static func view(_ world: MeadowWorld, column: Bool, time: MeadowSettings.TimeOfDay) -> MeadowView {
        let size = column ? NSSize(width: 300, height: 520) : NSSize(width: 480, height: 320)
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: column ? .column : .picnic, timeOfDay: time, picnic: .hamper)
        view.world = world
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 4)
        return view
    }
    static func save(_ view: MeadowView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] else { return }
        let w = Int(view.bounds.width * 2), h = Int(view.bounds.height * 2)
        guard let image = view.renderImage(width: w, height: h) else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

@MainActor
@Suite(.serialized) struct CrowdedBlanket {
    @Test func snapshots() {
        guard ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] != nil else { return }
        for column in [false, true] {
            for n in [1, 5, 13, 30] {
                Crowd.save(Crowd.view(Crowd.world(n, helpers: true), column: column, time: .night), "\(column ? "column" : "picnic")-\(n)-night")
            }
            Crowd.save(Crowd.view(Crowd.world(13, helpers: true), column: column, time: .day), "\(column ? "column" : "picnic")-13-day")
            Crowd.save(Crowd.view(Crowd.world(13, helpers: false), column: column, time: .night), "\(column ? "column" : "picnic")-13-alone-night")
        }
    }
}
