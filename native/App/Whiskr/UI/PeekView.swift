import AppKit
import SwiftUI
import WhiskrKit

/// A helper terminal with no tab of its own (started by an agent with `paw run --bg`), looked at over
/// the panes (herdr's peek): its real terminal on a card, which you can type into, with who it is
/// above it, Keep as Tab and a close button. The panes stay where they were beneath a light veil; a
/// click on the veil, the close button or ⌘W puts the card away, and the terminal runs on.
final class PeekOverlay: NSView {
    private let workbench: Workbench
    private let veil = PeekVeil()
    private let card = NSView()
    private let header: NSHostingView<PeekHeader>
    private let terminalHost = NSView()
    private var shown: Pane?
    private var observer: Observing?

    init(workbench: Workbench) {
        self.workbench = workbench
        header = NSHostingView(rootView: PeekHeader(workbench: workbench, pane: nil))
        super.init(frame: .zero)
        isHidden = true
        veil.onClick = { [weak workbench] in workbench?.closePeek() }
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        terminalHost.clipsToBounds = true
        header.sizingOptions = []
        for part in [veil, card] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        for part in [header, terminalHost] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(part)
        }
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        card.shadow = shadow
        NSLayoutConstraint.activate([
            veil.topAnchor.constraint(equalTo: topAnchor), veil.bottomAnchor.constraint(equalTo: bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: leadingAnchor), veil.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 14), card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: card.topAnchor), header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor), header.heightAnchor.constraint(equalToConstant: PeekHeader.height),
            terminalHost.topAnchor.constraint(equalTo: header.bottomAnchor), terminalHost.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: card.leadingAnchor), terminalHost.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        observer = Observing { [weak self] in self?.update() }
    }

    required init?(coder: NSCoder) {
        fatalError("PeekOverlay is created in code")
    }

    /// Clicks reach it only while it shows.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }

    private func update() {
        let pane = workbench.peekedPane.flatMap { workbench.panes[$0] }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = Colors.terminalBackground.cgColor
            card.layer?.borderColor = Colors.line.cgColor
        }
        header.rootView = PeekHeader(workbench: workbench, pane: pane)
        guard pane !== shown else { return }
        shown?.surface.removeFromSuperview()
        shown = pane
        isHidden = pane == nil
        guard let pane else { return }
        let surface = pane.surface
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: terminalHost.topAnchor, constant: 8),
            surface.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor, constant: 12),
            surface.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor, constant: -4),
            surface.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor, constant: -8),
        ])
        setAccessibilityLabel(String(localized: "Helper terminal \(workbench.name(of: pane))", comment: "Accessibility: a helper terminal looked at over the panes"))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shown === pane, surface.window != nil else { return }
            self.window?.makeFirstResponder(surface)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }
}

/// The light veil over the panes behind a peek: a click on it puts the peek away.
private final class PeekVeil: NSView {
    var onClick: () -> Void = {}

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (Palette.isDark(effectiveAppearance) ? NSColor.black : NSColor.white).withAlphaComponent(0.35).cgColor
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// Who the helper is, who started it, and what you can do: keep it as a tab, or put it away.
struct PeekHeader: View {
    let workbench: Workbench
    let pane: Pane?

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 8) {
            if let pane {
                Image(systemName: pane.agentRunning ? "pawprint.fill" : "apple.terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
                    .accessibilityHidden(true)
                if let status = workbench.status(of: pane) { StateMark(status: status) }
                Text(title(pane))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let address = pane.address {
                    Text(address)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Color.ink3)
                        .help(String(localized: "Its address: paw send \(address) … reaches it", comment: "Peek: a helper terminal's address"))
                }
                if let boss = workbench.boss(of: pane) {
                    Text(String(localized: "helper of \(workbench.name(of: boss))", comment: "Peek: which Claude started this terminal"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(String(localized: "Keep as Tab")) { workbench.keepAsTab(pane.id) }
                    .controlSize(.small)
                    .help(String(localized: "Give this terminal a tab of its own, after its boss's"))
                Button {
                    workbench.closePeek()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.ink2)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Put it away (⌘W); it keeps running"))
                .accessibilityLabel(String(localized: "Close"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Colors.terminalBackground).overlay(Color.primary.opacity(0.06)))
        .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
    }

    /// Its name (`paw run --name`), else what runs in it.
    private func title(_ pane: Pane) -> String {
        if let name = pane.terminalName, !pane.agentRunning { return name }
        let name = workbench.name(of: pane)
        if let given = pane.terminalName, given != name { return "\(given) · \(name)" }
        return name
    }
}
