import AppKit
@preconcurrency import Metal
import MetalKit
import QuartzCore
import simd

/// The meadow, as an AppKit view to embed anywhere. Give it a `world` and it shows it; it tells you what
/// is pointed at and chosen; you can choose things and frame them beside a panel from outside.
///
/// It draws at the display's refresh rate (120 Hz on ProMotion) while you interact or something moves
/// fast, at 30 Hz when the window is not key or the scene is calm, and not at all while the window is
/// hidden or covered. Left alone with nothing new for a few seconds it rests: the scene's time slows and it
/// draws at a slow tick, so the meadow still sways. Your input brings the full rate back at once; a change
/// in the world (a cat dozing off, a lantern going dark) ends the rest and is drawn at the pace its motion
/// needs: 30 Hz when nothing in it moves fast.
/// It lowers its own resolution, in steps, when frames take too long. With `animatesAmbient` off it stops
/// drawing altogether once a change has settled.
@MainActor
public final class MeadowView: MTKView {
    public enum Mode: Sendable { case meadow, catPlayground }

    // MARK: public API

    /// Everything to show. Set it whenever the app's model changes; arrivals, departures and changes are
    /// worked out here and animated.
    public var world: MeadowWorld = .empty {
        didSet { if world != oldValue { stage.show(world); worldChanged = true; wake() } }
    }
    /// The scenery the meadow holds: its trees, flowers, mushrooms, stones and logs (`MeadowScenery.standard`,
    /// the Default, until set). Setting another lays it at once (growing only the trees not seen before)
    /// and ends the meadow's rest, as a change in the world does; blankets keep off its trees and logs.
    public var scenery: MeadowScenery {
        get { stage.meadow?.scenery ?? .empty }
        set {
            guard newValue != scenery else { return }
            stage.show(newValue)
            wake()
        }
    }
    public var settings = MeadowSettings() {
        didSet { if settings != oldValue { stage.settings = settings; wake() } }
    }
    /// What is chosen: its blanket is ringed (or the cat, or the lantern). Setting it does not move the
    /// camera (`select(_:origin:)` with `.user` does).
    public var selection: MeadowItem? {
        get { stage.selection }
        set { stage.selection = newValue; wake() }
    }

    /// Who made a selection. Only your own choice moves the camera (docs/DESIGN.md, "Attention"): a
    /// selection that changes because of something that happened by itself (a Claude starting beside the
    /// one chosen, a pane closing) is ringed where it is and the view stays put.
    public enum Origin: Sendable { case user, event }

    /// Rings `item` (nil: nothing, as on Home). Chosen by the user (a workspace, tab or pane on the right, a
    /// click here), the view follows it: its blanket and, for a cat, the cat glide comfortably into view
    /// (nothing moves if they are already), or on Home the view goes back to framing every blanket.
    /// - Choices in quick succession (⌃Tab, a held ⌘⇧]) move the view once, to the last: each waits
    ///   `followSettle` for the next, and a glide under way bends toward a new one without a jolt.
    /// - Your hand comes first: nothing follows while you drag the view, and once you have moved it yourself
    ///   choosing the same thing again leaves it where you put it. The next different choice follows.
    /// - Hidden, it does nothing; when it shows again it is there at once, with no glide from far away.
    /// - With Reduce Motion, or the meadow's animation off, it cuts instead of gliding.
    public func select(_ item: MeadowItem?, origin: Origin) {
        stage.selection = item
        guard origin == .user else { return wake() }
        if stage.camera.held || (handMoved && followedOnce && item == lastFollowed) { return wake() }
        pendingFollow = (item, clock())
        if !isShownForFollowing { catchUp = true }
        wake()
    }
    /// How long a choice waits for the next before the view follows it.
    public static let followSettle: CFTimeInterval = 0.12
    /// Points to spare between something chosen and the view's edges (in the column, its top and bottom
    /// edges) for it to count as comfortably in view (`select`): closer than this, the view moves.
    public static var comfortableInset: CGFloat { CGFloat(Stage.Comfort.edge) }
    /// What the pointer is over right now.
    public internal(set) var hovered: MeadowItem?
    /// Called when the user clicks something (or empty ground: nil).
    public var onSelect: ((MeadowItem?) -> Void)?
    /// Called when what the pointer is over changes.
    public var onHover: ((MeadowItem?) -> Void)?
    /// A right-click's menu for what was clicked (nil: grass). When it returns a menu, the menu shows and
    /// the right button does not slide the view.
    public var onContextMenu: ((MeadowItem?) -> NSMenu?)?
    /// Whether a click takes the keyboard. A host that keeps a terminal beside the meadow turns this off
    /// while the terminal is showing, so dragging, scrolling or clicking the meadow never takes the keys
    /// from it. The meadow has no keys of its own: while it has them they go to `onKeyDown`.
    public var takesKeyboardFocus = true
    /// Keys pressed while the meadow has the keyboard (arrows, Return, Space, Esc…): return true when
    /// handled; anything else goes on up the responder chain.
    public var onKeyDown: ((NSEvent) -> Bool)?
    /// Keys with ⌘ pressed while the meadow has the keyboard, offered before the menus take them (a view's
    /// key equivalent comes first): return true when handled.
    public var onKeyEquivalent: ((NSEvent) -> Bool)?
    // Editing (the API is in MeadowView+Editing.swift).
    /// While editing: the pointer on the meadow, with the scenery's thing under it. Dragging with ⌘ or
    /// Space held, the right button or two fingers slides, turns or zooms the view instead; plain drags are
    /// the editor's.
    public var onEditPointer: ((MeadowEditPointer) -> Void)?
    /// While editing: a right-click's menu for the scenery's thing under it (nil: the grass), at that point of
    /// the view. When it returns a menu, the menu shows and the right button does not slide the view.
    public var onEditMenu: ((Int?, NSPoint) -> NSMenu?)?
    /// While editing: called after each frame drawn, so what floats over the meadow (the selection's bar) can
    /// follow the view.
    public var onEditViewChanged: (() -> Void)?
    /// While editing: a scroll or a swipe over the meadow, offered to the editor first (⌥-scroll turns what
    /// is about to be placed); return true when taken, else it zooms as always.
    public var onEditScroll: ((NSEvent) -> Bool)?
    /// The view as it was before editing began, to come back to exactly.
    var editRestore: (view: CameraView, framing: Bool, handMoved: Bool)?
    /// A slide of the view under way, begun with ⌘ or Space held; the thing it began on, and whether the
    /// pointer has moved (a ⌘-click that never moved is the editor's: everything of that kind nearby).
    var editSliding = false
    var editSlideThing: Int?
    var editSlideMoved = false
    /// Space is held: a drag slides the view.
    var spaceHeld = false
    /// The scenery's thing under the pointer while editing.
    var editHovered: Int?

    /// What the keyboard is on: ringed in `MeadowChrome.focus`, two points wide, apart from the selection's
    /// ring. A blanket, a cat or a lantern; nil for none. Cleared when it leaves the world.
    public var keyboardFocus: MeadowItem? {
        get { stage.keyboardFocus }
        set { stage.keyboardFocus = newValue; wake(.input) }
    }

    /// One agent messaging another (both `.cat` items): a helper writing to whoever launched it (or launched
    /// its boss) on the same blanket trots over, hands a note to them, sees them nod and trots back; any
    /// other two turn to each other while the note floats across. Unknown cats are ignored, and nothing
    /// plays on a cat that needs you. A cat already busy with a note gets this one after it (two at most
    /// wait). With `reduceMotion` they only look at each other.
    public func passNote(from sender: MeadowItem, to receiver: MeadowItem) {
        stage.village?.passNote(from: sender, to: receiver)
        wake()
    }

    /// Reduce Motion: helpers do not trot or carry notes, they only glance. Follows the system's setting
    /// (and its changes); set it to override until the system's setting next changes.
    public var reduceMotion: Bool {
        get { stage.village?.reduceMotion ?? false }
        set { stage.village?.reduceMotion = newValue }
    }

    /// Whether the meadow's ambient motion plays (WCAG 2.2.2, Pause, Stop, Hide): grass and flowers
    /// swaying, butterflies, bees and fireflies, drifting seeds and falling rain or snow, flickering
    /// lights, the ladybirds, and each cat's breathing, blinks, glances, fidgets, tail and the loop of its
    /// work. Off, all of that holds still where it is, and nothing hops, trots or carries a note. What
    /// the meadow says still shows: cats change pose (easing into it), bubbles come and go, lanterns light
    /// and blankets, cats and lanterns arrive and leave. Dragging, scrolling and zooming the view still
    /// work. Once nothing is changing the view draws no frames until something does. Turned back on,
    /// everything carries on from where it stood. On by default; a host keeps the user's choice (off by
    /// default under Reduce Motion).
    public var animatesAmbient = true {
        didSet {
            guard animatesAmbient != oldValue else { return }
            stage.ambient = animatesAmbient
            wake()
        }
    }

    /// Where something is in the view, in its own coordinates (points, origin bottom left): a blanket
    /// with its flag, a cat with its bubble, a lantern (only after dark, when lanterns show). Nil if it is
    /// not laid out. As of the last frame drawn; for anchoring popovers and accessibility frames.
    public func screenRect(of item: MeadowItem) -> CGRect? {
        guard let box = stage.screenBox(of: item), !box.isEmpty else { return nil }
        return CGRect(x: CGFloat(box.left), y: bounds.height - CGFloat(box.bottom), width: CGFloat(box.right - box.left), height: CGFloat(box.bottom - box.top))
    }

    /// How gladly a cat walks at a spot on the ground (x, z), 0…1: 1 on a painted path or a stepping stone,
    /// less on mown lawn, least in the long wild grass and on tilled soil (the meadow's own grass where no
    /// meadow is shown). For whatever leads a cat about the meadow.
    public func walkingEase(at spot: SIMD2<Float>) -> Float {
        stage.meadow?.walkingEase(spot.x, spot.y) ?? Meadow.walkingEase(.wild)
    }

    /// Whether a cat going straight from `from` to `to` on the ground (x, z) would have to pass through a fence: any
    /// of its spans but a gate's. For whatever leads a cat about the meadow, which goes round, or through the gate.
    public func crossesFence(from: SIMD2<Float>, to: SIMD2<Float>) -> Bool {
        stage.meadow?.crossesFence(from, to) ?? false
    }

    /// The blankets whose blanket and flag are not wholly in view, as of the last frame: past the top edge
    /// and past the bottom edge, by id, in the world's order.
    public private(set) var blanketsOutOfView: (above: [String], below: [String]) = ([], [])
    /// Called on the main actor after a frame in which `blanketsOutOfView` changed (at most once a frame).
    public var onViewChanged: (() -> Void)?

    /// In the column (`MeadowSettings.Arrangement.column`), scrolls it just far enough to bring a
    /// blanket and its flag wholly into view with a small margin, as the scroll gesture would: nothing if
    /// they are in view already (so nothing in the rows form unless the set is taller than the view).
    /// Eased over 0.3 s when animated, at once with Reduce Motion. Ignored while the user is dragging or
    /// scrolling the view; while the camera is flying it waits for it to land. Meant for the user's own
    /// actions (choosing a workspace), not for things happening on their own.
    public func reveal(_ item: MeadowItem, animated: Bool = true) {
        guard stage.settings.arrangement == .column else { return }
        if stage.camera.held || CACurrentMediaTime() - lastScrolled < 0.3 { return }
        if stage.camera.flying { pendingReveal = (item, animated); return }
        pendingReveal = nil
        let distance = stage.revealDistance(item.blanketID, margin: Self.revealMargin)
        if distance == 0 { return }
        let ease = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        stage.camera.scroll(by: distance, seconds: ease ? 0.3 : 0)
        wake(.input)
    }
    /// Points kept clear between a revealed blanket and the view's edge.
    static let revealMargin: Float = 12

    /// Frames `item` (or everything, for nil) in the part of the view a panel of `panelWidth` points on
    /// the right leaves open, keeping the angle the user has turned the view to. Never moves the camera
    /// while the user is dragging it.
    public func frame(_ item: MeadowItem?, besidePanelWidth panelWidth: CGFloat, animated: Bool = true) {
        stage.focus = item
        stage.camera.coverGoal = Vec2(Float(panelWidth), 0)
        if animated { stage.camera.fly() } else { stage.camera.settle() }
        wake(.input)
    }

    /// The angle the view is turned to: bearing round the ground (radians, 0 looking from +z) and pitch
    /// above it. Read it to save the view; set it to restore one. Ignored while the user is dragging.
    public var cameraAngle: (bearing: Float, pitch: Float) {
        (stage.camera.view.bearing, stage.camera.view.pitch)
    }
    public func turn(toBearing bearing: Float, pitch: Float? = nil) {
        guard !stage.camera.held else { return }
        var v = stage.camera.view
        v.bearing = bearing
        if let pitch { v.pitch = min(max(pitch, MapCamera.lowest), MapCamera.highest) }
        stage.camera.setView(v)
        stage.camera.fly()
        wake(.input)
    }

    /// Draws one frame into an image of the given size in pixels, from the current camera, without
    /// disturbing what is on screen. For tests, comparisons and thumbnails.
    public func renderImage(width: Int, height: Int) -> CGImage? {
        renderer?.image(stage, width: width, height: height, pointScale: Float(width) / Float(max(bounds.width, 1)))
    }

    /// Runs the scene forward by `seconds` in steps of `step` without drawing, so a preview or test can
    /// show a settled moment (cats arrived, camera landed) deterministically.
    public func advance(seconds: Double, step: Double = 1.0 / 60) {
        var left = seconds
        while left > 1e-9 {
            let dt = min(step, left)
            followIfDue()
            stage.update(Float(dt))
            left -= dt
            if pendingReveal != nil { revealWhenLanded() }
            settle(Float(dt))
        }
        noticeView()
        tellViewChanged()
        tellEditViewChanged()
    }

    /// Measured over the last second, for diagnostics.
    public struct Timings: Sendable {
        /// Main-thread time per frame, all of it (update + posing + encoding), and its parts.
        public var cpuMilliseconds: Double
        public var updateMilliseconds: Double
        public var poseMilliseconds: Double
        public var encodeMilliseconds: Double
        /// Main-thread time per frame spent blocked: waiting for a free frame slot (the GPU is behind),
        /// and waiting for a drawable from the display.
        public var slotWaitMilliseconds: Double
        public var drawableWaitMilliseconds: Double
        public var gpuMilliseconds: Double
        /// Frames encoded, and frames actually shown on the display, per second.
        public var framesPerSecond: Double
        public var presentedPerSecond: Double
        /// Presented frames that came later than one refresh after the one before (a visible hitch).
        public var droppedFrames: Int
        /// The longest gap between two presented frames, in milliseconds.
        public var worstIntervalMilliseconds: Double
        public var targetFramesPerSecond: Int
        public var renderScale: Double
        public var drawableSize: CGSize
        public var cats: Int
    }
    public private(set) var timings: Timings?
    public var onTimings: ((Timings) -> Void)?
    /// Draw at the full rate even when the window is not key (normally 30 Hz then). For measuring; a host
    /// app should leave it off.
    public var keepsFullRateWhenInactive = false { didSet { updateRate() } }

    /// Something beside the meadow is being worked in (keys typed into a terminal): for `seconds` from now
    /// it draws at most `yieldRate` times a second, at the same pace (things move as far, in fewer
    /// steps), leaving the frames and the main thread to what is being typed into. Each call extends it;
    /// the full rate comes back by itself.
    public func yieldFrames(for seconds: CFTimeInterval = MeadowView.yieldSeconds) {
        let until = clock() + seconds
        guard until > yieldUntil + 0.05 else { return }
        yieldUntil = until
        updateRate()
    }
    public static let yieldSeconds: CFTimeInterval = 1.5
    static let yieldRate = 30
    private var yieldUntil: CFTimeInterval = 0

    /// Diagnostics: a drag of the view as if made with the mouse, for measuring how interaction feels.
    @_spi(Diagnostics) public func simulateDrag(dx: Float, dy: Float, slide: Bool = false) {
        handTookOver()
        stage.camera.grab()
        if slide { stage.camera.slide(dx: dx, dy: dy) } else { stage.camera.turn(dx: dx, dy: dy) }
        stage.camera.release()
        wake(.input)
    }
    /// Diagnostics: one frame drawn offscreen at `width`×`height` pixels after `dt` seconds of scene time,
    /// timed: main-thread milliseconds (and the posing part of them) and GPU milliseconds. Shows nothing on
    /// screen, so it can measure without a window.
    @_spi(Diagnostics) public func timeOffscreenFrame(width: Int, height: Int, dt: Double) -> (cpu: Double, pose: Double, update: Double, gpu: Double) {
        guard let renderer else { return (0, 0, 0, 0) }
        if offscreenTarget?.width != width || offscreenTarget?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderer.gpu.colorFormat, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .private
            offscreenTarget = renderer.gpu.device.makeTexture(descriptor: d)
        }
        guard let target = offscreenTarget, let cb = renderer.gpu.queue.makeCommandBuffer() else { return (0, 0, 0, 0) }
        stage.camera.viewport = Vec2(Float(width) / 2, Float(height) / 2)
        renderer.semaphore.wait()
        let t0 = CACurrentMediaTime()
        stage.update(Float(dt))
        noticeView()
        let t1 = CACurrentMediaTime()
        renderer.prepare(stage, into: cb, width: width, height: height, pointScale: 2)
        renderer.encodePass(stage, into: cb, target: target)
        cb.commit()
        let t2 = CACurrentMediaTime()
        tellViewChanged()
        cb.waitUntilCompleted()
        renderer.semaphore.signal()
        return ((t2 - t0) * 1000, renderer.poseMilliseconds, (t1 - t0) * 1000, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
    }
    private var offscreenTarget: MTLTexture?

    /// Diagnostics: the sky and weather as the scene shows them now.
    public struct SkyReading: Sendable {
        /// 0 by day … 1 at night.
        public var night: Float
        /// The sun's height, degrees, while the light follows the real sun (else nil).
        public var sunElevation: Double?
        /// The share of the moon's disc that is lit, and whether it is waxing.
        public var moonLit: Double
        public var moonWaxing: Bool
        /// The moon showing, 0…1: risen (where it is reckoned), after dark, not behind cloud.
        public var moonShown: Float
        /// Stars and moon showing, 0…1.
        public var stars: Float
        /// The wind's push at a gust's height (1 a breeze), which way it blows on the ground (x east, z
        /// south), and the share of it kept between gusts.
        public var wind: Float
        public var windToward: (x: Float, z: Float)
        public var windCalm: Float
        /// Rain or snow, 0…1, and the drops drawn for it.
        public var falling: Float
        public var snowing: Bool
        public var drops: Int
        public var thunder: Bool
        /// The lightning's flash this frame, 0…1.
        public var flash: Float
        public var mist: Float
        /// The grass's deeper green, linear RGB.
        public var turf: (red: Float, green: Float, blue: Float)
    }
    @_spi(Diagnostics) public var sky: SkyReading {
        let l = stage.light
        return SkyReading(night: l.night, sunElevation: l.sunElevation, moonLit: l.moon.lit, moonWaxing: l.moon.waxing, moonShown: l.moonShown, stars: l.stars,
                          wind: l.wind, windToward: (stage.windToward.x, stage.windToward.y), windCalm: l.windCalm,
                          falling: l.falling, snowing: l.snowing, drops: stage.meadow?.fallingCount ?? 0, thunder: l.thunder, flash: stage.flash,
                          mist: l.mist, turf: (l.turfLow.x, l.turfLow.y, l.turfLow.z))
    }

    /// Diagnostics: where the moon's disc is in the view (points, origin bottom left), whether or not
    /// anything stands in front of it.
    @_spi(Diagnostics) public var moonRect: CGRect? {
        let center = MeadowDrawer.moonCenter(stage.camera), c = stage.screen(center)
        guard c.z <= 1 else { return nil }
        let up = stage.camera.viewMatrix.inverse.direction(Vec3(0, 1, 0))
        let edge = stage.screen(center + simd_normalize(up) * 16 * MeadowDrawer.moonScale)
        let r = CGFloat(hypot(edge.x - c.x, edge.y - c.y))
        return CGRect(x: CGFloat(c.x) - r, y: bounds.height - CGFloat(c.y) - r, width: 2 * r, height: 2 * r)
    }

    @_spi(Diagnostics) public func simulateZoom(by factor: Float, at point: CGPoint) {
        handTookOver()
        stage.camera.zoom(by: factor, at: Vec2(Float(point.x), Float(point.y)))
        wake(.input)
    }

    // MARK: setup

    let stage: Stage
    private(set) var renderer: Renderer?
    /// Pictures of single things for the editor's tray (`portrait(of:pixels:background:)`), made when first asked.
    var portraits: Portraits?
    private let driver = FrameDriver()
    /// Frames come from a CAMetalDisplayLink on the view's Metal layer, which calls back only when a
    /// drawable is ready, at the cadence the display really gives this window. MTKView's own loop (which
    /// asks for the drawable on the main thread and blocks there until one is free) stays switched off.
    /// (A measuring run's meadow has a stand-in clock instead: `assumesOnScreen`.)
    private var link: CAMetalDisplayLink?
    /// The rate asked of the display link now.
    private(set) var targetRate = 60
    private var running = false
    /// The rate the display was found to give this window, when lower than asked; retried now and then.
    private var displayCap: Int?
    private var shortSeconds = 0
    private var cappedSeconds = 0

    public init(frame: NSRect, mode: Mode = .meadow) {
        stage = Stage(mode: mode == .catPlayground ? .playground : .meadow)
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .invalid
        sampleCount = 1
        autoResizeDrawable = false
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0.98, green: 0.976, blue: 0.965, alpha: 1)
        layer?.isOpaque = true
        // The drawable always has the view's shape (`sizeDrawable`), but while the view is resized a frame
        // drawn for the old size can still be on screen for a moment: it is scaled keeping its shape,
        // never stretched to the new one.
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        if let device {
            do { renderer = try Renderer(device: device) } catch { NSLog("MeadowView: could not build the renderer: \(error)") }
        }
        isPaused = true
        enableSetNeedsDisplay = false
        driver.view = self
        makeLink()
        stage.settings = settings
        updateTrackingAreas()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pacingChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(pacingChanged), name: NSApplication.didResignActiveNotification, object: nil)
        // Reduce Motion is announced on the workspace's own notification centre, not the default one.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(pacingChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        stage.camera.calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        sizeDrawable()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeLink() {
        guard link == nil, let metal = layer as? CAMetalLayer else { return }
        let link = CAMetalDisplayLink(metalLayer: metal)
        link.delegate = driver
        link.preferredFrameLatency = 2
        link.isPaused = !running
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(30, targetRate)), maximum: Float(targetRate), preferred: Float(targetRate))
        // Common modes, so frames keep coming while a window is resized or a menu is open.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    public override var acceptsFirstResponder: Bool { takesKeyboardFocus }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.removeObserver(self, name: name, object: nil)
            if let window { center.addObserver(self, selector: #selector(pacingChanged), name: name, object: window) }
        }
        sizeDrawable()
        pacingChanged()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sizeDrawable()
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDrawable()
        // A flight under way works out where it ends afresh each frame, for the size the view has then (a
        // region sliding as editing begins or ends resizes the view on the way); else the view frames
        // again, unless it is being edited and you have moved it yourself.
        if !stage.camera.flying, !stage.editing || stage.camera.framing { stage.camera.fly() }
        wake(.input)
    }
    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        sizeDrawable()
    }
    public override func layout() {
        super.layout()
        sizeDrawable()
    }

    // MARK: what is in view

    var pendingReveal: (item: MeadowItem, animated: Bool)?

    // MARK: following what you choose

    /// A choice of yours the view has yet to follow, and when it was made.
    var pendingFollow: (item: MeadowItem?, at: CFTimeInterval)?
    /// The view was not on screen when you chose: it follows at once, a cut, as soon as it is.
    private var catchUp = false
    /// What the view last followed, and whether you have moved the view yourself since.
    var lastFollowed: MeadowItem?
    var followedOnce = false
    var handMoved = false

    /// You moved the view yourself (a drag, a scroll, a pinch, a turn): it is yours until you choose
    /// something else, and a choice still waiting is dropped.
    func handTookOver() {
        handMoved = true
        pendingFollow = nil
        catchUp = false
    }

    /// Whether a follow would be seen: the view is in a window, not hidden, and has some size. (Covered by
    /// other windows counts as shown: it is drawn again the moment it is uncovered.)
    private var isShownForFollowing: Bool {
        if let shownForTests { return shownForTests }
        guard let window, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor, bounds.width >= 1, bounds.height >= 1 else { return false }
        return true
    }
    /// Tests stand in for a window: shown or not.
    var shownForTests: Bool?

    /// Each frame: a choice that has waited `followSettle` for the next is followed, at once if the view
    /// was hidden when it was made (it has just come back).
    private func followIfDue() {
        guard let (item, at) = pendingFollow, catchUp || clock() - at >= Self.followSettle else { return }
        if stage.camera.held { pendingFollow = nil; catchUp = false; return }
        let cut = catchUp || stage.camera.calm || !animatesAmbient
        pendingFollow = nil
        catchUp = false
        lastFollowed = item
        followedOnce = true
        handMoved = false
        stage.follow(item, cut: cut)
        wake()
    }

    /// Diagnostics: where the camera stands (the spot it looks at, and how far back), what it is doing for a
    /// follow, and what was followed last.
    @_spi(Diagnostics) public var followState: (x: Float, z: Float, distance: Float, waiting: Bool, gliding: Bool, followed: MeadowItem?) {
        let v = stage.camera.view
        return (v.x, v.z, v.distance, pendingFollow != nil, stage.camera.chasing, stage.followed)
    }
    /// The system's Reduce Motion as last seen, so only a change of it overrides `reduceMotion`.
    private var systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lastScrolled: CFTimeInterval = 0
    /// Blankets out of view this frame and as last told, by index (kept, so a frame allocates nothing).
    private var outAbove: [Int] = [], outBelow: [Int] = [], toldAbove: [Int] = [], toldBelow: [Int] = []
    private var worldChanged = false
    private var viewChanged = false

    private func revealWhenLanded() {
        guard let (item, animated) = pendingReveal, !stage.camera.flying else { return }
        reveal(item, animated: animated)
    }

    /// After each step of the scene: which blankets are out of view, noted when that changes.
    private func noticeView() {
        stage.outOfView(above: &outAbove, below: &outBelow)
        guard worldChanged || outAbove != toldAbove || outBelow != toldBelow else { return }
        worldChanged = false
        swap(&outAbove, &toldAbove)
        swap(&outBelow, &toldBelow)
        let plots = stage.village?.plots ?? []
        let now = (above: toldAbove.map { plots[$0].view.id }, below: toldBelow.map { plots[$0].view.id })
        if now != blanketsOutOfView {
            blanketsOutOfView = now
            viewChanged = true
        }
    }
    /// Once the frame is done, so the host may change anything it likes in answer.
    private func tellViewChanged() {
        guard viewChanged else { return }
        viewChanged = false
        onViewChanged?()
    }

    // MARK: pacing

    /// Pixels per point we draw at: from 1 up to the screen's backing scale, in quarter steps.
    private var renderScale: CGFloat = 0
    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Diagnostics: `MEADOW_RENDER_SCALE=2` holds the render scale where it is put.
    private let fixedScale: CGFloat? = ProcessInfo.processInfo.environment["MEADOW_RENDER_SCALE"].flatMap { Double($0) }.map { CGFloat($0) }

    /// The drawable is the view's shape at the render scale, the camera's viewport the view's size in
    /// points: called on every change of size, backing scale, render scale or window. Width and height
    /// are rounded alike, so the drawable's shape matches the view's to within a pixel.
    func sizeDrawable() {
        if let fixedScale { renderScale = fixedScale }
        if renderScale == 0 { renderScale = min(backing, 2) }
        renderScale = min(renderScale, backing)
        let size = Self.drawableSize(for: bounds.size, scale: renderScale)
        if drawableSize != size { drawableSize = size }
        stage.camera.viewport = Vec2(Float(max(bounds.width, 1)), Float(max(bounds.height, 1)))
    }

    static func drawableSize(for size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    /// Resting (the scene still, nothing done to the view, no change in the world): after this long the
    /// scene's time eases down to `restPace` and frames come at `restRate`, so each moves things about as
    /// far as a frame at 30 Hz does and nothing looks stepped, only calmer.
    static let restAfter: CFTimeInterval = 5
    static let restRate = 12
    static let restPace: Float = 0.4
    /// The scene's pace now, eased toward 1 or `restPace`.
    private(set) var pace: Float = 1
    private var resting: Bool {
        clock() - lastChange > Self.restAfter && pendingReveal == nil && pendingFollow == nil && stage.still
    }
    /// Diagnostics: resting at the slow tick now (`restRate`, the scene's time at `restPace`).
    @_spi(Diagnostics) public var isResting: Bool { resting && pace < Self.restPace + 0.05 }
    /// Diagnostics: what keeps the meadow from resting now, in words.
    @_spi(Diagnostics) public var restBlockers: String {
        let actors = stage.village?.plots.flatMap { Array($0.actors.values) } ?? []
        return String(format: "%.1f s since a change", clock() - lastChange) + " (woken at \(lastWake.file):\(lastWake.line))"
            + ", reveal \(pendingReveal != nil), follow \(pendingFollow != nil), camera moving \(stage.camera.moving)"
            + ", notes \(stage.village.map { $0.notes.count + $0.waitingNotes.count } ?? 0), errands \(actors.filter { $0.errand != nil }.count)"
            + ", leaving \(actors.filter(\.leaving).count), cats not still \(actors.filter { !$0.cat.still }.count)"
    }

    /// Diagnostics: draws as if the view were on screen even while its window is covered, for measuring
    /// what the meadow costs in a run that must stay out of sight. Such a window gets no frames from the
    /// meadow's display link (a window on another Space, or wholly covered, gets a frame or two, then none),
    /// so frames come from a stand-in clock instead, the screen's own display link, which ticks whatever the
    /// window: each takes a drawable from the layer and is drawn and presented as the link's are, at the
    /// same rate and pacing. The display link is set aside meanwhile (a layer it drives gives no drawables
    /// to anyone else). A shipped app never sets this: its meadow has the display link alone.
    @_spi(Diagnostics) public var assumesOnScreen = false {
        didSet {
            guard assumesOnScreen != oldValue else { return }
            if assumesOnScreen { link?.invalidate(); link = nil } else { makeLink() }
            pacingChanged()
        }
    }

    /// The clock pacing reads (tests give their own, which starts the view's timers afresh).
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() } {
        didSet { lastInput = clock(); lastChange = lastInput; yieldUntil = 0 }
    }
    /// What wakes the view: something you did to it (the full rate, until it is calm again), or a change in
    /// what it shows (the rest ends, at the rate the scene's own motion needs).
    enum Wake { case input, change }
    /// When you last did something to the view, and when anything at all last changed.
    private var lastInput = CACurrentMediaTime(), lastChange = CACurrentMediaTime()
    /// Where the view was last woken from (diagnostics, `restBlockers`), kept without allocating.
    private var lastWake: (file: StaticString, line: UInt) = ("", 0)
    func wake(_ cause: Wake = .change, _ file: StaticString = #fileID, _ line: UInt = #line) {
        lastWake = (file, line)
        let now = clock()
        if cause == .input { lastInput = now }
        lastChange = now
        unchanged = 0
        if !running, isVisibleOnScreen { setRunning(true) }
        updateRate()
    }

    /// Seconds of scene time with nothing new: no input, no change of world and the scene `still`.
    private var unchanged: Float = 0
    /// With ambient motion off, how long after the last change frames keep coming: long enough for
    /// poses, bubbles and lanterns to finish easing in.
    static let settleSeconds: Float = 3
    /// Ambient motion is off and the last change has settled: every frame would be the same as the one
    /// on screen, so none is drawn until something changes (`wake`).
    var frozenAtRest: Bool { !animatesAmbient && unchanged >= Self.settleSeconds }
    private func settle(_ dt: Float) {
        unchanged = stage.still ? unchanged + dt : 0
    }
    /// While frozen at rest, a clock-driven sky still turns to evening: checked now and then, and drawn
    /// when it has.
    private var relightTimer: Timer?
    private func restFrozen() {
        setRunning(false)
        guard relightTimer == nil else { return }
        relightTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.frozenAtRest || self.running { self.relightTimer?.invalidate(); self.relightTimer = nil; return }
                if self.stage.relight() { self.wake() }
            }
        }
    }

    private var isVisibleOnScreen: Bool {
        guard let window, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor, bounds.width >= 1, bounds.height >= 1 else { return false }
        return assumesOnScreen || window.occlusionState.contains(.visible)
    }

    // A host hides the view (or a view it sits in) when something else takes its place: no frames then.
    public override func viewDidHide() {
        super.viewDidHide()
        pacingChanged()
    }
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        pacingChanged()
        wake()
    }

    @objc private func pacingChanged() {
        stage.camera.calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if stage.camera.calm != systemReducesMotion {
            systemReducesMotion = stage.camera.calm
            reduceMotion = systemReducesMotion
        }
        setRunning(isVisibleOnScreen)
        sizeDrawable()
        updateRate()
    }

    func updateRate() {
        let now = clock()
        let goal = Self.frameRate(fastest: window?.screen?.maximumFramesPerSecond ?? 60,
                                  key: (window?.isKeyWindow ?? false) || keepsFullRateWhenInactive,
                                  calm: stage.restful && !stage.camera.moving && now - lastInput > 4,
                                  resting: resting && pace < Self.restPace + 0.05,
                                  yielding: now < yieldUntil && !stage.camera.held, displayCap: displayCap)
        if targetRate != goal {
            targetRate = goal
            let range = CAFrameRateRange(minimum: Float(min(30, goal)), maximum: Float(goal), preferred: Float(goal))
            link?.preferredFrameRateRange = range
            standIn?.preferredFrameRateRange = range
        }
    }

    /// The rate to draw at: the display's full rate while you interact, something moves fast or the camera
    /// moves; 30 Hz when the window is not key or the scene is calm; `restRate` once resting (on the way
    /// down it eases at the calm rate); at most `yieldRate` while something beside it is being typed in
    /// (unless the view is being dragged); never more than the display gives this window (`displayCap`:
    /// an unfocused window, a 60 Hz display), where drawing more would be wasted work.
    static func frameRate(fastest: Int, key: Bool, calm: Bool, resting: Bool, yielding: Bool, displayCap: Int?) -> Int {
        var goal = !key || calm ? min(30, fastest) : fastest
        if resting { goal = min(goal, restRate) }
        if yielding { goal = min(goal, yieldRate) }
        if let displayCap { goal = min(goal, displayCap) }
        return goal
    }

    private func setRunning(_ on: Bool) {
        running = on
        link?.isPaused = !on
        updateStandIn()
    }

    // MARK: the stand-in clock (`assumesOnScreen` only)

    /// The screen's display link, ticking at the rate asked of the meadow's own link.
    private var standIn: CADisplayLink?
    private weak var standInScreen: NSScreen?

    /// Runs while the view runs and stands for a visible one; follows the window to another screen.
    private func updateStandIn() {
        let screen = window?.screen ?? NSScreen.main
        guard running, assumesOnScreen, let screen else {
            standIn?.invalidate()
            standIn = nil
            return
        }
        if standIn != nil, standInScreen === screen { return }
        standIn?.invalidate()
        let clock = screen.displayLink(target: driver, selector: #selector(FrameDriver.standInTick(_:)))
        clock.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(30, targetRate)), maximum: Float(targetRate), preferred: Float(targetRate))
        clock.add(to: .main, forMode: .common)
        standIn = clock
        standInScreen = screen
    }

    /// A tick of the stand-in: a frame once one is due at the rate asked (the screen may tick faster), into
    /// a drawable from the layer. Waiting for it blocks the main thread, as MTKView's own loop would: the
    /// wait is reported apart (`Timings.drawableWaitMilliseconds`), not as the frame's work.
    fileprivate func standInTick(refresh: CFTimeInterval) {
        guard running, CACurrentMediaTime() - lastFrameAt >= 1 / Double(max(targetRate, 1)) - refresh / 2,
              let metal = layer as? CAMetalLayer else { return }
        let asked = CACurrentMediaTime()
        guard let drawable = metal.nextDrawable() else { return }
        drawFrame(drawable, waited: CACurrentMediaTime() - asked)
    }

    // Adaptive render scale, judged once a second on GPU time against the frame budget.
    private var gpuSmoothed = 0.0
    private var comfortable = 0
    private var judgedAt = CACurrentMediaTime()
    private var lastFrameAt = CACurrentMediaTime()
    /// Sums over the second being measured.
    private var sums = (frames: 0, cpu: 0.0, update: 0.0, pose: 0.0, encode: 0.0, slot: 0.0, drawable: 0.0)
    /// Filled by Metal's handlers on their own threads; read once a second on the main thread.
    private let fromGPU = GPUReports()

    private func judge(now: CFTimeInterval) {
        guard now - judgedAt >= 1 else { return }
        let seconds = now - judgedAt
        judgedAt = now
        let report = fromGPU.take()
        if report.gpuFrames > 0 { gpuSmoothed = report.gpuSum / Double(report.gpuFrames) }
        let budget = 1000 / Double(max(targetRate, 1))
        if fixedScale != nil {
            comfortable = 0
        } else if gpuSmoothed > budget * 0.9, renderScale > 1 {
            renderScale = max(1, renderScale - 0.25)
            comfortable = 0
            sizeDrawable()
        } else if gpuSmoothed * pow((renderScale + 0.25) / renderScale, 2) < budget * 0.8 {
            // The next step up costs about the square of the scale more; take it only if that would fit.
            comfortable += 1
            if comfortable >= 4, renderScale < min(backing, 2) {
                comfortable = 0
                renderScale = min(min(backing, 2), renderScale + 0.25)
                sizeDrawable()
            }
        } else {
            comfortable = 0
        }
        let n = Double(max(sums.frames, 1))
        // A presented frame later than one and a half refreshes after the last is a visible hitch.
        // Against the cadence the display actually gave (it may run slower than asked), so a hitch is a
        // frame that came late, not a display that runs at 60.
        let sorted = report.intervals.sorted()
        let refresh = max(1.0 / Double(max(targetRate, 1)), sorted.isEmpty ? 0 : sorted[sorted.count / 2])
        let dropped = report.intervals.reduce(0) { $0 + ($1 > refresh * 1.5 ? Int(($1 / refresh).rounded()) - 1 : 0) }
        timings = Timings(cpuMilliseconds: sums.cpu / n, updateMilliseconds: sums.update / n, poseMilliseconds: sums.pose / n,
                          encodeMilliseconds: sums.encode / n, slotWaitMilliseconds: sums.slot / n, drawableWaitMilliseconds: sums.drawable / n,
                          gpuMilliseconds: gpuSmoothed, framesPerSecond: Double(sums.frames) / seconds,
                          presentedPerSecond: Double(report.intervals.count) / seconds, droppedFrames: dropped,
                          worstIntervalMilliseconds: (report.intervals.max() ?? 0) * 1000, targetFramesPerSecond: targetRate,
                          renderScale: Double(renderScale), drawableSize: drawableSize, cats: stage.cats.count)
        sums = (0, 0, 0, 0, 0, 0, 0)
        // Presented frames well short of those drawn, two seconds running: draw only what is shown. (Not
        // judged on the stand-in clock: what the compositor presents of a window nobody sees says nothing.)
        let presented = Double(report.intervals.count) / seconds, encoded = timings?.framesPerSecond ?? 0
        if !assumesOnScreen, displayCap == nil, encoded > 40, presented < encoded * 0.7 {
            shortSeconds += 1
            if shortSeconds >= 2 { displayCap = presented > 75 ? 120 : presented > 40 ? 60 : 30; shortSeconds = 0; cappedSeconds = 0 }
        } else {
            shortSeconds = 0
        }
        if displayCap != nil {
            cappedSeconds += 1
            if cappedSeconds >= 10 { displayCap = nil; cappedSeconds = 0 }   // try the full rate again
        }
        if let timings { onTimings?(timings) }
    }

    /// One drawn frame's step of the scene, `dt` seconds after the last: the pace eased toward rest or
    /// back, the scene moved on at that pace.
    func step(_ dt: Float) {
        // Slowing into rest takes two seconds; waking takes a fraction of one, at the full rate already.
        let calmer = resting
        pace += ((calmer ? Self.restPace : 1) - pace) * min(1, dt * (calmer ? 1.5 : 8))
        if abs(pace - 1) < 0.002 { pace = 1 }
        stage.pace = pace
        followIfDue()
        stage.update(dt)
        if pendingReveal != nil { revealWhenLanded() }
        settle(dt * pace)
        noticeView()
        tellEditViewChanged()
    }

    /// One frame, into `drawable` (from the display link, or from the layer on the stand-in clock after
    /// `waited` seconds asking for it).
    fileprivate func drawFrame(_ drawable: CAMetalDrawable, waited: CFTimeInterval = 0) {
        guard let renderer else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameAt, 0.05))
        lastFrameAt = now
        // A free frame slot (only blocks if the GPU has fallen three frames behind).
        renderer.semaphore.wait()
        let t1 = CACurrentMediaTime()
        step(dt)
        let t2 = CACurrentMediaTime()
        guard let cb = renderer.gpu.queue.makeCommandBuffer() else { renderer.semaphore.signal(); return }
        let target = drawable.texture
        // A drawable handed out before the latest resize: drawn at its own shape (the projection follows
        // the texture), and the next one comes at the new size.
        if CGSize(width: target.width, height: target.height) != drawableSize { sizeDrawable() }
        renderer.prepare(stage, into: cb, width: target.width, height: target.height, pointScale: Float(renderScale))
        renderer.encodePass(stage, into: cb, target: target)
        let sem = renderer.semaphore
        let reports = fromGPU
        cb.addCompletedHandler { cb in
            reports.gpu((cb.gpuEndTime - cb.gpuStartTime) * 1000)
            sem.signal()
        }
        drawable.addPresentedHandler { d in reports.presented(d.presentedTime) }
        cb.present(drawable)
        cb.commit()
        let t3 = CACurrentMediaTime()
        sums.frames += 1
        sums.slot += (t1 - now) * 1000
        sums.drawable += waited * 1000
        sums.update += (t2 - t1) * 1000
        sums.pose += renderer.poseMilliseconds
        sums.encode += ((t3 - t2) * 1000 - renderer.poseMilliseconds)
        sums.cpu += (t3 - t1) * 1000
        judge(now: now)
        updateRate()
        tellViewChanged()
        if frozenAtRest { restFrozen() }
    }

    // MARK: input

    private var tracking: NSTrackingArea?
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// A point in the view, origin top left (as the web's client coordinates).
    func point(_ event: NSEvent) -> Vec2 {
        let p = convert(event.locationInWindow, from: nil)
        return Vec2(Float(p.x), Float(bounds.height - p.y))
    }

    private var pressedAt: Vec2?
    private var pressedTime: CFTimeInterval = 0
    private var dragged = false
    private var petTimer: Timer?

    public override func mouseMoved(with event: NSEvent) {
        if stage.editing { return editMoved(event) }
        let p = point(event)
        stage.pointer = Vec2(p.x / Float(bounds.width) * 2 - 1, 1 - p.y / Float(bounds.height) * 2)
        let found = stage.pick(p)
        if found != hovered {
            hovered = found
            stage.hover(found)
            onHover?(found)
            (found != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        wake(.input)
    }
    public override func mouseExited(with event: NSEvent) {
        if stage.editing { return editExited(event) }
        if hovered != nil { hovered = nil; stage.hover(nil); onHover?(nil); NSCursor.arrow.set() }
    }

    public override func mouseDown(with event: NSEvent) {
        if takesKeyboardFocus { window?.makeFirstResponder(self) }
        if stage.editing { return editDown(event) }
        pendingReveal = nil
        pressedAt = point(event)
        pressedTime = CACurrentMediaTime()
        dragged = false
        // Pressing on a cat is for the cat: hold a moment and it is petted.
        if case .cat = hovered {
            petTimer = Timer.scheduledTimer(withTimeInterval: 0.26, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.stage.setPetting(true) }
            }
        } else {
            stage.camera.grab()
        }
        wake(.input)
    }
    public override func mouseDragged(with event: NSEvent) {
        if stage.editing { return editDragged(event) }
        guard let start = pressedAt else { return }
        if simd_distance(point(event), start) >= 5 { dragged = true }
        if case .cat = hovered, !dragged { return }
        if petTimer != nil, dragged { petTimer?.invalidate(); petTimer = nil; stage.setPetting(false); stage.camera.grab() }
        if dragged { handTookOver() }
        let slide = !event.modifierFlags.intersection([.command, .control, .shift]).isEmpty
        if slide { stage.camera.slide(dx: Float(event.deltaX), dy: Float(event.deltaY)) } else { stage.camera.turn(dx: Float(event.deltaX), dy: Float(event.deltaY)) }
        wake(.input)
    }
    public override func mouseUp(with event: NSEvent) {
        if stage.editing { return editUp(event) }
        petTimer?.invalidate()
        petTimer = nil
        let wasPetting = stage.setPetting(false)
        stage.camera.release()
        defer { pressedAt = nil }
        guard let start = pressedAt, simd_distance(point(event), start) < 5, !dragged, !wasPetting else { wake(.input); return }
        let picked = stage.pick(point(event))
        if case .cat = picked { stage.hop(picked) }
        selection = picked
        onSelect?(picked)
        wake(.input)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if stage.editing, let onEditMenu, let menu = onEditMenu(stage.pickScenery(point(event)), convert(event.locationInWindow, from: nil)) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if !stage.editing, let onContextMenu, let menu = onContextMenu(stage.pick(point(event))) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        stage.camera.grab()
        wake(.input)
    }
    public override func rightMouseDragged(with event: NSEvent) { handTookOver(); stage.camera.slide(dx: Float(event.deltaX), dy: Float(event.deltaY)); wake(.input) }
    public override func rightMouseUp(with event: NSEvent) { stage.camera.release() }
    public override func otherMouseDown(with event: NSEvent) { stage.camera.grab() }
    public override func otherMouseDragged(with event: NSEvent) { handTookOver(); stage.camera.slide(dx: Float(event.deltaX), dy: Float(event.deltaY)); wake(.input) }
    public override func otherMouseUp(with event: NSEvent) { stage.camera.release() }

    /// Scrolling zooms toward whatever is under the cursor; a trackpad's momentum carries on smoothly.
    public override func scrollWheel(with event: NSEvent) {
        if stage.editing, onEditScroll?(event) == true { return }
        // A trackpad's momentum from before a follow began does not undo it: only a fresh touch does.
        if stage.camera.chasing, !event.momentumPhase.isEmpty { return }
        let precise = event.hasPreciseScrollingDeltas
        // A sidebar's column scrolls, as any sidebar does; pinch (or ⌘-scroll) still zooms. Editing, it zooms.
        if stage.settings.arrangement == .column, !stage.editing, !event.modifierFlags.contains(.command) {
            let dy = precise ? Float(event.scrollingDeltaY) : Float(event.scrollingDeltaY) * 16
            lastScrolled = CACurrentMediaTime()
            pendingReveal = nil
            if dy != 0 { handTookOver(); stage.camera.scroll(dy: dy); wake(.input) }
            return
        }
        let pixels = precise ? -Float(event.scrollingDeltaY) : -Float(event.scrollingDeltaY) * 16
        if pixels == 0 { return }
        handTookOver()
        let factor = exp(clamp(pixels, -120, 120) * (precise ? 0.004 : 0.0022))
        stage.camera.zoom(by: factor, at: point(event), immediate: precise)
        wake(.input)
    }
    /// Pinching zooms toward the cursor.
    public override func magnify(with event: NSEvent) {
        handTookOver()
        stage.camera.zoom(by: 1 / max(0.2, 1 + Float(event.magnification)), at: point(event), immediate: true)
        wake(.input)
    }
    public override func keyDown(with event: NSEvent) {
        if stage.editing, editKeyDown(event) { return }
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    /// A key with ⌘ while the meadow has the keyboard, before the menus see it (`onKeyEquivalent`).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyUp(with event: NSEvent) {
        if stage.editing, editKeyUp(event) { return }
        super.keyUp(with: event)
    }

    /// Turning two fingers turns the view.
    public override func rotate(with event: NSEvent) {
        handTookOver()
        stage.camera.twist(-Float(event.rotation) * .pi / 180)
        wake(.input)
    }
}

/// Hands the display link's frames to the view, kept out of the public interface.
private final class FrameDriver: NSObject, CAMetalDisplayLinkDelegate {
    nonisolated(unsafe) weak var view: MeadowView?
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // Added to the main run loop, so this is the main thread.
        nonisolated(unsafe) let drawable = update.drawable
        nonisolated(unsafe) let me = self
        MainActor.assumeIsolated { me.view?.drawFrame(drawable) }
    }
    /// The stand-in clock's tick (`MeadowView.assumesOnScreen`), on the main run loop too.
    @objc func standInTick(_ link: CADisplayLink) {
        let refresh = link.duration
        nonisolated(unsafe) let me = self
        MainActor.assumeIsolated { me.view?.standInTick(refresh: refresh) }
    }
}
