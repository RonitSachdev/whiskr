import Foundation
import Testing
import simd
@testable import MeadowScene

@Suite struct CameraBehaviour {
    func camera() -> MapCamera {
        let c = MapCamera()
        c.viewport = Vec2(1200, 800)
        c.bounds = { Ground(x: 0, z: 0, across: 40, deep: 40) }
        c.aim = { Ground(x: 10, z: -5, across: 6, deep: 6) }
        c.setView(CameraView(x: 0, z: 0, distance: 40, pitch: 0.8, bearing: 0.2))
        return c
    }

    /// Zooming toward the cursor keeps the ground under the cursor where it was on screen (camera.ts).
    @Test func zoomKeepsTheSpotUnderTheCursor() {
        let c = camera()
        let cursor = Vec2(300, 520)
        let before = c.groundUnder(cursor)!
        c.zoom(by: 0.6, at: cursor, immediate: true)
        let after = c.groundUnder(cursor)!
        #expect(simd_distance(before, after) < 0.05)
        // Gliding (a mouse wheel's notch) arrives at the same place.
        let d = camera()
        d.zoom(by: 0.6, at: cursor)
        for _ in 0..<240 { d.update(1.0 / 120) }
        #expect(simd_distance(d.groundUnder(cursor)!, before) < 0.05)
        #expect(abs(d.view.distance - 24) < 0.1)
    }

    /// A flight frames the aimed ground but keeps whatever angle you turned the view to.
    @Test func flyKeepsTheAngle() {
        let c = camera()
        c.setView(CameraView(x: 0, z: 0, distance: 40, pitch: 1.1, bearing: 2.4))
        c.fly()
        for _ in 0..<180 { c.update(1.0 / 120) }
        #expect(abs(c.view.bearing - 2.4) < 1e-4)
        #expect(abs(c.view.pitch - 1.1) < 1e-4)
        #expect(abs(c.view.x - 10) < 0.01 && abs(c.view.z + 5) < 0.01)
    }

    /// While you hold the view, nothing else moves it: not a flight, not the follow.
    @Test func neverMovesWhileHeld() {
        let c = camera()
        c.grab()
        let held = c.view
        c.fly()
        for _ in 0..<120 { c.update(1.0 / 120) }
        #expect(c.view == held)
        c.release()
    }

    /// A drag lands at once (no easing in), then the view coasts and comes to rest.
    @Test func dragIsDirectAndCoasts() {
        let c = camera()
        c.grab()
        let before = c.view.bearing
        c.turn(dx: 100, dy: 0)
        #expect(abs(c.view.bearing - (before - 2 * .pi * 100 / 800 * MapCamera.rotateSpeed)) < 1e-5)
        // Keep dragging the way a hand does, a little every few milliseconds, then let go mid-move.
        for _ in 0..<6 { Thread.sleep(forTimeInterval: 0.008); c.turn(dx: 10, dy: 0) }
        c.release()
        let afterDrag = c.view.bearing
        for _ in 0..<240 { c.update(1.0 / 120) }
        #expect(c.view.bearing < afterDrag)          // coasted on the same way
        #expect(!c.moving)                            // and stopped
    }

    /// Pitch stays between the limits however far you drag.
    @Test func pitchIsLimited() {
        let c = camera()
        c.grab()
        for _ in 0..<50 { c.turn(dx: 0, dy: -400) }
        #expect(c.view.pitch <= MapCamera.highest + 1e-5)
        for _ in 0..<50 { c.turn(dx: 0, dy: 400) }
        #expect(c.view.pitch >= MapCamera.lowest - 1e-5)
        c.release()
    }

    /// A panel over the right of the window shifts the picture's middle into the open part.
    @Test func panelShiftsTheMiddle() {
        let c = camera()
        let middle = c.target
        c.coverGoal = Vec2(400, 0)
        for _ in 0..<240 { c.update(1.0 / 120) }
        let m: Mat4 = c.projection(aspect: 1.5) * c.viewMatrix
        let clip: Vec4 = m * Vec4(middle.x, middle.y, middle.z, 1)
        let x = (clip.x / clip.w + 1) / 2 * 1200
        #expect(abs(x - (1200 - 400) / 2) < 2)
    }
}
