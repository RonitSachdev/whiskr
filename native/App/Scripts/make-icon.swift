// Renders the app icon asset set from the app icon source (docs/logo.svg): the tile is scaled onto
// Apple's macOS icon grid (an 824 pt tile centred in 1024) with a soft drop shadow.
// Run from native/App with `make icon`. The output is checked in.
import AppKit

let arguments = CommandLine.arguments
let svg = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "../../docs/logo.svg")
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Whiskr/Assets.xcassets/AppIcon.appiconset")

guard let logo = NSImage(contentsOf: svg) else {
    FileHandle.standardError.write(Data("Could not read \(svg.path)\n".utf8))
    exit(1)
}

// In the SVG the tile spans 64…960 of a 1024 canvas; on the icon grid it spans 100…924.
let tileScale = 824.0 / 896.0
let canvasInIcon = NSRect(x: 100 - 64 * tileScale, y: 100 - 64 * tileScale, width: 1024 * tileScale, height: 1024 * tileScale)

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

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    logo.draw(in: canvasInIcon, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

struct Entry: Encodable { let size: String; let idiom = "mac"; let filename: String; let scale: String }
var images: [Entry] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try draw(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(Entry(size: "\(points)x\(points)", filename: name, scale: "\(scale)x"))
    }
}
struct Contents: Encodable {
    struct Info: Encodable { let author = "xcode"; let version = 1 }
    let images: [Entry]
    let info = Info()
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(Contents(images: images)).write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon sizes to \(output.path)")
