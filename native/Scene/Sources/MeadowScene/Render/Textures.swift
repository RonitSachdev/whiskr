import AppKit
import CoreText
@preconcurrency import Metal

// Textures drawn with Core Graphics and Core Text, the way the web draws them on a canvas: the bubbles
// above cats (props.ts `bubbleTexture`) and the name flags (Flag.ts). Pixels are premultiplied sRGB.

enum Paint {
    /// Draws into a premultiplied RGBA bitmap with the origin at the top left (like a canvas) and
    /// uploads it with mipmaps.
    static func texture(_ device: MTLDevice, queue: MTLCommandQueue, width: Int, height: Int, label: String, draw: (CGContext) -> Void) -> MTLTexture {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        draw(ctx)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: true)
        d.usage = .shaderRead
        let tex = device.makeTexture(descriptor: d)!
        tex.label = label
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: width * 4)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
        }
        return tex
    }

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    static func color(_ c: MeadowColor, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: alpha)
    }

    /// A rounded system font (ui-rounded / SF Pro Rounded), as the web's bubbles ask for.
    static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f as CTFont }
        return base as CTFont
    }
    static func system(_ size: CGFloat, weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

    static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }
    static func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    /// Draws a line of text centred on (x, y) in canvas coordinates (y down), `textBaseline = middle`.
    static func draw(_ line: CTLine, in ctx: CGContext, centerX: CGFloat? = nil, left: CGFloat? = nil, middleY: CGFloat) {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let x = centerX.map { $0 - w / 2 } ?? left ?? 0
        ctx.saveGState()
        // Flip back to y up for Core Text, around the text's own baseline.
        let baseline = middleY + (ascent - descent) / 2
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// The note one cat hands another (a task, a report, a message): a little white speech bubble with a
    /// tail, outlined in ink, three dots inside. No words: what it says is in the terminals.
    static func note(_ device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture {
        texture(device, queue: queue, width: 256, height: 256, label: "note") { c in
            let body = CGMutablePath()
            body.addRoundedRect(in: CGRect(x: 30, y: 52, width: 196, height: 128), cornerWidth: 58, cornerHeight: 58)
            // The tail, curling down from the lower left.
            body.move(to: CGPoint(x: 76, y: 168))
            body.addQuadCurve(to: CGPoint(x: 54, y: 214), control: CGPoint(x: 78, y: 198))
            body.addQuadCurve(to: CGPoint(x: 116, y: 176), control: CGPoint(x: 96, y: 206))
            c.setFillColor(color(0xffffff))
            c.setStrokeColor(color(0x242428))
            c.setLineWidth(9)
            c.setLineJoin(.round)
            c.addPath(body)
            c.drawPath(using: .fillStroke)
            // The outline where the tail meets the bubble is painted over, so the two read as one.
            c.addPath(CGPath(roundedRect: CGRect(x: 36, y: 58, width: 184, height: 116), cornerWidth: 52, cornerHeight: 52, transform: nil))
            c.fillPath()
            c.setFillColor(color(0x242428))
            for x in [88.0, 128, 168] { c.fillEllipse(in: CGRect(x: x - 13, y: 103, width: 26, height: 26)) }
        }
    }

    /// props.ts `bubbleTexture`: a white thought bubble with two trailing dots, outlined in ink, and the
    /// symbol in the middle. The Mac design's "needs you" bubble is red (`alert`) with a white mark.
    static func bubble(_ device: MTLDevice, queue: MTLCommandQueue, _ mark: BubbleMark, alert: MeadowColor = MeadowChrome.standard.alert) -> MTLTexture {
        texture(device, queue: queue, width: 256, height: 256, label: "bubble \(mark)") { c in
            // Request and error: the alert colour (vermillion); finished: blue (Okabe–Ito), so the three
            // marks differ by glyph and colour alike. The rest are quiet white thought bubbles.
            let red = mark == .needsYou || mark == .error
            let blue = mark == .done
            c.setFillColor(red ? color(alert) : blue ? color(0x0072b2) : color(0xffffff))
            c.setStrokeColor(color(0x242428))
            c.setLineWidth(9)
            for (x, y, r) in [(128.0, 104.0, 88.0), (196, 204, 17), (226, 236, 8)] {
                c.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                c.drawPath(using: .fillStroke)
            }
            let ink = red || blue ? color(0xffffff) : color(0x242428)
            if mark == .done {
                // A check drawn as a stroke, as the design's bubble has it.
                c.setStrokeColor(ink)
                c.setLineWidth(17)
                c.setLineCap(.round)
                c.setLineJoin(.round)
                c.move(to: CGPoint(x: 90, y: 108)); c.addLine(to: CGPoint(x: 118, y: 134)); c.addLine(to: CGPoint(x: 168, y: 78))
                c.strokePath()
            } else {
                draw(line(mark.symbol, font: rounded(104, weight: .bold), color: ink), in: c, centerX: 128, middleY: mark == .thinking ? 92 : 110)
            }
        }
    }
}
