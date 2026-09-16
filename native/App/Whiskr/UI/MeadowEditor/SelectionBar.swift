import AppKit
import SwiftUI

/// What the selection's bar shows and does.
@MainActor @Observable
final class SelectionBarModel {
    enum Action { case turnLeft, turnRight, smaller, larger, shuffle, duplicate, delete, more }

    /// How many things are chosen.
    var count = 0
    /// They are living things: they can be sized and shuffled.
    var grows = false
    @ObservationIgnored var act: (Action) -> Void = { _ in }
}

/// The selection's bar (docs/DESIGN.md, "Edit Meadow"): floats 12 pt above whatever is chosen in the meadow
/// (below it when there is no room above), following it as the view moves. Turn left and right, smaller and
/// larger and Shuffle for living things, Duplicate, Delete, and More (Select All Like This, Copy, Paste). A
/// floating piece: the chrome's colour, a line round it, radius 10 and the one soft shadow; its buttons are
/// the bars' (hover, pressed and their tooltips with the key).
struct SelectionBar: View {
    let model: SelectionBarModel

    /// Room round the bar inside its view for the shadow.
    static let margin: CGFloat = 14

    var body: some View {
        HStack(spacing: Look.Space.xxs) {
            button(.turnLeft, "rotate.left", String(localized: "Turn Left", comment: "Selection bar"), key: "⇧R")
            button(.turnRight, "rotate.right", String(localized: "Turn Right", comment: "Selection bar"), key: "R")
            if model.grows {
                separator
                button(.smaller, "minus", String(localized: "Smaller", comment: "Selection bar"), key: "[")
                button(.larger, "plus", String(localized: "Larger", comment: "Selection bar"), key: "]")
                button(.shuffle, "shuffle", String(localized: "Shuffle", comment: "Selection bar: draws a living thing's size, lean and shape again"), key: nil)
            }
            separator
            button(.duplicate, "plus.square.on.square", String(localized: "Duplicate", comment: "Selection bar"), key: "⌘D")
            button(.delete, "trash", String(localized: "Delete", comment: "Selection bar"), key: "⌫")
            separator
            button(.more, "ellipsis", String(localized: "More", comment: "Selection bar: a menu of further commands"), key: nil)
        }
        .padding(Look.Space.xs)
        .background(RoundedRectangle(cornerRadius: Look.Radius.card).fill(Color.chrome))
        .overlay(RoundedRectangle(cornerRadius: Look.Radius.card).strokeBorder(Color.line))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .padding(Self.margin)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.count == 1 ? String(localized: "Chosen thing", comment: "VoiceOver: the selection's bar, one thing chosen")
                                             : String(localized: "\(model.count) chosen things", comment: "VoiceOver: the selection's bar"))
    }

    private var separator: some View {
        Color.line.frame(width: 1, height: 16).padding(.horizontal, Look.Space.xxs).accessibilityHidden(true)
    }

    private func button(_ action: SelectionBarModel.Action, _ symbol: String, _ label: String, key: String?) -> some View {
        Button { model.act(action) } label: { ChromeIcon(symbol: symbol) }
            .buttonStyle(ChromeButtonStyle())
            .help(key.map { "\(label) (\($0))" } ?? label)
            .accessibilityLabel(label)
    }
}

/// The selection's bar's view: takes clicks on its buttons only, so the meadow round it keeps the rest.
final class SelectionBarHost: NSHostingView<SelectionBar> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let card = bounds.insetBy(dx: SelectionBar.margin, dy: SelectionBar.margin)
        guard card.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where More's menu opens: under its button, the bar's last.
    var moreAnchor: NSPoint {
        NSPoint(x: bounds.maxX - SelectionBar.margin - Look.Space.xs - Look.Height.iconButton,
                y: isFlipped ? bounds.maxY - SelectionBar.margin + Look.Space.xs : SelectionBar.margin - Look.Space.xs)
    }
}

/// The compass (docs/DESIGN.md, "Edit Meadow"): floating at the meadow's top right while it is edited,
/// showing which way north is (away along the meadow at its first angle, as the wind's). A click turns the
/// view back to north, a double-click frames the picnic ground again, a drag round it turns the view.
final class CompassView: NSView {
    /// Which way the view looks round the meadow, radians (0: toward north).
    var bearing: Float = 0 {
        didSet { if bearing != oldValue { needsDisplay = true; setAccessibilityValue(facing) } }
    }
    var onFaceNorth: () -> Void = {}
    var onFrame: () -> Void = {}
    var onTwist: (Float) -> Void = { _ in }

    static let size: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Compass", comment: "Meadow editor: turns the view back to north"))
        setAccessibilityHelp(String(localized: "Turns the view back to north", comment: "Meadow editor: the compass"))
        setAccessibilityValue(facing)
        toolTip = String(localized: "Compass: click to face north, double-click to frame your workspaces again", comment: "Meadow editor: the compass's tooltip")
    }

    required init?(coder: NSCoder) {
        fatalError("CompassView is created in code")
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// "Facing north", "Facing north-west"…: which way the view looks.
    private var facing: String {
        let degrees = (Double(-bearing) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        let names = [String(localized: "Facing north", comment: "VoiceOver: the compass"), String(localized: "Facing north-east", comment: "VoiceOver: the compass"),
                     String(localized: "Facing east", comment: "VoiceOver: the compass"), String(localized: "Facing south-east", comment: "VoiceOver: the compass"),
                     String(localized: "Facing south", comment: "VoiceOver: the compass"), String(localized: "Facing south-west", comment: "VoiceOver: the compass"),
                     String(localized: "Facing west", comment: "VoiceOver: the compass"), String(localized: "Facing north-west", comment: "VoiceOver: the compass")]
        return names[Int(((degrees + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45) % 8]
    }

    override func draw(_ dirtyRect: NSRect) {
        let dial = bounds.insetBy(dx: 4, dy: 4)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        Colors.chrome.setFill()
        NSBezierPath(ovalIn: dial).fill()
        NSGraphicsContext.restoreGraphicsState()
        (Look.increasesContrast ? Colors.lineStrong : Colors.line).setStroke()
        let ring = NSBezierPath(ovalIn: dial.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        // North on screen: up turned by the view's bearing, clockwise.
        let center = NSPoint(x: dial.midX, y: dial.midY)
        let angle = CGFloat(bearing)
        let north = NSPoint(x: sin(angle), y: cos(angle)), across = NSPoint(x: -north.y, y: north.x)
        func at(_ along: CGFloat, _ side: CGFloat) -> NSPoint {
            NSPoint(x: center.x + north.x * along + across.x * side, y: center.y + north.y * along + across.y * side)
        }
        let length = dial.width / 2 - 9
        let up = NSBezierPath(), down = NSBezierPath()
        up.move(to: at(length, 0)); up.line(to: at(0, 3.5)); up.line(to: at(0, -3.5)); up.close()
        down.move(to: at(-length, 0)); down.line(to: at(0, 3.5)); down.line(to: at(0, -3.5)); down.close()
        NSColor(Color.ink3).setFill()
        down.fill()
        Colors.text.setFill()
        up.fill()
        // The N, just past the needle's tip, upright.
        let letter = NSAttributedString(string: String(localized: "N", comment: "Meadow editor: the compass's north"),
                                        attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .bold), .foregroundColor: Colors.text])
        let size = letter.size(), tip = at(length + 5.5, 0)
        letter.draw(at: NSPoint(x: tip.x - size.width / 2, y: tip.y - size.height / 2))
    }

    private var pressedAt: NSPoint?
    private var lastAngle: CGFloat = 0
    private var turned = false

    private func angle(_ event: NSEvent) -> CGFloat {
        let p = convert(event.locationInWindow, from: nil)
        return atan2(p.x - bounds.midX, p.y - bounds.midY)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onFrame(); pressedAt = nil; return }
        pressedAt = convert(event.locationInWindow, from: nil)
        lastAngle = angle(event)
        turned = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !turned, hypot(p.x - start.x, p.y - start.y) < 3 { return }
        turned = true
        // The dial follows the hand round its middle.
        let now = angle(event)
        var delta = now - lastAngle
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        lastAngle = now
        onTwist(Float(delta))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        guard pressedAt != nil, !turned else { return }
        onFaceNorth()
    }

    override func accessibilityPerformPress() -> Bool {
        onFaceNorth()
        return true
    }
}

/// The marquee: a dashed rectangle drawn from where a drag on empty ground began to where the pointer is;
/// it chooses what stands inside it. Takes no click.
final class MarqueeView: NSView {
    var rect: NSRect? {
        didSet {
            guard rect != oldValue else { return }
            isHidden = rect == nil
            needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect else { return }
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        Colors.accent.withAlphaComponent(0.1).setFill()
        box.fill()
        let path = NSBezierPath(rect: box)
        path.lineWidth = Look.increasesContrast ? 2 : 1
        path.setLineDash([5, 3], count: 2, phase: 0)
        Colors.accent.setStroke()
        path.stroke()
    }
}
