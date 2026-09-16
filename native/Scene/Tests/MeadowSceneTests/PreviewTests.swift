import AppKit
import Foundation
import Testing
@testable import MeadowScene

// My Meadows' pictures of meadows, and the parcel a thing from a newer Whiskr shows as while editing.

/// A pixel's colour (0…255), at fractions across and down.
private func pixel(_ image: CGImage, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let px = Double(image.width) * x, py = Double(image.height) * (1 - y)
    context.draw(image, in: CGRect(x: -px, y: -py, width: Double(image.width), height: Double(image.height)))
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
}

@MainActor
@Suite(.serialized) struct Previews {
    @Test("a meadow's picture: its size, sky over grass, the same meadow alike each time (the grass a breath apart), another meadow another")
    func picture() throws {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 240, height: 150))
        let standard = try #require(view.previewImage(of: .standard, width: 480, height: 300))
        #expect(standard.width == 480 && standard.height == 300)
        let sky = pixel(standard, 0.5, 0.03), grass = pixel(standard, 0.5, 0.9)
        #expect(sky.r + sky.g + sky.b > grass.r + grass.g + grass.b && grass.g > grass.r && grass.g > grass.b, "\(sky) over \(grass)")
        let empty = try #require(view.previewImage(of: .empty, width: 480, height: 300))
        let again = try #require(view.previewImage(of: .standard, width: 480, height: 300))
        // Mean difference per channel over a grid of points.
        func apart(_ a: CGImage, _ b: CGImage) -> Double {
            var sum = 0, n = 0
            for i in 1..<12 { for j in 1..<8 {
                let p = pixel(a, Double(i) / 12, Double(j) / 8), q = pixel(b, Double(i) / 12, Double(j) / 8)
                sum += abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)
                n += 3
            } }
            return Double(sum) / Double(n)
        }
        #expect(apart(again, standard) < 8, "one view draws one picture after another: \(apart(again, standard))")
        #expect(apart(empty, standard) > apart(again, standard))
    }

    @Test("the parcel is drawn and pictured, never offered as a catalog thing, and a thing's ground for the rules")
    func parcel() {
        #expect(MeadowScenery.draws(MeadowScenery.parcel) && !MeadowScenery.drawnIds.contains(MeadowScenery.parcel))
        let thing = MeadowScenery.Thing(id: MeadowScenery.parcel, x: 0, z: 0)
        #expect(Meadow.alone(thing) != nil && !SceneryRules.footprint(of: thing).isEmpty && !SceneryRules.isBig(MeadowScenery.parcel))
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        #expect(view.portrait(of: [MeadowScenery.parcel], pixels: 96, background: MeadowColor(hex: 0xffffff)) != nil)
    }
}
