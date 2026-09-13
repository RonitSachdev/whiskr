import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// "It's squished": the meadow must keep its proportions whatever shape the view is, a tall narrow
// sidebar, a square, a wide window, and through every resize. Three things make that true, each tested:
// the drawable has the view's shape (and the projection follows the drawable), the blankets are laid out
// for the view's shape so a sidebar shows them in a column at a readable size, and a cat drawn in any of
// these views has the same proportions as in the reference square view.

@MainActor
@Suite(.serialized) struct AspectRatios {
    /// A sidebar beside a terminal, a square, a wide window (points).
    nonisolated static let shapes: [NSSize] = [NSSize(width: 260, height: 760), NSSize(width: 600, height: 600), NSSize(width: 1200, height: 420)]

    func world(blankets: Int) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: (0..<blankets).map { i in
            MeadowSpace(id: "s\(i)", name: "space \(i)", blankets: [
                MeadowBlanket(id: "b\(i)", title: "tab \(i)", color: .account(i), agents: [MeadowAgent(id: "cat", activity: .awake)]),
            ])
        })])
    }

    func view(_ size: NSSize, blankets: Int) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(timeOfDay: .day, picnic: .none)
        view.world = world(blankets: blankets)
        view.advance(seconds: 0.5)
        return view
    }

    @Test("the drawable keeps the view's shape through resizes and render-scale changes")
    func drawableFollowsTheView() {
        let view = view(Self.shapes[0], blankets: 1)
        for size in Self.shapes + [NSSize(width: 333, height: 1001), NSSize(width: 1, height: 500)] {
            view.setFrameSize(size)
            let drawable = view.drawableSize
            #expect(abs(drawable.width / drawable.height - size.width / size.height) <= 1 / min(drawable.width, drawable.height) + 1e-6,
                    "drawable \(drawable) for a view of \(size)")
            #expect(view.stage.camera.viewport == Vec2(Float(size.width), Float(size.height)))
        }
        for scale in [1.0, 1.25, 1.75, 2.0] {
            let size = MeadowView.drawableSize(for: CGSize(width: 260, height: 760), scale: scale)
            #expect(abs(size.width / size.height - 260.0 / 760.0) < 0.005)
        }
    }

    @Test("a circle facing the camera stays round on screen, whatever the view's shape", arguments: shapes)
    func circlesStayRound(_ size: NSSize) {
        let view = view(size, blankets: 1)
        view.frame(.blanket("b0"), besidePanelWidth: 0, animated: false)
        view.advance(seconds: 2)
        let camera = view.stage.camera
        // Exactly as the renderer projects: the drawable's own width over height.
        let drawable = view.drawableSize
        let projection = camera.projection(aspect: Float(drawable.width / drawable.height)) * camera.viewMatrix
        func pixel(_ p: Vec3) -> Vec2 {
            let clip = projection * Vec4(p.x, p.y, p.z, 1)
            return Vec2((clip.x / clip.w + 1) / 2 * Float(drawable.width), (1 - clip.y / clip.w) / 2 * Float(drawable.height))
        }
        let forward = simd_normalize(camera.target - camera.eye)
        let right = simd_normalize(simd_cross(forward, Vec3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let centre = pixel(camera.target)
        var radii: [Float] = []
        for step in 0..<12 {
            let angle = Float(step) / 12 * 2 * .pi
            let point = camera.target + (right * cos(angle) + up * sin(angle)) * 0.5
            radii.append(simd_distance(pixel(point), centre))
        }
        let spread = (radii.max()! - radii.min()!) / radii.max()!
        #expect(spread < 0.01, "radii \(radii) in a \(size) view")
    }

    @Test("in a tall sidebar the blankets lie in a column; in a wide window, in a row")
    func layoutFollowsTheShape() {
        func extent(_ size: NSSize) -> (wide: Float, tall: Float) {
            let view = view(size, blankets: 5)
            view.frame(nil, besidePanelWidth: 0, animated: false)
            view.advance(seconds: 3)
            let points = view.stage.village!.plots.map { view.stage.screen($0.middle) }
            return ((points.map(\.x).max()! - points.map(\.x).min()!), (points.map(\.y).max()! - points.map(\.y).min()!))
        }
        let sidebar = extent(Self.shapes[0]), wide = extent(Self.shapes[2])
        #expect(sidebar.tall > sidebar.wide, "sidebar spread \(sidebar)")
        #expect(wide.wide > wide.tall, "wide spread \(wide)")
    }

    @Test("a sidebar that is widened into a window lays its blankets out afresh for the new shape")
    func relaysOnABigChange() {
        let view = view(Self.shapes[0], blankets: 5)
        view.advance(seconds: 1)
        let before = view.stage.village!.plots.map(\.at)
        view.setFrameSize(Self.shapes[2])
        view.advance(seconds: 1)
        #expect(view.stage.village!.plots.map(\.at) != before)
        // A small change moves nobody.
        let settled = view.stage.village!.plots.map(\.at)
        view.setFrameSize(NSSize(width: 1100, height: 420))
        view.advance(seconds: 1)
        #expect(view.stage.village!.plots.map(\.at) == settled)
    }

    @Test("a cat has the same proportions in every view shape as in the square reference")
    func catKeepsItsProportions() throws {
        func proportions(_ size: NSSize) throws -> Double {
            let view = view(size, blankets: 1)
            view.turn(toBearing: 0.2, pitch: 0.55)
            view.frame(.cat(blanket: "b0", agent: "cat"), besidePanelWidth: 0, animated: false)
            view.advance(seconds: 3)
            let scale = 2.0
            let image = try #require(view.renderImage(width: Int(size.width * scale), height: Int(size.height * scale)))
            let cat = view.stage.village!.plots[0].actors["cat"]!.cat
            let middle = view.stage.screen(cat.position + Vec3(0, 1.1, 0))
            let reach = view.stage.screen(cat.position + Vec3(0, 3.2, 0))
            let half = Double(abs(middle.y - reach.y)) * scale * 1.6
            return try #require(darkBox(image, around: (Double(middle.x) * scale, Double(middle.y) * scale), half: half))
        }
        let reference = try proportions(Self.shapes[1])
        for size in [Self.shapes[0], Self.shapes[2]] {
            let ratio = try proportions(size)
            #expect(abs(ratio / reference - 1) < 0.08, "cat height over width \(ratio) in \(size), \(reference) in the square")
        }
    }

    /// Height over width of the box round the cat's coat: the near-black pixels joined to the one nearest
    /// `centre` (y down), so the flag's dark lettering nearby is not counted.
    func darkBox(_ image: CGImage, around centre: (Double, Double), half: Double) -> Double? {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func dark(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2]) < 55
        }
        // The dark pixel nearest the centre.
        var start: (Int, Int)?
        var best = Double.infinity
        let x0 = max(0, Int(centre.0 - half)), x1 = min(width - 1, Int(centre.0 + half))
        let y0 = max(0, Int(centre.1 - half)), y1 = min(height - 1, Int(centre.1 + half))
        guard x0 < x1, y0 < y1 else { return nil }
        for y in y0...y1 {
            for x in x0...x1 where dark(x, y) {
                let d = hypot(Double(x) - centre.0, Double(y) - centre.1)
                if d < best { best = d; start = (x, y) }
            }
        }
        guard let start else { return nil }
        var seen = Set<Int>([start.1 * width + start.0])
        var queue = [start]
        var box = (minX: start.0, minY: start.1, maxX: start.0, maxY: start.1)
        while let (x, y) = queue.popLast() {
            box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= x0 && nx <= x1 && ny >= y0 && ny <= y1 {
                let key = ny * width + nx
                if !seen.contains(key), dark(nx, ny) { seen.insert(key); queue.append((nx, ny)) }
            }
        }
        guard box.maxX > box.minX + 8 else { return nil }
        return Double(box.maxY - box.minY + 1) / Double(box.maxX - box.minX + 1)
    }
}
