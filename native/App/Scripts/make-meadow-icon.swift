// Draws the meadow file's document badge (`MeadowDocument` in the asset catalog; Info.plist's `UTTypeIcons`):
// the system lays it on its own page for a `.whiskrmeadow` in the Finder, with "meadow" under it. In the app
// icon's style (docs/logo.svg): flat shapes, no outlines, its off-white, and our cat peeking up with ring eyes;
// here from behind a round of meadow under a pale sky, a tree on the hill. Drawn in code, no art from elsewhere.
// Run from native/App with `make icon`. The output is checked in.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Whiskr/Assets.xcassets/MeadowDocument.imageset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

/// The badge on a 1024 canvas: a disc of sky and meadow, its edge a soft off-white ring.
func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()

    // A soft shadow under the disc, as the app icon's tile has.
    let disc = NSBezierPath(ovalIn: NSRect(x: 112, y: 112, width: 800, height: 800))
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    color(0xf5f4f0).setFill()
    disc.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Inside the ring: the sky, a far hill, the meadow's own hill, a tree, the cat.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: NSRect(x: 140, y: 140, width: 744, height: 744)).addClip()
    color(0xe4efe9).setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let far = NSBezierPath()
    far.move(to: NSPoint(x: 100, y: 520))
    far.curve(to: NSPoint(x: 560, y: 600), controlPoint1: NSPoint(x: 260, y: 640), controlPoint2: NSPoint(x: 420, y: 650))
    far.curve(to: NSPoint(x: 940, y: 540), controlPoint1: NSPoint(x: 700, y: 560), controlPoint2: NSPoint(x: 820, y: 600))
    far.line(to: NSPoint(x: 940, y: 0))
    far.line(to: NSPoint(x: 100, y: 0))
    far.close()
    color(0xb9d59a).setFill()
    far.fill()
    let hill = NSBezierPath()
    hill.move(to: NSPoint(x: 100, y: 430))
    hill.curve(to: NSPoint(x: 940, y: 470), controlPoint1: NSPoint(x: 380, y: 560), controlPoint2: NSPoint(x: 660, y: 540))
    hill.line(to: NSPoint(x: 940, y: 0))
    hill.line(to: NSPoint(x: 100, y: 0))
    hill.close()
    color(0x7fb04e).setFill()
    hill.fill()
    // The tree: a trunk and a round crown of three clay balls.
    color(0x6f523a).setFill()
    NSBezierPath(roundedRect: NSRect(x: 638, y: 470, width: 30, height: 120), xRadius: 14, yRadius: 14).fill()
    color(0x5f9a3c).setFill()
    for (x, y, r) in [(CGFloat(600), CGFloat(610), CGFloat(70)), (708, 616, 64), (652, 676, 74)] {
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
    }
    // Daisies in the grass, either side of the cat.
    for (x, y) in [(CGFloat(300), CGFloat(380)), (232, 300), (790, 330), (742, 250)] {
        color(0xffffff).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 16, y: y - 16, width: 32, height: 32)).fill()
        color(0xf2b632).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 7, y: y - 7, width: 14, height: 14)).fill()
    }
    // The cat, peeking up from the bottom: one shape with two small ears, and ring eyes (logo.svg's, smaller).
    let cat = NSBezierPath()
    let s: CGFloat = 0.62, ox: CGFloat = 512 - 499 * s, oy: CGFloat = -52
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + (1024 - y) * s) }
    cat.move(to: p(214, 1024))
    cat.line(to: p(246, 560))
    cat.curve(to: p(276, 462), controlPoint1: p(250, 500), controlPoint2: p(260, 480))
    cat.line(to: p(312, 352))
    cat.curve(to: p(356, 348), controlPoint1: p(330, 312), controlPoint2: p(340, 320))
    cat.line(to: p(414, 446))
    cat.curve(to: p(586, 446), controlPoint1: p(472, 436), controlPoint2: p(528, 436))
    cat.line(to: p(640, 344))
    cat.curve(to: p(684, 350), controlPoint1: p(660, 316), controlPoint2: p(672, 320))
    cat.line(to: p(722, 462))
    cat.curve(to: p(752, 560), controlPoint1: p(740, 480), controlPoint2: p(750, 500))
    cat.line(to: p(784, 1024))
    cat.close()
    color(0x141416).setFill()
    cat.fill()
    for x in [CGFloat(396), 602] {
        color(0xffffff).setFill()
        let outer = p(x - 64, 640 + 64)
        NSBezierPath(ovalIn: NSRect(x: outer.x, y: outer.y, width: 128 * s, height: 128 * s)).fill()
        color(0x141416).setFill()
        let inner = p(x - 36, 640 + 36)
        NSBezierPath(ovalIn: NSRect(x: inner.x, y: inner.y, width: 72 * s, height: 72 * s)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try draw(pixels: 512).write(to: output.appendingPathComponent("meadow-document.png"))
try draw(pixels: 1024).write(to: output.appendingPathComponent("meadow-document@2x.png"))
let contents = """
{
  "images" : [
    {
      "filename" : "meadow-document.png",
      "idiom" : "mac",
      "scale" : "1x"
    },
    {
      "filename" : "meadow-document@2x.png",
      "idiom" : "mac",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try Data(contents.utf8).write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(output.path)")
