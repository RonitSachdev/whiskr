import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The painted ground and the stones walked on, as the ground's map holds them for the shaders: path, lawn and
// soil softened round their cells, the wear round each stepping stone, only the touched texels painted again
// for a stroke, and a cat's liking for where it walks.

/// A ground with `paint` in a disc of `radius` round (x, z).
private func ground(_ paint: MeadowScenery.Ground.Paint, at x: Float, _ z: Float, radius: Float, onto base: MeadowScenery.Ground = .init()) -> MeadowScenery.Ground {
    var ground = base
    let cell = MeadowScenery.Ground.cell
    for row in 0..<MeadowScenery.Ground.side {
        for column in 0..<MeadowScenery.Ground.side {
            let p = Vec2(-150 + (Float(column) + 0.5) * cell, -150 + (Float(row) + 0.5) * cell)
            if hypot(p.x - x, p.y - z) <= radius { ground[column, row] = paint }
        }
    }
    return ground
}

@Suite struct PaintedGroundMap {
    @Test("each paint has its channel: full inside, none well outside, about half at its edge, never another's")
    func channels() {
        var g = ground(.path, at: -20, 0, radius: 4)
        g = ground(.lawn, at: 20, 0, radius: 4, onto: g)
        g = ground(.soil, at: 0, 30, radius: 4, onto: g)
        let map = GroundMap.baked(shade: [], ground: g)
        for (paint, centre, channel) in [(MeadowScenery.Ground.Paint.path, Vec2(-20, 0), 0), (.lawn, Vec2(20, 0), 1), (.soil, Vec2(0, 30), 2)] {
            #expect(map.sample(centre, channel: channel) > 0.99, "\(paint) inside")
            #expect(map.sample(centre + Vec2(7, 0), channel: channel) < 0.01, "\(paint) outside")
            let edge = map.sample(centre + Vec2(4, 0), channel: channel)
            #expect(edge > 0.2 && edge < 0.8, "\(paint) soft at its edge: \(edge)")
            for other in 0..<3 where other != channel { #expect(map.sample(centre, channel: other) == 0) }
        }
        #expect(map.shade(at: Vec2(-20, 0)) == 0, "paint leaves the shade alone")
    }

    @Test("softened, an edge runs round in a curve: the half-way line of a painted disc keeps close to its circle all round")
    func roundEdges() {
        let map = GroundMap.baked(shade: [], ground: ground(.path, at: 0, 0, radius: 5))
        for k in 0..<64 {
            let a = Float(k) / 64 * 2 * .pi, way = Vec2(cos(a), sin(a))
            // Where the weight falls through ½ along this way.
            var r: Float = 3
            while map.sample(way * r, channel: 0) > 0.5, r < 8 { r += 0.02 }
            #expect(abs(r - 5) < 0.45, "at \(a): \(r)")
        }
    }

    @Test("a stepping stone wears the ground bare under it (no grass through it) and the turf round it trodden short, untouched beyond")
    func treads() {
        let stone = GroundMap.Tread(x: 10, z: 10, turn: 0.4, half: Vec2(0.64, 0.48))
        let map = GroundMap.baked(shade: [], treads: [stone])
        #expect(map.sample(Vec2(10, 10), channel: 0) > 0.66, "\(map.sample(Vec2(10, 10), channel: 0))")
        let edge = Vec2(10, 10) + Vec2(cos(-0.4), sin(-0.4)) * 1.0
        #expect(map.sample(edge, channel: 1) > 0.3 && map.sample(edge, channel: 1) <= GroundMap.Tread.trodden + 0.01, "trodden short round its edge")
        #expect(map.sample(Vec2(13, 10), channel: 0) == 0 && map.sample(Vec2(13, 10), channel: 1) == 0)
        #expect(stone.holds(Vec2(10, 10)) && !stone.holds(Vec2(11, 10)))
    }

    @Test("painting a region again is the same as baking afresh, and touches only the region and the softening's reach")
    func regions() throws {
        let before = ground(.lawn, at: 0, 0, radius: 6)
        let after = ground(.path, at: 3, 0, radius: 2, onto: before)
        let changed = try #require(GroundMap.difference(before, after))
        var map = GroundMap.baked(shade: [Vec4(0, 0, 10, 0)], ground: before)
        let old = map.surface
        let touched = map.paint(after, treads: [], in: changed)
        #expect(map.surface == GroundMap.baked(shade: [Vec4(0, 0, 10, 0)], ground: after).surface)
        #expect(touched.columns.count == changed.columns.count + GroundMap.soften.count - 1 && touched.rows.count == changed.rows.count + GroundMap.soften.count - 1)
        for row in 0..<GroundMap.side where !touched.rows.contains(row) {
            let from = row * GroundMap.side * 4
            #expect(map.surface[from..<(from + GroundMap.side * 4)] == old[from..<(from + GroundMap.side * 4)])
        }
        #expect(GroundMap.difference(after, after) == nil && GroundMap.difference(nil, nil) == nil)
        #expect(GroundMap.difference(nil, before) == GroundMap.difference(before, MeadowScenery.Ground()))
    }
}

@Suite(.serialized) struct PaintingTheMeadow {
    @MainActor
    func meadow(_ scenery: MeadowScenery) -> Meadow { Meadow(scenery: scenery) }

    @Test("a stroke of paint changes only the ground: nothing is laid again, and the map is drawn again only round the stroke")
    @MainActor func stroke() throws {
        let things = [MeadowScenery.Thing(id: "tree.oak", x: 30, z: 30, seed: 4), MeadowScenery.Thing(id: "flower.daisy", x: 2, z: 2)]
        let m = meadow(MeadowScenery(things: things))
        let laid = m.sceneryVersion, baked = m.groundVersion
        _ = m.takeGroundChanges()
        m.show(MeadowScenery(things: things, ground: ground(.path, at: -10, 5, radius: 2)))
        #expect(m.sceneryVersion == laid && m.groundVersion == baked)
        let region = try #require(m.takeGroundChanges())
        #expect(region.columns.count < 16 && region.rows.count < 16, "\(region)")
        #expect(m.groundMap.sample(Vec2(-10, 5), channel: 0) > 0.95)
        #expect(m.takeGroundChanges() == nil)
        // Painted away again.
        m.show(MeadowScenery(things: things))
        #expect(m.groundMap.sample(Vec2(-10, 5), channel: 0) == 0 && m.takeGroundChanges() != nil)
    }

    @Test("stepping stones laid, moved or taken up wear the turf where they lie, and only there")
    @MainActor func steppingStones() throws {
        let stone = MeadowScenery.Thing(id: "stone.stepping", x: 6, z: 6)
        let m = meadow(MeadowScenery(things: [MeadowScenery.Thing(id: "flower.daisy", x: -30, z: -30)]))
        _ = m.takeGroundChanges()
        m.show(MeadowScenery(things: [MeadowScenery.Thing(id: "flower.daisy", x: -30, z: -30), stone]))
        #expect(m.groundMap.sample(Vec2(6, 6), channel: 0) > 0.66 && m.takeGroundChanges() != nil)
        var moved = stone
        moved.x = 9
        m.show(MeadowScenery(things: [MeadowScenery.Thing(id: "flower.daisy", x: -30, z: -30), moved]))
        #expect(m.groundMap.sample(Vec2(6, 6), channel: 0) == 0 && m.groundMap.sample(Vec2(9, 6), channel: 0) > 0.66)
        m.show(MeadowScenery(things: [MeadowScenery.Thing(id: "flower.daisy", x: -30, z: -30)]))
        #expect(m.groundMap.sample(Vec2(9, 6), channel: 0) == 0)
    }

    @Test("a cat likes walking most on a path or a stepping stone, less on lawn, least in wild grass or on soil")
    @MainActor func walkingEase() {
        var g = ground(.path, at: 0, 20, radius: 3)
        g = ground(.lawn, at: 20, 20, radius: 3, onto: g)
        g = ground(.soil, at: -20, 20, radius: 3, onto: g)
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), mode: .meadow)
        view.scenery = MeadowScenery(things: [MeadowScenery.Thing(id: "stone.stepping", x: 10, z: -10, turn: 1)], ground: g)
        view.advance(seconds: 0.1)
        let path = view.walkingEase(at: SIMD2(0, 20)), stone = view.walkingEase(at: SIMD2(10, -10)), lawn = view.walkingEase(at: SIMD2(20, 20))
        let wild = view.walkingEase(at: SIMD2(40, 40)), soil = view.walkingEase(at: SIMD2(-20, 20)), beside = view.walkingEase(at: SIMD2(11.5, -10))
        #expect(path == 1 && stone == 1 && lawn < 1 && lawn > wild && wild == soil && beside == wild, "\(path) \(stone) \(lawn) \(wild) \(soil) \(beside)")
        #expect(view.walkingEase(at: SIMD2(400, 0)) == wild, "off the map: the wild grass")
    }

    @Test("the shaders read the painted ground and give way to blankets; the meadow is drawn with paint by day and night")
    @MainActor func shaders() {
        #expect(ShaderSource.common.contains("Painted paintedAt(float2 g, float4 m, float blankets)"))
        #expect(ShaderSource.meadow.contains("paintedAt(g, map, blankets)") && ShaderSource.meadow.contains("paintedAt(root.xz, map, blankets)"))
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .day)
        view.advance(seconds: 0.3)
        let plain = view.renderImage(width: 320, height: 200)
        view.scenery = MeadowScenery(things: [], ground: ground(.soil, at: 0, 0, radius: 30))
        view.advance(seconds: 0.3)
        let soil = view.renderImage(width: 320, height: 200)
        #expect(plain != nil && soil != nil && plain!.dataProvider!.data != soil!.dataProvider!.data, "the soil is drawn")
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .night)
        view.advance(seconds: 0.3)
        #expect(view.renderImage(width: 320, height: 200) != nil)
    }

    @Test("every ground paint has a picture of its turf for the tray, distinct from the others")
    @MainActor func pictures() throws {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), mode: .meadow)
        let pictures = try MeadowScenery.Ground.Paint.allCases.map { try #require(view.portrait(of: [$0.id], pixels: 96, background: MeadowColor(hex: 0xf4f1ea))) }
        let bytes = pictures.map { $0.dataProvider!.data! as Data }
        #expect(Set(bytes).count == pictures.count)
    }
}
