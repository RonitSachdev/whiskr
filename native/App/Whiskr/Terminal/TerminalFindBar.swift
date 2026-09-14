import AppKit
import SwiftTerm

/// Find in a terminal (Edit › Find, ⌘F), floating at the terminal's top right as the editor's find bar
/// sits in its page: a field, how many matches there are and which one is shown, previous and next, and
/// close. SwiftTerm finds the text (`findNext`, `findPrevious`, `searchMatchSummary`); this bar is the
/// app's own, so it takes the theme, the app's words in English and Japanese, and its keys: Return and
/// ⇧Return step, Esc closes it and gives the keyboard back to the terminal. ⌘G and ⇧⌘G step with the bar
/// open or closed, from the shared find text (⌘E sets it from the selection), as every Mac app does.
final class TerminalFindBar: NSView, NSTextFieldDelegate {
    private let field = FindField()
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let close = NSButton()
    /// What the bar asks of its terminal.
    var onSearch: ((String) -> Void)?
    var onStep: ((_ forward: Bool) -> Void)?
    var onClose: (() -> Void)?

    static let width: CGFloat = 340

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Look.Radius.card
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false

        field.placeholderString = String(localized: "Find", comment: "Placeholder of the terminal's find field")
        field.delegate = self
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .default
        field.onCancel = { [weak self] in self?.onClose?() }
        field.setAccessibilityLabel(String(localized: "Find in terminal", comment: "Accessibility: the terminal's find field"))
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        configure(previous, symbol: "chevron.up", help: String(localized: "Previous Match (⇧⌘G)", comment: "Terminal find bar"), action: #selector(stepBack))
        configure(next, symbol: "chevron.down", help: String(localized: "Next Match (⌘G)", comment: "Terminal find bar"), action: #selector(stepForward))
        configure(close, symbol: "xmark", help: String(localized: "Close (Esc)", comment: "Terminal find bar: closes it"), action: #selector(closeBar))

        let stack = NSStackView(views: [field, count, previous, next, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Look.Space.xs
        stack.setCustomSpacing(Look.Space.m, after: count)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Look.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Look.Space.xs),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36),
            widthAnchor.constraint(equalToConstant: Self.width),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Find", comment: "Accessibility: the terminal's find bar"))
        showCount(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalFindBar is created in code")
    }

    private func configure(_ button: NSButton, symbol: String, help: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 24)])
    }

    /// ⌘G and ⇧⌘G while the keyboard is in the field: the field's own text view would take Edit › Find Next
    /// and turn it down.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if hasKeyboard, event.charactersIgnoringModifiers?.lowercased() == "g", flags == .command || flags == [.command, .shift] {
            onStep?(!flags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Clicks reach the bar even in a window that is not the key one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Colors.surface.cgColor
            layer?.borderColor = Colors.line.cgColor
            layer?.shadowColor = NSColor.black.cgColor
        }
        count.textColor = Colors.textTertiary
        for button in [previous, next, close] { button.contentTintColor = Colors.textTertiary }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        updateLayer()
    }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// The keyboard into the field, its text selected so typing replaces it.
    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Whether the keyboard is in the bar.
    var hasKeyboard: Bool {
        guard let editor = window?.firstResponder as? NSView else { return false }
        return editor.isDescendant(of: self)
    }

    /// "3 of 12", "No results", or nothing while the field is empty.
    func showCount(_ summary: (index: Int, total: Int)?) {
        guard let summary, !text.isEmpty else {
            count.stringValue = ""
            previous.isEnabled = false
            next.isEnabled = false
            return
        }
        count.stringValue = summary.total == 0
            ? String(localized: "No results", comment: "Terminal find bar: nothing matches")
            : String(localized: "\(max(summary.index, 1)) of \(summary.total)", comment: "Terminal find bar: which match is shown, of how many")
        count.setAccessibilityLabel(count.stringValue)
        previous.isEnabled = summary.total > 0
        next.isEnabled = summary.total > 0
    }

    func controlTextDidChange(_ notification: Notification) {
        onSearch?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            onStep?(false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func stepBack() { onStep?(false) }
    @objc private func stepForward() { onStep?(true) }
    @objc private func closeBar() { onClose?() }
}

/// The find field: plain and rounded in the content's colour, as the top bar's search field is drawn.
private final class FindField: NSTextField {
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = true
        bezelStyle = .roundedBezel
        controlSize = .small
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        cell?.isScrollable = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("FindField is created in code")
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
