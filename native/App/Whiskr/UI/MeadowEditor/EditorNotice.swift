import AppKit
import SwiftUI

/// What the quiet bar at the top of edit mode says (docs/DESIGN.md, §8.3 and §8.6), and its buttons: things
/// this Whiskr cannot draw ("Made with a newer Whiskr: 6 things can't be shown here…"), and the meadow being
/// edited changed or removed on disk by something else ("Changed on disk · Reload / Keep Mine"). Nothing
/// when there is nothing to say.
@MainActor @Observable
final class EditorNoticeModel {
    struct Choice: Equatable {
        var title: String
        var id: String
        var isDefault = false
    }

    var text: String?
    /// Its symbol: a parcel for things this Whiskr cannot draw, arrows round for a question about the disk, a
    /// lightbulb for the first hint.
    var symbol = "shippingbox"
    var choices: [Choice] = []
    /// It can be put away (a note; a question cannot, until it is answered).
    var closable = false
    @ObservationIgnored var chose: (String) -> Void = { _ in }
}

/// The bar: a floating piece along the meadow's top edge, in the middle (the chrome's colour, a line round it,
/// radius 10, the one soft shadow), an icon, the words, and its buttons.
struct EditorNotice: View {
    let model: EditorNoticeModel

    /// Room round the bar inside its view for the shadow.
    static let margin: CGFloat = 14

    var body: some View {
        if let text = model.text {
            HStack(spacing: Look.Space.m) {
                Image(systemName: model.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink2)
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.choices, id: \.id) { choice in
                    Button { model.chose(choice.id) } label: {
                        Text(verbatim: choice.title)
                            .font(.system(size: 12, weight: choice.isDefault ? .semibold : .regular))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, Look.Space.m)
                            .frame(height: Look.Height.control - 4)
                            .background(RoundedRectangle(cornerRadius: Look.Radius.control).fill(Color.content))
                            .overlay(RoundedRectangle(cornerRadius: Look.Radius.control).strokeBorder(Color.lineStrong))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title)
                }
                if model.closable {
                    Button { model.chose("close") } label: { ChromeIcon(symbol: "xmark") }
                        .buttonStyle(ChromeButtonStyle())
                        .help(String(localized: "Hide this note", comment: "Meadow editor: the top note's close button"))
                        .accessibilityLabel(String(localized: "Hide this note", comment: "Meadow editor: the top note's close button"))
                }
            }
            .padding(.leading, Look.Space.l)
            .padding(.trailing, model.closable ? Look.Space.xs : Look.Space.l)
            .padding(.vertical, Look.Space.s)
            .frame(maxWidth: 640)
            .background(RoundedRectangle(cornerRadius: Look.Radius.card).fill(Color.chrome))
            .overlay(RoundedRectangle(cornerRadius: Look.Radius.card).strokeBorder(Look.increasesContrast ? Color.lineStrong : Color.line))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
            .padding(Self.margin)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
        }
    }
}

/// The bar's view: takes clicks on the bar only, so the meadow round it keeps the rest.
final class EditorNoticeHost: NSHostingView<EditorNotice> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.insetBy(dx: EditorNotice.margin, dy: EditorNotice.margin).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
