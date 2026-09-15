import AppKit

/// Bringing a floating piece of the interface in and taking it out again (Go to, the ⌃Tab list, the find
/// bar, the worktree panel), as `Look.Motion` says: a fade with a slight grow from where it is anchored,
/// carried by Core Animation, so the render server draws every frame and the main thread is free the moment
/// the animation is added. Only the picture moves: whatever shows it has its keyboard and its clicks from
/// the first frame, and something put away takes neither while it fades.
///
/// The animations are explicit and leave the layer's own values alone (AppKit owns a view's layer), so
/// nothing is left half-way if one is cut short: coming in, the layer is already as it ends; going out,
/// the last, clear frame is held (until `done` takes the view away, or it appears again), so it never
/// shows whole for a frame on its way out.
@MainActor
enum OverlayMotion {
    /// Where a piece grows from: its top edge's middle (something hung under the bar, as Go to is) or its
    /// middle (something that stands on its own, as the ⌃Tab list).
    enum Anchor { case top, center }

    private static let key = "overlayMotion"

    /// Fades `layer` in, from 98 % of its size about `anchor` (with Reduce Motion, only the fade).
    static func appear(_ layer: CALayer, anchor: Anchor = .top, duration: TimeInterval = Look.Motion.standard) {
        layer.removeAnimation(forKey: key)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = layer.opacity
        var parts: [CAAnimation] = [fade]
        if Look.Motion.moves {
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: shrunk(layer, anchor: anchor))
            grow.toValue = NSValue(caTransform3D: layer.transform)
            parts.append(grow)
        }
        layer.add(group(parts, duration: duration, holds: false), forKey: key)
    }

    /// Fades `layer` out the way it came in, then calls `done` (which takes the view away). Reduce Motion:
    /// only the fade.
    static func disappear(_ layer: CALayer, anchor: Anchor = .top, duration: TimeInterval = Look.Motion.quick, done: @escaping @MainActor () -> Void) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = (layer.presentation() ?? layer).opacity
        fade.toValue = 0
        var parts: [CAAnimation] = [fade]
        if Look.Motion.moves {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: (layer.presentation() ?? layer).transform)
            shrink.toValue = NSValue(caTransform3D: shrunk(layer, anchor: anchor))
            parts.append(shrink)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        layer.add(group(parts, duration: duration, holds: true), forKey: key)
        CATransaction.commit()
    }

    private static func group(_ parts: [CAAnimation], duration: TimeInterval, holds: Bool) -> CAAnimationGroup {
        // Each part spans the whole group (a part's own duration would otherwise default to 0.25 s and be cut
        // off part-way when the group ends).
        for part in parts { part.duration = duration }
        let group = CAAnimationGroup()
        group.animations = parts
        group.duration = duration
        group.timingFunction = Look.Motion.curve
        if holds {
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
        }
        return group
    }

    /// The layer at 98 % of its size, about `anchor`. A layer's transform turns about its anchor point,
    /// which AppKit puts at a view's corner, so the scale is moved to the anchor and back.
    private static func shrunk(_ layer: CALayer, anchor: Anchor) -> CATransform3D {
        let scale: CGFloat = 0.98
        let bounds = layer.bounds
        let pivot = CGPoint(x: bounds.width * layer.anchorPoint.x, y: bounds.height * layer.anchorPoint.y)
        // The top edge is y = 0 where the layer's content is drawn flipped (as a flipped view's is).
        let top = layer.contentsAreFlipped() ? bounds.minY : bounds.maxY
        let point = CGPoint(x: bounds.midX, y: anchor == .top ? top : bounds.midY)
        let offset = CGPoint(x: point.x - pivot.x, y: point.y - pivot.y)
        var transform = CATransform3DMakeTranslation(offset.x, offset.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -offset.x, -offset.y, 0)
        return CATransform3DConcat(transform, layer.transform)
    }
}
