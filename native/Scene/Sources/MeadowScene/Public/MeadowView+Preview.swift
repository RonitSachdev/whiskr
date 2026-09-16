import AppKit

/// A meadow's picture (docs/DESIGN.md, "My Meadows"): its scenery drawn by the scene itself, by day in still
/// air, with no blankets, cats or flags (a meadow file holds scenery only, and a picture of it shows only
/// that), seen from where editing looks down on the picnic ground. For the library's cards, the import sheet
/// and File › Export Meadow Picture….
extension MeadowView {
    /// Where a preview looks from: low over the picnic ground toward the far hills (18° above the ground, the
    /// sky a strip along the top), a little turned off square as the meadow is first seen, so it reads as a
    /// place rather than a map.
    static let previewView = CameraView(x: 0, z: -5, distance: 130, pitch: 18 * .pi / 180, bearing: MapCamera.bearing)

    /// A picture of `scenery`, `width` × `height` pixels. Meant for a view of its own that is never on screen
    /// (it takes the view's world, settings and camera for the picture): the same view draws one picture after
    /// another, growing only the trees it has not grown before. Nil when the scene cannot draw.
    public func previewImage(of scenery: MeadowScenery, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        // Points as a window at twice the scale would have them: the view's shape decides the framing.
        let size = NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        if frame.size != size { setFrameSize(size) }
        world = .empty
        settings = MeadowSettings(timeOfDay: .day, effects: [])
        self.scenery = scenery
        stage.camera.viewport = Vec2(Float(size.width), Float(size.height))
        stage.camera.setView(Self.previewView)
        // A moment for the meadow to lay the scenery and the light to settle; the view stays where it was put.
        advance(seconds: 0.25)
        stage.camera.setView(Self.previewView)
        return renderImage(width: width, height: height)
    }
}
