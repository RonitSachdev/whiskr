import AppKit
import SwiftUI

/// What the selection's bar shows and does.
@MainActor @Observable
final class SelectionBarModel {
    enum Action: Equatable {
        case turnLeft, turnRight, smaller, larger, shuffle, duplicate, delete, more
        /// A colour chosen from the palette, by its name.
        case colour(String)
        /// A fence's: straight from end to end; a gate hung, or taken away.
        case straighten, gate
    }

    /// One colour of the chosen things' palette: its name, how it looks and what VoiceOver calls it.
    struct Swatch: Equatable, Identifiable {
        var name: String
        var color: Color
        var label: String
        var id: String { name }
    }

    /// How many things are chosen.
    var count = 0
    /// They are living things: they can be sized and shuffled.
    var grows = false
    /// Among them is a thing shown as a parcel (from a newer Whiskr, or with no model yet): they can be moved and
    /// taken away, nothing more.
    var onlyMoves = false
    /// The palette the chosen things share (made things of one kind with colours to choose), and which they wear
    /// (nil when they wear different ones); empty when they share none.
    var swatches: [Swatch] = []
    var wearing: String?
    /// The colours' popover is open.
    var paletteOpen = false {
        didSet { if paletteOpen != oldValue { resized() } }
    }
    /// The bar changed size (the row of swatches opened or closed): placed again over what is chosen.
    @ObservationIgnored var resized: () -> Void = {}
    /// One fence is chosen: its own bar (Straighten, Add Gate, Delete); whether it bends, has a gate, has room for one.
    var fence = false
    var bends = false
    var hasGate = false
    var gateFits = false
    @ObservationIgnored var act: (Action) -> Void = { _ in }
}

/// The selection's bar (docs/DESIGN.md, "Edit Meadow"): floats 12 pt above whatever is chosen in the meadow
/// (below it when there is no room above), following it as the view moves. Turn left and right, smaller and
/// larger and Shuffle for living things, Colour for made things with a palette (a row of swatches in its popover),
/// Duplicate, Delete, and More (Select All Like This, Copy, Paste); for a fence, Straighten, Add Gate (or Remove
/// Gate) and Delete; things shown as parcels can only be moved or taken away, so with one among them only Delete
/// and More show. A
/// floating piece: the chrome's colour, a line round it, radius 10 and the one soft shadow; its buttons are
/// the bars' (hover, pressed and their tooltips with the key; AppKit views under their drawing, `barButton`).
struct SelectionBar: View {
    let model: SelectionBarModel

    /// Room round the bar inside its view for the shadow.
    static let margin: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            buttons
            if model.paletteOpen, !model.swatches.isEmpty {
                Color.line.frame(height: 1).accessibilityHidden(true)
                swatchRow
            }
        }
        .background(RoundedRectangle(cornerRadius: Look.Radius.card).fill(Color.chrome))
        .overlay(RoundedRectangle(cornerRadius: Look.Radius.card).strokeBorder(Look.increasesContrast ? Color.lineStrong : Color.line))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .padding(Self.margin)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.count == 1 ? String(localized: "Chosen thing", comment: "VoiceOver: the selection's bar, one thing chosen")
                                             : String(localized: "\(model.count) chosen things", comment: "VoiceOver: the selection's bar"))
    }

    private var buttons: some View {
        HStack(spacing: Look.Space.xxs) {
            if model.fence {
                button(.straighten, "line.diagonal", String(localized: "Straighten", comment: "Selection bar: makes a fence one straight length from end to end"), key: nil,
                       enabled: model.bends)
                button(.gate, model.hasGate ? "door.left.hand.closed" : "door.left.hand.open",
                       model.hasGate ? String(localized: "Remove Gate", comment: "Selection bar: takes a fence's gate away")
                                     : String(localized: "Add Gate", comment: "Selection bar: hangs a gate in a fence"), key: nil,
                       enabled: model.hasGate || model.gateFits)
                separator
            } else if !model.onlyMoves {
                button(.turnLeft, "rotate.left", String(localized: "Turn Left", comment: "Selection bar"), key: "⇧R")
                button(.turnRight, "rotate.right", String(localized: "Turn Right", comment: "Selection bar"), key: "R")
                if model.grows {
                    separator
                    button(.smaller, "minus", String(localized: "Smaller", comment: "Selection bar"), key: "[")
                    button(.larger, "plus", String(localized: "Larger", comment: "Selection bar"), key: "]")
                    button(.shuffle, "shuffle", String(localized: "Shuffle", comment: "Selection bar: draws a living thing's size, lean and shape again"), key: nil)
                }
                if !model.swatches.isEmpty {
                    separator
                    colourButton
                }
                separator
                button(.duplicate, "plus.square.on.square", String(localized: "Duplicate", comment: "Selection bar"), key: "⌘D")
            }
            button(.delete, "trash", String(localized: "Delete", comment: "Selection bar"), key: "⌫")
            separator
            button(.more, "ellipsis", String(localized: "More", comment: "Selection bar: a menu of further commands"), key: nil)
        }
        .padding(Look.Space.xs)
    }

    /// Colour: opens the palette's row of swatches in the bar itself, under its buttons (a part of the same floating
    /// piece, drawn in the theme's chrome as the bar is, rather than a popover window of its own).
    private var colourButton: some View {
        ChromeIcon(symbol: "paintpalette")
            .barButton("bar.selection.colour", label: String(localized: "Colour", comment: "Selection bar: chooses a made thing's colour from its palette"),
                       help: String(localized: "Colour (C)", comment: "Selection bar: the Colour button's tooltip, with its key"),
                       value: model.swatches.first { $0.name == model.wearing }?.label, selected: model.paletteOpen) { model.paletteOpen.toggle() }
    }

    /// The palette: a swatch for each colour, its name in the tooltip and for VoiceOver, the one worn ringed in the
    /// focus colour (with a tick, so it never rests on colour alone).
    private var swatchRow: some View {
        HStack(spacing: Look.Space.xs) {
            ForEach(model.swatches) { swatch in
                let worn = swatch.name == model.wearing
                Circle().fill(swatch.color)
                    .overlay(Circle().strokeBorder(Look.increasesContrast ? Color.lineStrong : Color.line))
                    .frame(width: 22, height: 22)
                    .overlay {
                        if worn {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 1)
                        }
                    }
                    .padding(3)
                    .overlay(Circle().strokeBorder(worn ? Color.accent : .clear, lineWidth: Look.increasesContrast ? 3 : 2))
                    .barButton("bar.swatch.\(swatch.name)", label: swatch.label, help: swatch.label, selected: worn, radius: 14) { model.act(.colour(swatch.name)) }
            }
        }
        .padding(.horizontal, Look.Space.s)
        .padding(.vertical, Look.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Colours", comment: "VoiceOver: the selection bar's row of colour swatches"))
    }

    private var separator: some View {
        Color.line.frame(width: 1, height: 16).padding(.horizontal, Look.Space.xxs).accessibilityHidden(true)
    }

    private func button(_ action: SelectionBarModel.Action, _ symbol: String, _ label: String, key: String?, enabled: Bool = true) -> some View {
        ChromeIcon(symbol: symbol)
            .barButton("bar.selection.\(String(describing: action))", label: label, help: key.map { "\(label) (\($0))" } ?? label, enabled: enabled) { model.act(action) }
    }
}

/// The selection's bar's view: takes clicks on its buttons only, so the meadow round it keeps the rest.
final class SelectionBarHost: BarHostingView<SelectionBar> {
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
