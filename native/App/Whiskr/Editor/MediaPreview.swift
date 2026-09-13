import AppKit
import PDFKit
import SwiftUI
import WhiskrKit

/// A picture file (PNG, JPEG, GIF, which plays, SVG, WebP, HEIC…): fitted to the page, or at its actual
/// size; pinch to zoom.
final class ImagePreview: NSView {
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private(set) var image: NSImage?
    var fitsPage = true { didSet { layoutImage() } }

    init(url: URL) {
        super.init(frame: .zero)
        image = NSImage(contentsOf: url)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.setAccessibilityLabel(url.lastPathComponent)
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = false
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = imageView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ImagePreview is created in code")
    }

    override func layout() {
        super.layout()
        layoutImage()
    }

    /// Fitted: as large as the page allows without going past the picture's own size, with a margin.
    /// Actual size: one image point per screen point.
    private func layoutImage() {
        guard let image else { return }
        let natural = image.size
        let room = NSSize(width: max(1, bounds.width - 48), height: max(1, bounds.height - 48))
        let scale = fitsPage ? min(1, room.width / max(natural.width, 1), room.height / max(natural.height, 1)) : 1
        scrollView.magnification = 1
        imageView.frame = NSRect(origin: .zero, size: NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded()))
    }
}

/// Keeps a document smaller than the view in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// A PDF, page after page, fitted to the width.
final class PDFPreview: NSView {
    private let view = PDFView()

    init(url: URL) {
        super.init(frame: .zero)
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateLook()
    }

    required init?(coder: NSCoder) {
        fatalError("PDFPreview is created in code")
    }

    var pageCount: Int { view.document?.pageCount ?? 0 }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook()
    }

    private func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            view.backgroundColor = Colors.well
        }
    }
}

/// What shows instead of a file that cannot be shown here: not text, too large, gone, unreadable. It
/// says which, calmly, and offers the two ways on: the app that opens it, and Finder.
struct UnreadablePage: View {
    let document: FileDocument

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: document.url.path))
                .resizable()
                .frame(width: 64, height: 64)
                .opacity(document.content == .missing ? 0.4 : 1)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(document.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink2)
                    .multilineTextAlignment(.center)
            }
            if document.content != .missing {
                HStack(spacing: 10) {
                    Button(openTitle) { NSWorkspace.shared.open(document.url) }
                        .keyboardShortcut(.defaultAction)
                    Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Colors.terminalBackground))
    }

    private var reason: String {
        switch document.content {
        case .binary: String(localized: "This file isn’t text, so it can’t be shown here.")
        case .tooLarge(let bytes): String(localized: "At \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), this file is too large to open here.")
        case .missing: String(localized: "This file no longer exists. It may have been moved or deleted.")
        case .unreadable(let why): String(localized: "This file couldn’t be read: \(why)")
        default: ""
        }
    }

    private var openTitle: String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: document.url) else { return String(localized: "Open with Default App") }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        return String(localized: "Open with \(name)", comment: "A button: opens the file in the app that handles it")
    }
}
