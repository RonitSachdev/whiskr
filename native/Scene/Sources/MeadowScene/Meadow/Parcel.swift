import Foundation
import simd

// A thing from a newer Whiskr, while the meadow is edited (docs/DESIGN.md, "Edit Meadow"): a meadow file can
// hold things this Whiskr has no model for; they are kept whole and written back, and while editing each shows
// where it stands as a parcel, so it can be seen, moved and taken away. Real parcels were the reference: a
// box of brown kraft paper with softened corners, tied once each way with pale string and a small bow on top.
// Neutral on purpose: it says "something is here" and nothing about what.

extension MeadowScenery {
    /// The scenery id a thing from a newer Whiskr is drawn with while the meadow is edited. Never a catalog id
    /// (those are `^[a-z]+(\.[a-zA-Z0-9]+)+$`), so no meadow file can name it and no asset can take it.
    public static let parcel = "#parcel"
}

extension SceneryCatalog {
    /// How a parcel is drawn: a plant's way (rooted, making way under a blanket, ringed and picked as one), still
    /// in the wind, its ground a little wider than the box so the rules keep things off it.
    static let parcelKind = Kind.plant({ [Plant(shape: parcel, top: Vec3(0, 1.48, 0))] }, sway: 0, blooms: false, base: 1.25)

    /// The parcel: a box as tall as half a cat (2.2 units wide, 1.8 deep and 1.4 tall: large enough to find among
    /// the trees from the edit view, as the things it stands for often are), its string a finger's width, the
    /// bow's two loops and knot on its lid. Modelled at half that, then doubled.
    static let parcel: Geometry = {
        let half = Vec3(0.55, 0.7, 0.45), kraft: UInt32 = 0xa98a62, lid: UInt32 = 0xc4a77c, string: UInt32 = 0xeee4cc
        let box = Clay.stacked([Clay.Ring(w: half.x * 0.97, d: half.z * 0.97, y: 0), Clay.Ring(w: half.x, d: half.z, y: 0.04),
                                Clay.Ring(w: half.x, d: half.z, y: half.y - 0.04), Clay.Ring(w: half.x * 0.97, d: half.z * 0.97, y: half.y)],
                               square: 9) { ring, _ in ring >= 2 ? lid : kraft }
        // The string: up one side, over the lid and down the other, once along x and once along z, a hair proud
        // of the paper so it never sinks into it.
        func band(_ across: Vec3) -> [Geometry] {
            let out = across * 1.012, top = half.y + 0.012
            let corners = [Vec3(-out.x, 0.02, -out.z), Vec3(-out.x, top, -out.z), Vec3(out.x, top, out.z), Vec3(out.x, 0.02, out.z)]
            return zip(corners, corners.dropFirst()).map { a, b in
                Clay.limb(QuadraticBezier(a, (a + b) / 2, b), 0.03, 0.03, string, string, sides: 6, rings: 2).shape
            }
        }
        let loops = [Float(-1), 1].map { side in
            Clay.blob(at: Vec3(side * 0.11, half.y + 0.06, 0), size: Vec3(0.12, 0.05, 0.07), color: string, turn: Vec3(0, 0, side * 0.35))
        }
        let knot = Clay.blob(at: Vec3(0, half.y + 0.03, 0), size: 0.045, color: string)
        return Geometry.join([box] + band(Vec3(half.x, 0, 0)) + band(Vec3(0, 0, half.z)) + loops + [knot]).applied(.compose(.zero, euler: .zero, scale: Vec3(repeating: 2)))
    }()
}
