import Foundation

/// The words a meadow carries (its name, author and description), made safe to show: they come from
/// anyone, and are shown only as plain text.
public enum MeadowText {
    /// The texts a meadow has, each with its longest length in characters (grapheme clusters, after
    /// NFC). A text may also hold at most eight Unicode scalars per character allowed, so one
    /// "character" piled with thousands of combining marks is refused too.
    public enum Field: String, Sendable, CaseIterable {
        case name, author, description

        public var limit: Int {
            switch self {
            case .name: 60
            case .author: 40
            case .description: 280
            }
        }
    }

    /// `text` in NFC with what could deceive or hide removed: control characters (tabs, line breaks and
    /// the line and paragraph separators become spaces), bidirectional overrides, embeddings, isolates
    /// and marks, invisible zero-width characters, tag characters, and private-use characters. A
    /// zero-width joiner or non-joiner is kept only alone and between two visible characters (as in an
    /// emoji sequence or a Persian word), never in a run. Then runs of white space become one space and
    /// the ends are trimmed. Doing it twice changes nothing.
    public static func sanitised(_ text: String) -> String {
        var kept: [Unicode.Scalar] = []
        kept.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if isSpaceLike(scalar) {
                kept.append(" ")
            } else if !isRemoved(scalar) {
                kept.append(scalar)
            }
        }
        // Joiners: only alone, and only between two characters that are neither space nor joiner.
        var joined: [Unicode.Scalar] = []
        joined.reserveCapacity(kept.count)
        for (i, scalar) in kept.enumerated() {
            if isJoiner(scalar) {
                let before = i > 0 ? kept[i - 1] : nil, after = i + 1 < kept.count ? kept[i + 1] : nil
                guard let before, let after, !isJoiner(before), !isJoiner(after),
                      !before.properties.isWhitespace, !after.properties.isWhitespace else { continue }
            }
            joined.append(scalar)
        }
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in joined {
            let space = scalar.properties.isWhitespace
            if space {
                if !lastWasSpace { out.append(" ") }
            } else {
                out.append(scalar)
            }
            lastWasSpace = space
        }
        var result = String(out)
        while result.last == " " { result.removeLast() }
        // Removing characters can bring a base and a combining mark together; settle into NFC again.
        return result.precomposedStringWithCanonicalMapping
    }

    /// Whether a sanitised `text` fits `field`.
    public static func fits(_ text: String, _ field: Field) -> Bool {
        text.count <= field.limit && text.unicodeScalars.count <= field.limit * 8
    }

    /// Whether `text` as it arrived is short enough to be worth sanitising: at most 32 Unicode scalars
    /// per character allowed. Longer is refused unread, however much of it sanitising would remove.
    public static func mayFit(_ text: String, _ field: Field) -> Bool {
        text.utf8.count <= field.limit * 32 * 4 && text.unicodeScalars.count <= field.limit * 32
    }

    private static func isSpaceLike(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200C || scalar.value == 0x200D
    }

    private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true                 // control characters
        case 0x061C, 0x200E, 0x200F: true                   // directional marks
        case 0x202A...0x202E, 0x2066...0x2069: true         // embeddings, overrides, isolates
        case 0x200B, 0x2060...0x2064, 0xFEFF: true          // zero-width space, word joiner, invisible operators, BOM
        case 0x180E, 0x034F, 0x115F, 0x1160, 0x3164, 0xFFA0: true // invisible fillers
        case 0xFFF9...0xFFFB: true                          // interlinear annotation
        case 0xE0000...0xE007F: true                        // tags
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD: true // private use
        default: false
        }
    }
}
