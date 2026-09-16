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
