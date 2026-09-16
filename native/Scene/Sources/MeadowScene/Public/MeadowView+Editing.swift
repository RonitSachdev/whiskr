import AppKit
import simd

/// The pointer on the meadow while it is edited (`MeadowView.onEditPointer`).
public struct MeadowEditPointer: Sendable {
    public enum Phase: Sendable { case moved, down, dragged, up, exited }
    public var phase: Phase
    /// Where, in the view's own coordinates (points, origin bottom left).
    public var location: NSPoint
    /// The scenery's thing under it (by index in `MeadowView.scenery`), if any.
    public var thing: Int?
    public var modifiers: NSEvent.ModifierFlags
    public var clickCount: Int
}

/// Editing the meadow (docs/DESIGN.md, "Edit Meadow"): the view lifts to look down on the picnic ground and
/// may roam the whole meadow, the blankets keep the rows they had, the scenery can be pointed at and marked,
/// and plain drags are the editor's (`onEditPointer`) while ⌘-drag, right-drag and Space-drag slide the
/// view, two fingers turn it, and scrolling or pinching zooms toward the pointer, nearer than usual.
/// Ending it brings the view back exactly where it was. Cats and blankets go on as always; they are not
/// the editor's to choose.
extension MeadowView {
    /// Whether the meadow is being edited.
    public var isEditing: Bool { stage.editing }

    /// The view lifts to the edit view over about a second (at once with Reduce Motion): about 55° above
    /// the ground, framing the blankets and the picnic ground round them. What it was is kept to come back
    /// to. A follow waiting is dropped: nothing moves the view while editing but you.
    public func beginEditing() {
        guard !stage.editing, stage.meadow != nil else { return }
        editRestore = (stage.camera.destination, stage.camera.framing, handMoved)
        pendingFollow = nil
        pendingReveal = nil
        if hovered != nil { hovered = nil; stage.hover(nil); onHover?(nil) }
        stage.heldPerRow = stage.village?.perRow
        stage.editing = true
        stage.camera.pitchGoal = Stage.editPitch
        stage.camera.closest = Stage.editClosest
        stage.camera.fly()
        wake(.input)
    }

    /// The view glides back to exactly where it was before editing (at once with Reduce Motion), and the
    /// blankets take the rows the meadow's width gives once it has its width back.
    public func endEditing() {
        guard stage.editing else { return }
        stage.editing = false
        stage.editMarks = MeadowEditMarks()
        stage.camera.coverGoal.y = 0
        stage.camera.pitchGoal = nil
        stage.camera.closest = MapCamera.nearest
        stage.heldRowsLinger = 0.6
        editSliding = false
        spaceHeld = false
        editHovered = nil
        if let saved = editRestore {
            stage.camera.glide(to: saved.view, thenFraming: saved.framing)
            handMoved = saved.handMoved
        } else {
            stage.camera.fly()
        }
        editRestore = nil
        NSCursor.arrow.set()
        wake(.input)
    }

    /// What the editor marks on the ground.
    public var editMarks: MeadowEditMarks {
        get { stage.editMarks }
        set {
            guard newValue != stage.editMarks else { return }
            stage.editMarks = newValue
            wake(.input)
        }
    }

    // MARK: Where things are

    /// The scenery's thing drawn under a point of the view (its own coordinates), nearest first.
    public func sceneryThing(at point: NSPoint) -> Int? {
        stage.pickScenery(topLeft(point))
    }

    /// The scenery's things standing inside a rectangle of the view (by the spot each stands on).
    public func sceneryThings(in rect: NSRect) -> [Int] {
        let top = topLeft(NSPoint(x: rect.minX, y: rect.maxY)), bottom = topLeft(NSPoint(x: rect.maxX, y: rect.minY))
        return stage.scenery(inside: ScreenBox(left: top.x, top: top.y, right: bottom.x, bottom: bottom.y))
    }

    /// Where some of the scenery's things are drawn, all together, in the view's coordinates; nil when none is.
    public func screenRect(ofScenery things: [Int]) -> NSRect? {
        guard let box = stage.screenBox(ofScenery: things) else { return nil }
        return NSRect(x: CGFloat(box.left), y: bounds.height - CGFloat(box.bottom), width: CGFloat(box.right - box.left), height: CGFloat(box.bottom - box.top))
    }

    /// Where the editor's rings round some of the scenery's things lie on the ground (round their ground, and
    /// round a tree's crown where it shades the ground), all together, in the view's coordinates; nil when none
    /// is drawn. What the selection's bar hangs under.
    public func screenRect(ofGroundMarks things: [Int]) -> NSRect? {
        guard let meadow = stage.meadow else { return nil }
        var box = ScreenBox.empty
        for i in things where meadow.scenery.things.indices.contains(i) && meadow.laid[i] != .none {
            var circles = SceneryRules.footprint(of: meadow.scenery.things[i])
            if let crown = meadow.canopy(i) { circles.append(SceneryRules.Circle(x: crown.x, z: crown.z, r: crown.r)) }
            for c in circles {
                for k in 0..<16 {
                    let a = Float(k) / 16 * 2 * .pi, x = c.x + cos(a) * c.r, z = c.z + sin(a) * c.r
                    let p = stage.screen(Vec3(x, Land.height(x, z), z))
                    if p.z <= 1 { box.add(Vec2(p.x, p.y)) }
                }
            }
        }
        guard !box.isEmpty else { return nil }
        return NSRect(x: CGFloat(box.left), y: bounds.height - CGFloat(box.bottom), width: CGFloat(box.right - box.left), height: CGFloat(box.bottom - box.top))
    }

    /// The spot on the land (x, z) under a point of the view, if the view looks at land there.
    public func groundPoint(at point: NSPoint) -> SIMD2<Float>? {
        stage.groundPoint(topLeft(point))
    }

    /// Where a spot on the land (x, z) is in the view; nil when it is behind the view.
    public func viewPoint(ofGround spot: SIMD2<Float>) -> NSPoint? {
        let p = stage.screen(Vec3(spot.x, Land.height(spot.x, spot.y), spot.y))
        guard p.z <= 1 else { return nil }
        return NSPoint(x: CGFloat(p.x), y: bounds.height - CGFloat(p.y))
    }

    /// Along the ground, the view's right and its forward (toward the top of the view), each one unit long.
    public var groundAxes: (right: SIMD2<Float>, forward: SIMD2<Float>) {
        let b = stage.camera.view.bearing
        return (SIMD2(cos(b), -sin(b)), SIMD2(-sin(b), -cos(b)))
    }

    // MARK: The view, by hand

    /// Which way the view looks round the meadow, radians (0: toward north, the meadow's −z).
    public var viewBearing: Float { stage.camera.view.bearing }

    /// Turns the view round the spot it looks at by `radians`, gliding (at once with Reduce Motion).
    public func turnView(by radians: Float) {
        var goal = stage.camera.destination
        goal.bearing += radians
        handTookOver()
        stage.camera.glide(to: goal, thenFraming: false)
        wake(.input)
    }

    /// Turns the view back to look toward north, gliding.
    public func faceNorth() {
        var goal = stage.camera.destination
        goal.bearing = 0
        handTookOver()
        stage.camera.glide(to: goal, thenFraming: false)
        wake(.input)
    }

    /// Turns the view at once by `radians` (a drag on the compass).
    public func twistView(by radians: Float) {
        handTookOver()
        stage.camera.twist(radians)
        wake(.input)
    }

    /// Frames the picnic ground and its surroundings again, as on entering edit mode.
    public func frameEditView() {
        stage.camera.fly()
        wake(.input)
    }

    /// While editing: how many points along the view's bottom edge something floats over (the editor's
    /// tray), so the picnic ground is framed in the part above it. The view eases to it when it frames itself
    /// (unless you have moved it yourself since). Ending editing sets it back to none.
    public var editingCover: CGFloat {
        get { CGFloat(stage.camera.coverGoal.y) }
        set {
            let goal = Float(max(0, newValue))
            guard stage.editing, goal != stage.camera.coverGoal.y else { return }
            stage.camera.coverGoal.y = goal
            if stage.camera.framing, !stage.camera.flying { stage.camera.fly() }
            wake(.input)
        }
    }

    // MARK: Input while editing (from MeadowView's own handlers)

    private func topLeft(_ p: NSPoint) -> Vec2 { Vec2(Float(p.x), Float(bounds.height - p.y)) }

    private func tell(_ phase: MeadowEditPointer.Phase, _ event: NSEvent, thing: Int?) {
        // Only a press, a drag or a release has a click count (asked of another event, AppKit raises).
        let clicks = [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) ? event.clickCount : 0
        onEditPointer?(MeadowEditPointer(phase: phase, location: convert(event.locationInWindow, from: nil), thing: thing,
                                         modifiers: event.modifierFlags, clickCount: clicks))
    }

    private var slides: Bool { spaceHeld }

    func editMoved(_ event: NSEvent) {
        let p = point(event)
        stage.pointer = Vec2(p.x / Float(bounds.width) * 2 - 1, 1 - p.y / Float(bounds.height) * 2)
        let found = stage.pickScenery(p)
        editHovered = found
        if spaceHeld || event.modifierFlags.contains(.command) { NSCursor.openHand.set() } else { (found != nil ? NSCursor.pointingHand : NSCursor.arrow).set() }
        tell(.moved, event, thing: found)
        wake(.input)
    }

    func editExited(_ event: NSEvent) {
        editHovered = nil
        NSCursor.arrow.set()
        tell(.exited, event, thing: nil)
    }

    func editDown(_ event: NSEvent) {
        pendingReveal = nil
        if event.modifierFlags.contains(.control), let onEditMenu, let menu = onEditMenu(stage.pickScenery(point(event)), convert(event.locationInWindow, from: nil)) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if slides || event.modifierFlags.contains(.command) {
            editSliding = true
            editSlideThing = slides ? nil : stage.pickScenery(point(event))
            editSlideMoved = false
            stage.camera.grab()
            NSCursor.closedHand.set()
            wake(.input)
            return
        }
        tell(.down, event, thing: stage.pickScenery(point(event)))
        wake(.input)
    }

    func editDragged(_ event: NSEvent) {
        if editSliding {
            editSlideMoved = true
            handTookOver()
            stage.camera.slide(dx: Float(event.deltaX), dy: Float(event.deltaY))
        } else {
            tell(.dragged, event, thing: nil)
        }
        wake(.input)
    }

    func editUp(_ event: NSEvent) {
        if editSliding {
            editSliding = false
            stage.camera.release()
            (spaceHeld ? NSCursor.openHand : NSCursor.arrow).set()
            // ⌘-click on a thing, not a slide: the editor's, as a press and a release.
            if let thing = editSlideThing, !editSlideMoved {
                tell(.down, event, thing: thing)
                tell(.up, event, thing: nil)
            }
            editSlideThing = nil
        } else {
            tell(.up, event, thing: nil)
        }
        wake(.input)
    }

    /// Space held slides the view with a plain drag; its release lets go.
    func editKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if !event.isARepeat {
            spaceHeld = true
            NSCursor.openHand.set()
        }
        return true
    }

    func editKeyUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        spaceHeld = false
        if !editSliding { (editHovered != nil ? NSCursor.pointingHand : NSCursor.arrow).set() }
        return true
    }

    /// After a frame while editing: what floats over the meadow follows the view.
    func tellEditViewChanged() {
        if stage.editing { onEditViewChanged?() }
    }

    // MARK: Diagnostics

    /// Diagnostics: where the view stands and looks (the spot, how far back, its pitch and bearing).
    @_spi(Diagnostics) public var cameraView: (x: Float, z: Float, distance: Float, pitch: Float, bearing: Float) {
        let v = stage.camera.view
        return (v.x, v.z, v.distance, v.pitch, v.bearing)
    }

    /// Diagnostics: blankets to a row in the sidebar's column, as laid out now.
    @_spi(Diagnostics) public var blanketsPerRow: Int { stage.village?.perRow ?? 0 }

    /// Diagnostics: the view is gliding or flying somewhere.
    @_spi(Diagnostics) public var cameraMoving: Bool { stage.camera.moving }
}
