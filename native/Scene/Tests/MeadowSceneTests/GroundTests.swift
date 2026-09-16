import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The view never sees past the ground: at every allowed tilt, zoom and view size, from a 300 pt sidebar to a
// whole window of meadow, no hole shows where land should be (`Renderer.marksVoid` paints any in magenta).

@MainActor
@Suite(.serialized) struct GroundEverywhere {
    nonisolated static let sizes: [NSSize] = [NSSize(width: 300, height: 820), NSSize(width: 240, height: 1100), NSSize(width: 900, height: 820),
                                  NSSize(width: 1440, height: 860), NSSize(width: 2560, height: 1400)]

    func holes(_ view: MeadowView, _ size: NSSize) -> Int {
        Renderer.marksVoid = true
        defer { Renderer.marksVoid = false }
        guard let image = view.renderImage(width: Int(size.width / 2), height: Int(size.height / 2)) else { return -1 }
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var n = 0
        for i in stride(from: 0, to: data.count, by: 4) where data[i] > 250 && data[i + 1] < 5 && data[i + 2] > 250 { n += 1 }
        return n
    }

    @Test("no hole in the ground and no hill in the foreground at the lowest tilt, the usual, the highest, and zoomed all the way out, in every arrangement and size",
          arguments: sizes, [MeadowSettings.Arrangement.column, .picnic])
    func noHoles(_ size: NSSize, _ arrangement: MeadowSettings.Arrangement) {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: arrangement, timeOfDay: .day, picnic: .hamper)
        view.world = Sidebar.world(arrangement == .column ? 12 : 5)
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 2)
        var found: [String] = []
        for pitch in [MapCamera.lowest, MapCamera.pitch, MapCamera.highest] {
            for out in [false, true] {
                view.turn(toBearing: view.cameraAngle.bearing, pitch: pitch)
                view.advance(seconds: 2)
                if out {
                    for _ in 0..<40 { view.simulateZoom(by: 1.3, at: CGPoint(x: size.width / 2, y: size.height / 2)) }
                    view.advance(seconds: 2)
                }
                // No far hill stands round the eye: one would fill the foreground between you and the meadow.
                let eye = view.stage.camera.eye, m = view.stage.meadow!
                for i in m.hills.indices {
                    let h = m.hill(i, view.stage.world.clearings, view.stage.clearingCount, eye: eye)
                    let top = h.columns.3.y + h.columns.1.y, apart = hypot(h.columns.3.x - eye.x, h.columns.3.z - eye.z) - h.columns.0.x
                    if top > 0.5 && apart < Meadow.hillClearOfEye * 0.5 { found.append("pitch \(pitch)\(out ? " zoomed out" : ""): hill \(i) stands \(apart) from the eye") }
                }
                let n = holes(view, size)
                if n != 0 { found.append("pitch \(pitch)\(out ? " zoomed out" : ""): \(n) px, eye \(view.stage.camera.eye), distance \(view.stage.camera.view.distance)") }
            }
        }
        #expect(found.isEmpty, "\(Int(size.width))×\(Int(size.height)) \(arrangement): \(found)")
    }
}
