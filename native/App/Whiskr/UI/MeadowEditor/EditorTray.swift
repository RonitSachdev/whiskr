import AppKit
import MeadowFile
import MeadowScene
import SwiftUI
import WhiskrMeadow

/// What the editor's tray shows and holds (docs/DESIGN.md, "Edit Meadow"): the tool, the shelf's category, the
/// item armed for placing, what the Brush paints, the Eraser clears and the Ground tool paints, how wide and how
/// thickly, the filter, whether it is folded to its top row, and the pictures of the things on its shelf.
@MainActor @Observable
final class EditorTray {
    enum Tool: String, CaseIterable {
        case select, brush, erase, ground
    }

    /// One tile of the shelf: a thing of the catalog, the Brush's wildflower mix, the Eraser's "any kind", or a
    /// ground paint (the wild grass among them).
    struct Item: Identifiable, Equatable {
        /// The asset's id, or `wildflowers` or `anyKind`.
        let id: String
        let name: String
        let category: MeadowAsset.Category?
        /// What its picture shows.
        let pictured: [String]
    }

    static let wildflowers = "mix.wildflowers"
    static let anyKind = "any.kind"

    var tool: Tool = .select
    var category: MeadowAsset.Category = .trees
    /// The thing armed for placing (the Select tool's), by asset id.
    var armed: String?
    var brushKind = EditorTray.wildflowers
    var eraseKind = EditorTray.anyKind
    /// What the Ground tool paints: a paint's id, or the wild grass's (`ground.wild`).
    var groundPaint = "ground.path"
    var brushRadius = MeadowBrush.usualRadius
    var eraseRadius = EditorTray.usualEraseRadius
    var groundRadius = MeadowEditSession.usualGroundRadius
    var density: MeadowBrush.Density = .natural
    var filter = ""
    var collapsed = false
    /// Under 760 pt: tools and categories as symbols, the hint left out.
    var narrow = false
    /// What to do now, in a line ("Click to place · ⇧-click to place more…").
    var hint = ""
    /// How full the meadow is, shown only past 80 % of a cap ("4,212 of 5,000 things").
    var fullness: String?
    /// Kinds the meadow holds as many of as it can: their tiles say why instead of arming.
    var full: [String: String] = [:]
    /// Each tile's picture, by item id (`EditorTray.pictureKey`).
    var pictures: [String: CGImage] = [:]
    /// The tile the keyboard is on, while the shelf has the keyboard.
    var highlighted: String?
    var shelfHasKeyboard = false
    /// The filter field takes the keyboard (⌘F).
    var findRequests = 0
    /// The tile being dragged onto the meadow.
    var dragging: String?

    static let usualEraseRadius = 3.0
    static let eraseRadii: ClosedRange<Double> = 1...10

    /// What the tray asks of the editor.
    enum Action {
        case tool(Tool)
        case category(MeadowAsset.Category)
        /// A tile clicked (or Return on it): armed, or chosen as the Brush's or the Eraser's kind.
        case choose(String)
        /// A tile double-clicked: armed and placed at once where the keyboard's cursor (or the view's middle) is.
        case placeNow(String)
        /// A tile pressed and dragged out over the meadow: the pointer in the window, and let go.
        case drag(String, NSPoint, ended: Bool)
        case radius(Double)
        case density(MeadowBrush.Density)
        case collapse
        /// Return in the filter field: the first thing it finds.
        case filterReturn
        /// Esc in the filter field, or out of the shelf: the keyboard back to the meadow.
        case keyboardBack
    }

    @ObservationIgnored var act: (Action) -> Void = { _ in }

    // MARK: The catalog's things

    /// Every thing the tray offers: the catalog's, in its order (the fence among them, laid in runs), that this
    /// Whiskr draws (others join by themselves as the scene learns to draw them).
    static let things: [Item] = MeadowCatalog.current.assets.filter { asset in
        asset.inTray && MeadowScenery.draws(asset.id)
    }.map { Item(id: $0.id, name: MeadowWords.name($0.id), category: shelved[$0.id] ?? $0.category, pictured: [$0.id]) }

    /// Things the tray shelves away from their catalog category, where people look for them: the garden lamp
    /// stands with the Garden (catalog 1 files it under Workplace, and a catalog's categories are frozen with it).
    static let shelved: [String: MeadowAsset.Category] = ["work.lampPost": .garden]

    /// The shelf a thing is offered on (nil: the tray does not offer it).
    static func shelf(of id: String) -> MeadowAsset.Category? { things.first { $0.id == id }?.category }

    /// The categories that hold something, in the catalog's order: those of things, and the ground's paints
    /// (whose tab is the Ground tool's).
    static var categories: [MeadowAsset.Category] {
        MeadowAsset.Category.allCases.filter { category in category == .ground || things.contains { $0.category == category } }
    }

    /// The Ground tool's shelf: path, lawn and soil, then the wild grass that paints them away.
    static let paints: [Item] = MeadowCatalog.current.assets.filter { asset in
        asset.inTray && asset.category == .ground && MeadowScenery.Ground.Paint(id: asset.id) != nil
    }.map { Item(id: $0.id, name: MeadowWords.name($0.id), category: .ground, pictured: [$0.id]) }

    /// What the shelf shows now: the Select tool's things of the category (or every match while filtering),
    /// the Brush's plants after its wildflower mix, the Eraser's kinds after "any kind".
    var shelf: [Item] {
        switch tool {
        case .select:
            let query = filter.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty { return Self.things.filter { Self.matches($0, query) } }
            return Self.things.filter { $0.category == category }
        case .brush: return Self.brushes
        case .erase: return Self.erasers
        case .ground: return Self.paints
        }
    }

    /// Whether the filter's `query` finds `item`: in its name, its shelf's name, the other words it goes by
    /// (`MeadowWords.keywords`) or its id (so "cat" and "post" find their things in any language), ignoring case,
    /// accents and, in Japanese, hiragana against katakana.
    static func matches(_ item: Item, _ query: String) -> Bool {
        func folded(_ text: String) -> String { text.applyingTransform(.hiraganaToKatakana, reverse: false) ?? text }
        let words = [item.name, MeadowWords.categoryName(item.category), MeadowWords.keywords(item.id), item.id].map(folded)
        let wanted = folded(query)
        return words.contains { $0.localizedStandardContains(wanted) }
    }

    /// The Brush's shelf: its wildflower mix, then the plants it paints.
    static var brushes: [Item] {
        [Item(id: wildflowers, name: MeadowWords.wildflowers, category: nil, pictured: MeadowBrush.wildflowers.map(\.asset))]
            + things.filter { MeadowCatalog.current.asset($0.id).map(MeadowBrush.paints) ?? false }
    }

    /// The Eraser's shelf: any kind, then each small kind it can be kept to (what its sweep takes).
    static var erasers: [Item] {
        [Item(id: anyKind, name: MeadowWords.anyKind, category: nil, pictured: [])] + things.filter { SceneryRules.isSmall($0.id) }
    }

    /// The tile chosen on the shelf now: the armed thing, or the Brush's or the Eraser's kind.
    var chosen: String? {
        switch tool {
        case .select: armed
        case .brush: brushKind
        case .erase: eraseKind
        case .ground: groundPaint
        }
    }

    /// A tile's picture, keyed by what it shows, its pixels and the colour behind it.
    static func pictureKey(_ item: Item, pixels: Int, background: MeadowColor) -> String {
        "\(item.pictured.joined(separator: "+"))@\(pixels)#\(background.red),\(background.green),\(background.blue)"
    }

    /// The tile's side, in points.
    static let tile: CGFloat = 64
    /// The rows' heights: the tools, the categories, the shelf (a tile, its name, and room round them).
    static let toolsRow = Look.Height.tabRow
    static let categoriesRow: CGFloat = 28
    static let shelfRow: CGFloat = 98

    /// The card's height, folded or not.
    var cardHeight: CGFloat { collapsed ? Self.toolsRow : Self.toolsRow + 1 + Self.categoriesRow + Self.shelfRow }
}

/// The editor's tray (docs/DESIGN.md, "Edit Meadow"): a floating piece along the meadow's bottom edge. Its top
/// row holds the tools (Select V, Brush B, Erase E, Ground G), the Brush's, the Eraser's and the Ground tool's
/// size and the Brush's density, how full the meadow is (past 80 % of a cap), the filter field (⌘F) and the fold; below, the
/// categories (1–7) and a line saying what to do now; then the shelf of things, each pictured by the scene in its
/// own clay. Folded, only the top row shows. The chrome's colour, a line round it, radius 10, the one soft
/// shadow; its buttons are the bars'.
struct EditorTrayView: View {
    let tray: EditorTray
    @FocusState private var filterFocused: Bool

    /// Room round the card inside its view for the shadow.
    static let margin: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolsRow
            if !tray.collapsed {
                Color.line.frame(height: 1).accessibilityHidden(true)
                categoriesRow
                shelf
            }
        }
        .background(RoundedRectangle(cornerRadius: Look.Radius.card).fill(Color.chrome))
        .overlay(RoundedRectangle(cornerRadius: Look.Radius.card).strokeBorder(Look.increasesContrast ? Color.lineStrong : Color.line))
        .clipShape(RoundedRectangle(cornerRadius: Look.Radius.card))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .padding(Self.margin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Meadow editor's tray", comment: "VoiceOver: the tray of tools and things while editing the meadow"))
        .onChange(of: tray.findRequests) { filterFocused = true }
    }

    // MARK: The top row

    private var toolsRow: some View {
        HStack(spacing: Look.Space.xs) {
            ForEach(EditorTray.Tool.allCases, id: \.self) { tool in
                toolButton(tool)
            }
            if tray.tool != .select {
                divider
                sizeControl
                if tray.tool == .brush, !tray.narrow { densityControl }
            }
            Spacer(minLength: Look.Space.m)
            if let fullness = tray.fullness {
                Text(fullness)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(fullness)
            }
            if tray.tool == .select { filterField }
            ChromeIcon(symbol: tray.collapsed ? "chevron.up" : "chevron.down")
                .barButton("tray.fold", label: tray.collapsed ? String(localized: "Show the Shelf", comment: "Meadow editor's tray: unfolds it")
                                                               : String(localized: "Fold the Tray", comment: "Meadow editor's tray: folds it to its top row"),
                           help: (tray.collapsed ? String(localized: "Show the Shelf", comment: "Meadow editor's tray: unfolds it")
                                                 : String(localized: "Fold the Tray", comment: "Meadow editor's tray: folds it to its top row")) + " (⌥⌘T)") {
                    tray.act(.collapse)
                }
        }
        .padding(.horizontal, Look.Space.s)
        .frame(height: EditorTray.toolsRow)
    }

    private func toolButton(_ tool: EditorTray.Tool) -> some View {
        let (name, symbol, key) = Self.describe(tool)
        let selected = tray.tool == tool
        return HStack(spacing: Look.Space.xs) {
            Image(systemName: symbol).font(Look.icon)
            if !tray.narrow {
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Text(key).font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
        }
        .foregroundStyle(selected ? Color.ink : Color.ink2)
        .padding(.horizontal, tray.narrow ? 0 : Look.Space.m)
        .frame(minWidth: Look.Height.iconButton)
        .frame(height: Look.Height.control)
        .barButton("tray.tool.\(tool.rawValue)", label: name, help: "\(name) (\(key))", selected: selected) { tray.act(.tool(tool)) }
    }

    static func describe(_ tool: EditorTray.Tool) -> (name: String, symbol: String, key: String) {
        switch tool {
        case .select: (String(localized: "Select", comment: "Meadow editor's tool: choose, move and place things"), "cursorarrow", "V")
        case .brush: (String(localized: "Brush", comment: "Meadow editor's tool: paints flowers"), "paintbrush.pointed", "B")
        case .erase: (String(localized: "Erase", comment: "Meadow editor's tool: takes things away"), "eraser", "E")
        case .ground: (String(localized: "Ground", comment: "Meadow editor's tool: paints paths, lawn and soil"), "square.split.diagonal.2x2", "G")
        }
    }

    private var divider: some View {
        Color.line.frame(width: 1, height: 16).padding(.horizontal, Look.Space.xs).accessibilityHidden(true)
    }

    private var sizeControl: some View {
        let range = switch tray.tool {
        case .erase: EditorTray.eraseRadii
        case .ground: MeadowEditSession.groundRadii
        default: MeadowBrush.radii
        }
        let value = Binding(get: {
            switch tray.tool {
            case .erase: tray.eraseRadius
            case .ground: tray.groundRadius
            default: tray.brushRadius
            }
        }, set: { tray.act(.radius($0)) })
        return HStack(spacing: Look.Space.s) {
            if !tray.narrow {
                Text(String(localized: "Size", comment: "Meadow editor's tray: the Brush's or the Eraser's size"))
                    .font(.system(size: 11)).foregroundStyle(Color.ink2)
            }
            Slider(value: value, in: range)
                .controlSize(.mini)
                .frame(width: tray.narrow ? 64 : 96)
                .help(String(localized: "Size ([ and ])", comment: "Meadow editor's tray: the size slider's tooltip"))
                .accessibilityLabel(sizeLabel)
                .accessibilityValue(String(localized: "\(Int(value.wrappedValue.rounded())) units across", comment: "VoiceOver: the brush's radius in the meadow's units"))
        }
    }

    private var sizeLabel: String {
        switch tray.tool {
        case .erase: String(localized: "Eraser size", comment: "VoiceOver: the Eraser's size slider")
        case .ground: String(localized: "Ground brush size", comment: "VoiceOver: the Ground tool's size slider")
        default: String(localized: "Brush size", comment: "VoiceOver: the Brush's size slider")
        }
    }

    private var densityControl: some View {
        HStack(spacing: Look.Space.xxs) {
            ForEach(MeadowBrush.Density.allCases, id: \.self) { density in
                let name = MeadowWords.density(density)
                Text(name)
                    .font(.system(size: 11, weight: tray.density == density ? .semibold : .regular))
                    .foregroundStyle(tray.density == density ? Color.ink : Color.ink2)
                    .padding(.horizontal, Look.Space.s)
                    .frame(height: Look.Height.control - 4)
                    .barButton("tray.density.\(density.rawValue)", label: name, help: String(localized: "How thickly the Brush plants: \(name)", comment: "Meadow editor's tray: a density's tooltip"),
                               selected: tray.density == density) { tray.act(.density(density)) }
            }
        }
        .padding(.leading, Look.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Density", comment: "VoiceOver: how thickly the Brush plants"))
    }

    private var filterField: some View {
        HStack(spacing: Look.Space.xs) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.ink3).accessibilityHidden(true)
            TextField(String(localized: "Filter", comment: "Meadow editor's tray: the filter field's placeholder"), text: Binding(get: { tray.filter }, set: { tray.filter = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                .onSubmit { tray.act(.filterReturn) }
                .onExitCommand {
                    tray.filter = ""
                    filterFocused = false
                    tray.act(.keyboardBack)
                }
                .accessibilityLabel(String(localized: "Filter things", comment: "VoiceOver: the tray's filter field"))
                .help(String(localized: "Filter the things on the shelf (⌘F)", comment: "Meadow editor's tray: the filter field's tooltip"))
        }
        .padding(.horizontal, Look.Space.s)
        .frame(width: tray.narrow ? 120 : 168, height: Look.Height.control - 4)
        .background(RoundedRectangle(cornerRadius: Look.Radius.control).fill(Color.well))
    }

    // MARK: Categories and the hint

    private var categoriesRow: some View {
        HStack(spacing: Look.Space.xxs) {
            if tray.tool == .select || tray.tool == .ground {
                let filtering = tray.tool == .select && !tray.filter.trimmingCharacters(in: .whitespaces).isEmpty
                ForEach(Array(EditorTray.categories.enumerated()), id: \.element) { index, category in
                    categoryButton(category, number: index + 1, selected: !filtering && (tray.tool == .ground ? category == .ground : tray.category == category))
                }
            }
            Spacer(minLength: Look.Space.m)
            if !tray.narrow {
                Text(tray.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Look.Space.s)
        .frame(height: EditorTray.categoriesRow)
    }

    private func categoryButton(_ category: MeadowAsset.Category, number: Int, selected: Bool) -> some View {
        let name = MeadowWords.categoryName(category)
        return Group {
            if tray.narrow {
                Image(systemName: MeadowWords.categorySymbol(category)).font(Look.smallIcon).frame(width: Look.Height.iconButton)
            } else {
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular)).padding(.horizontal, Look.Space.m)
            }
        }
        .foregroundStyle(selected ? Color.ink : Color.ink2)
        .frame(height: Look.Height.control - 4)
        .barButton("tray.category.\(category.rawValue)", label: name, help: "\(name) (\(number))", selected: selected) { tray.act(.category(category)) }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: The shelf

    private var shelf: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Look.Space.m) {
                    ForEach(tray.shelf) { item in
                        TrayTile(tray: tray, item: item).id(item.id)
                    }
                    if tray.shelf.isEmpty {
                        Text(String(localized: "Nothing by that name", comment: "Meadow editor's tray: the filter found nothing"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink2)
                            .frame(height: EditorTray.tile)
                    }
                }
                .padding(.horizontal, Look.Space.m)
                .padding(.top, Look.Space.xxs)
                .padding(.bottom, Look.Space.m)
            }
            .onChange(of: tray.highlighted) { if let id = tray.highlighted { proxy.scrollTo(id) } }
        }
        .frame(height: EditorTray.shelfRow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Things", comment: "VoiceOver: the tray's shelf of things"))
    }
}

/// A tile of the shelf: the thing's picture in a tile of the content colour, its name under it. Clicked, it is
/// armed (or chosen as what the Brush paints or the Eraser clears); double-clicked, it is placed at once; pressed
/// and dragged out over the meadow, it is placed where it is let go. A ring of the focus colour marks the one
/// chosen, a fainter one the one the keyboard is on.
private struct TrayTile: View {
    let tray: EditorTray
    let item: EditorTray.Item

    var body: some View {
        let chosen = tray.chosen == item.id
        let keyed = tray.shelfHasKeyboard && tray.highlighted == item.id
        let full = tray.full[item.id]
        let corner = Look.Radius.control
        VStack(spacing: Look.Space.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: corner).fill(Color.content)
                if let picture = tray.pictures[item.id] {
                    Image(decorative: picture, scale: CGFloat(picture.width) / EditorTray.tile)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(RoundedRectangle(cornerRadius: corner))
                        .opacity(full == nil ? 1 : 0.4)
                } else if item.id == EditorTray.anyKind {
                    Image(systemName: "eraser").font(.system(size: 22)).foregroundStyle(Color.ink2)
                }
                if full != nil {
                    Image(systemName: "nosign").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(Look.Space.xs)
                }
            }
            .frame(width: EditorTray.tile, height: EditorTray.tile)
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.line))
            .overlay(RoundedRectangle(cornerRadius: corner + 2).strokeBorder(Color.accent, lineWidth: chosen ? (Look.increasesContrast ? 3 : 2) : 0).padding(-3))
            .overlay(RoundedRectangle(cornerRadius: corner + 2).strokeBorder(Color.accent.opacity(0.55), lineWidth: keyed && !chosen ? 2 : 0).padding(-3))
            .opacity(tray.dragging == item.id ? 0.5 : 1)
            Text(item.name)
                .font(.system(size: 11))
                .foregroundStyle(chosen ? Color.ink : Color.ink2)
                .lineLimit(1)
                // A longer name ("Stepping stone") a little smaller rather than cut short.
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
                .frame(width: EditorTray.tile + Look.Space.m)
        }
        .contentShape(Rectangle())
        .overlay(TrayTileControl(id: item.id, tray: tray, help: full.map { "\(item.name): \($0)" } ?? item.name))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityHint(full ?? "")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { tray.act(.choose(item.id)) }
    }
}

/// The pointer on a tile, in AppKit (as the bars' controls take theirs, `BarControlView`): a click chooses it,
/// a double-click places it at once, a press dragged out of the tray carries it onto the meadow.
private struct TrayTileControl: NSViewRepresentable {
    let id: String
    let tray: EditorTray
    let help: String

    func makeNSView(context: Context) -> TrayTileView { TrayTileView() }

    func updateNSView(_ view: TrayTileView, context: Context) {
        view.item = id
        view.tray = tray
        view.toolTip = help
        view.identifier = NSUserInterfaceItemIdentifier("tray.item.\(id)")
    }
}

final class TrayTileView: NSView {
    var item = ""
    weak var tray: EditorTray?
    private var pressedAt: NSPoint?
    private var dragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
        dragging = false
        if event.clickCount == 2 {
            pressedAt = nil
            tray?.act(.placeNow(item))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt else { return }
        if !dragging, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 { return }
        dragging = true
        tray?.act(.drag(item, event.locationInWindow, ended: false))
    }

    /// A mouse's wheel turns up and down only: over the shelf it scrolls the shelf along. A trackpad's sideways
    /// swipe is the shelf's own.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let shelf = enclosingScrollView {
            EditorTrayHost.scrollAlong(shelf, by: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil; dragging = false }
        guard pressedAt != nil else { return }
        if dragging {
            tray?.act(.drag(item, event.locationInWindow, ended: true))
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            tray?.act(.choose(item))
        }
    }
}

/// The tray's view: it takes clicks on its card only (the meadow round it keeps the rest), each tile's press its
/// own and each of the bars' controls theirs.
final class EditorTrayHost: BarHostingView<EditorTrayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.insetBy(dx: EditorTrayView.margin, dy: EditorTrayView.margin).contains(local) else { return nil }
        let hit = super.hitTest(point)
        if hit is NSText || hit is NSControl || hit is BarControlView { return hit }
        return tile(in: self, at: point) ?? hit
    }

    private func tile(in view: NSView, at point: NSPoint) -> NSView? {
        for sub in view.subviews.reversed() where !sub.isHidden {
            if sub is TrayTileView, sub.convert(sub.bounds, to: superview).contains(point) { return sub }
            if let found = tile(in: sub, at: point) { return found }
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The wheel over the tray is the tray's: what reaches the card scrolls the shelf, and never zooms the meadow
    /// behind it.
    override func scrollWheel(with event: NSEvent) {
        if let shelf = shelf(in: self) { Self.scrollAlong(shelf, by: event) }
    }

    private func shelf(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView { return scroll }
            if let found = shelf(in: sub) { return found }
        }
        return nil
    }

    /// Scrolls the shelf along by a wheel's turn: down or right goes on along it, up or left back; a line of a
    /// mouse's wheel is a tile's width.
    static func scrollAlong(_ shelf: NSScrollView, by event: NSEvent) {
        let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        let step = event.hasPreciseScrollingDeltas ? delta : delta * (EditorTray.tile + Look.Space.m) / 3
        let clip = shelf.contentView, width = shelf.documentView?.frame.width ?? 0
        let x = min(max(clip.bounds.origin.x - step, 0), max(width - clip.bounds.width, 0))
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        shelf.reflectScrolledClipView(clip)
    }
}

/// The shelf with the keyboard (Tab from the meadow): ← and → go from tile to tile, Return chooses (an armed
/// thing then waits in the meadow at the keyboard's cursor), Tab, ⇧Tab and Esc go back to the meadow; the
/// editor's other keys (tools, categories, sizes) work here as there. Draws nothing: the tile it is on has a ring.
final class TrayKeys: NSView {
    weak var tray: EditorTray?
    /// The editor's own keys, when they are not the shelf's, and its keys with ⌘ before the menus (⌘↩ Done).
    var editorKey: (NSEvent) -> Bool = { _ in false }
    var editorKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, editorKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func becomeFirstResponder() -> Bool {
        tray?.shelfHasKeyboard = true
        if let tray, tray.highlighted == nil || !tray.shelf.contains(where: { $0.id == tray.highlighted }) {
            tray.highlighted = tray.chosen.flatMap { id in tray.shelf.contains { $0.id == id } ? id : nil } ?? tray.shelf.first?.id
        }
        announceHighlighted()
        return true
    }

    override func resignFirstResponder() -> Bool {
        tray?.shelfHasKeyboard = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let tray else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let shelf = tray.shelf
        let at = shelf.firstIndex { $0.id == tray.highlighted } ?? 0
        switch (event.keyCode, flags.isEmpty) {
        case (123, true), (124, true):
            guard !shelf.isEmpty else { return }
            tray.highlighted = shelf[(at + (event.keyCode == 124 ? 1 : -1) + shelf.count) % shelf.count].id
            announceHighlighted()
        case (36, true), (76, true):
            // Chosen, and the keyboard back in the meadow, where a thing to place waits at the cursor (and
            // Return places it), or the Brush or the Eraser dabs.
            guard let id = tray.highlighted else { return }
            tray.act(.choose(id))
            tray.act(.keyboardBack)
        case (48, _), (53, _):
            tray.act(.keyboardBack)
        default:
            if !editorKey(event) { super.keyDown(with: event) }
        }
    }

    private func announceHighlighted() {
        guard let tray, let item = tray.shelf.first(where: { $0.id == tray.highlighted }) else { return }
        let text = tray.full[item.id].map { "\(item.name), \($0)" } ?? item.name
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
