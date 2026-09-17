import Foundation
import simd

// The made things' colours (docs/DESIGN.md, rule 9): each named swatch is one clay colour wherever it is worn, a
// sage bench beside a sage shed and a sage cushion, so the things a person chooses go together and go with the
// blankets. The bright ones are the blankets' own gingham colours (`MeadowColor.accounts`) taken toward the cloth's
// cream as the gingham's bands are, then dulled a little into clay; the quiet ones are the meadow's woods, stones,
// glazes and cloths. None is a state's colour (the vermillion of a working cat, the finished blue, the alert red).

enum Palette {
    /// A swatch as clay: its shaded colour and its lit one (a thing is painted from the first at its foot to the
    /// second at its top, as all the meadow's clay is).
    struct Clay { var shade: UInt32; var light: UInt32 }

    static let swatches: [String: Clay] = [
        // From the gingham: rose, the gold (mustard), violet (lavender), teal (sage, forest), blue (duck egg),
        // orange (ochre, terracotta).
        "rose": Clay(shade: 0xd98c8e, light: 0xf2b9b6),
        "mustard": Clay(shade: 0xc99a3c, light: 0xe8c066),
        "lavender": Clay(shade: 0xa596cc, light: 0xcbbfe6),
        "sage": Clay(shade: 0x8ba487, light: 0xb7cbae),
        "forest": Clay(shade: 0x3f6a52, light: 0x5f8c6c),
        "duckEgg": Clay(shade: 0x8fbcbc, light: 0xbfdcd8),
        "ochre": Clay(shade: 0xb98a43, light: 0xd9ac64),
        "terracotta": Clay(shade: 0xb4643f, light: 0xd68a5e),
        // Cloths, woods, metals and stones.
        "oat": Clay(shade: 0xbfa881, light: 0xefe4cc),
        "cream": Clay(shade: 0xe3d8c4, light: 0xf7f1e4),
        "canvas": Clay(shade: 0xcdbb94, light: 0xebe0c4),
        "dove": Clay(shade: 0xaeaba5, light: 0xd9d6cf),
        "olive": Clay(shade: 0x777d4a, light: 0xa0a46a),
        "wood": Clay(shade: 0xa0703f, light: 0xc99a62),
        "slate": Clay(shade: 0x66737d, light: 0x96a3ab),
        "charcoal": Clay(shade: 0x45454b, light: 0x6b6b72),
        "zinc": Clay(shade: 0x8f979a, light: 0xcbd1d1),
        // Glazes on stoneware: moss, celadon (the pale grey-green of old Chinese and Korean ware), bottle green.
        "glazeMoss": Clay(shade: 0x667f43, light: 0x95ad66),
        "glazeCeladon": Clay(shade: 0x93b39f, light: 0xc3dac8),
        "glazeBottle": Clay(shade: 0x2c5543, light: 0x4c785e),
    ]

    /// A swatch by name; a name with no colour here (none should have) is oat.
    static func swatch(_ name: String) -> (clay: Clay, color: MeadowColor) {
        let clay = swatches[name] ?? swatches["oat"]!
        return (clay, MeadowColor(hex: clay.light))
    }

    /// The `index`th swatch of `id`'s palette, as clay (the first for an index it does not have).
    static func clay(_ id: String, _ index: Int) -> Clay {
        let names = SceneryCatalog.palettes[id] ?? []
        guard let name = names.indices.contains(index) ? names[index] : names.first else { return swatches["oat"]! }
        return swatch(name).clay
    }
}
