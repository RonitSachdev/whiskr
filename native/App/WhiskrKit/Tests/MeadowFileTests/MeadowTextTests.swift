import Foundation
import Testing
@testable import MeadowFile

// A meadow's name, author and description come from anyone: what could deceive or hide is removed.

@Suite("Meadow files: text")
struct MeadowTextTests {
    @Test("direction overrides, isolates and marks are removed, so a name cannot pretend to be another")
    func bidirectional() {
        #expect(MeadowText.sanitised("Orchard\u{202E}ydutS") == "OrchardydutS")
        #expect(MeadowText.sanitised("a\u{2066}b\u{2067}c\u{2068}d\u{2069}e\u{202A}f\u{202B}g\u{202C}h\u{202D}i\u{200E}j\u{200F}k\u{61C}l") == "abcdefghijkl")
    }

    @Test("control characters go; tabs and line breaks become spaces; runs of space become one; the ends are trimmed")
    func controlsAndSpace() {
        #expect(MeadowText.sanitised("  Garden\tOffice\n\nby\u{2028}the\u{0}way\u{7}\u{85}  ") == "Garden Office by theway")
        #expect(MeadowText.sanitised("a\u{A0}\u{3000} b") == "a b")
        #expect(MeadowText.sanitised(" \n\t ") == "")
    }

    @Test("invisible characters, tags and private-use characters go")
    func invisible() {
        #expect(MeadowText.sanitised("ca\u{200B}t\u{FEFF}\u{2060}s") == "cats")
        #expect(MeadowText.sanitised("hi\u{E0041}\u{E0042}") == "hi")
        #expect(MeadowText.sanitised("a\u{E000}b\u{F8FF}c\u{F0000}d\u{10FFFD}") == "abcd")
        #expect(MeadowText.sanitised("\u{3164}\u{115F}x") == "x")
    }

    @Test("a joiner stays alone between two characters, as in an emoji; runs of joiners and loose ones go")
    func joiners() {
        let family = "👩\u{200D}👩\u{200D}👧"
        #expect(MeadowText.sanitised(family) == family)
        #expect(MeadowText.sanitised("👩\u{200D}\u{200D}\u{200D}👧") == "👩👧")
        #expect(MeadowText.sanitised("\u{200D}a\u{200C}") == "a")
        #expect(MeadowText.sanitised("a \u{200D}b") == "a b")
        #expect(MeadowText.sanitised("می\u{200C}خواهم") == "می\u{200C}خواهم")
    }

    @Test("text is kept in NFC, also where removing a character brings a mark to its letter")
    func normalised() {
        #expect(MeadowText.sanitised("Cafe\u{301}").unicodeScalars.elementsEqual("Caf\u{E9}".unicodeScalars))
        #expect(MeadowText.sanitised("e\u{202E}\u{301}").unicodeScalars.elementsEqual("\u{E9}".unicodeScalars))
    }

    @Test("sanitising twice changes nothing")
    func idempotent() {
        let pieces = ["a", " ", "\u{200D}", "\u{202E}", "é", "e\u{301}", "\n", "👩", "\u{E000}", "ねこ", "\u{0}", "\u{2066}", "\u{A0}", "\u{200C}"]
        var random = SplitMix(11)
        for _ in 0..<2_000 {
            let text = (0..<Int.random(in: 0...12, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
            let once = MeadowText.sanitised(text)
            #expect(MeadowText.sanitised(once) == once && MeadowText.sanitised(once).unicodeScalars.elementsEqual(once.unicodeScalars), "\(Array(text.unicodeScalars))")
        }
    }

    @Test("limits count characters, and a character piled with marks counts by its scalars too")
    func limits() {
        #expect(MeadowText.fits(String(repeating: "猫", count: 60), .name))
        #expect(!MeadowText.fits(String(repeating: "猫", count: 61), .name))
        #expect(MeadowText.fits(String(repeating: "👩\u{200D}👩\u{200D}👧", count: 40), .author))
        #expect(!MeadowText.fits("a" + String(repeating: "\u{301}", count: 480), .name))
        #expect(MeadowText.fits(String(repeating: "x", count: 280), .description))
        #expect(!MeadowText.fits(String(repeating: "x", count: 281), .description))
    }
}
