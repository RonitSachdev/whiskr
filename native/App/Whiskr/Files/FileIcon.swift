import AppKit
import CoreText
import SwiftUI
import WhiskrKit

/// Files' icons in Files, tabs, Go to, Changes and the file header: Seti's glyphs, the icons VS Code shows by
/// default (`FileIconTheme`), so a Swift file, a Dockerfile or a README look as people know them. They are
/// template images in one colour, taking the colour of where they sit as SF Symbols do: colour in the chrome
/// means state. Folders keep the system's folder symbol (Seti has none).
enum FileIcon {
    /// The icon of a file called `name`, at `size` points as a symbol would be: 13 in rows and bars, 11 in
    /// tabs and headers. Made once per glyph and size; AppKit keeps each one's drawing per scale, and tints
    /// the template for light, dark and the window's state.
    static func image(for name: String, size: CGFloat) -> NSImage {
        // Seti gives most languages' icons by language (`.ts`, `.py`, `Dockerfile`), not by extension: the
        // language is the one the editor would use, found from the name.
        let icon = FileIconTheme.seti.icon(forFileName: name, languageID: LanguageRegistry.shared.detect(fileName: name).id)
        let key = Key(character: icon.character, size: size)
        if let image = images[key] { return image }
        let image = draw(icon.character, size: size)
        images[key] = image
        return image
    }

    private struct Key: Hashable {
        let character: Character
        let size: CGFloat
    }

    private static var images: [Key: NSImage] = [:]

    /// Seti's font as Core Text reads it from the WOFF file, without installing it anywhere.
    private static let font: CTFontDescriptor? = {
        guard let data = try? Data(contentsOf: FileIconTheme.setiFont) else { return nil }
        return (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.first
    }()

    /// VS Code draws Seti at 150 % of the text's size, centred in a 16 px slot beside 13 px text; the same
    /// proportions here. The glyphs sit in the middle of their em square; the few wider than the slot are
    /// scaled down to fit it rather than cut.
    private static func draw(_ character: Character, size: CGFloat) -> NSImage {
        let side = (size * 16 / 13).rounded()
        let path = font.flatMap { descriptor -> CGPath? in
            let font = CTFontCreateWithFontDescriptor(descriptor, size * 1.5, nil)
            var characters = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return nil }
            // The em square (ascent only: Seti's descent is 0) centred on the slot.
            let em = CTFontGetAscent(font) + CTFontGetDescent(font)
            var transform = CGAffineTransform(translationX: (side - em) / 2, y: (side - em) / 2 + CTFontGetDescent(font))
            return CTFontCreatePathForGlyph(font, glyphs[0], &transform)
        }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let path, let context = NSGraphicsContext.current?.cgContext else { return false }
            let bounds = path.boundingBoxOfPath
            let fit = min(1, rect.width / bounds.width, rect.height / bounds.height)
            context.saveGState()
            if fit < 1 {
                context.translateBy(x: rect.midX, y: rect.midY)
                context.scaleBy(x: fit, y: fit)
                context.translateBy(x: -bounds.midX, y: -bounds.midY)
            }
            context.addPath(path)
            context.setFillColor(.black)
            context.fillPath()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A file's icon in SwiftUI. Decorative: the name beside it says what the file is.
struct FileIconView: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: FileIcon.image(for: name, size: size))
            .renderingMode(.template)
            .accessibilityHidden(true)
    }
}
