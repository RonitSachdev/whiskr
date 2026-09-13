import Foundation
import Testing
import simd
@testable import MeadowScene

// The pure parts against values captured from the web version's own TypeScript
// (Fixtures/typescript-values.json, made by Fixtures/capture-typescript-values.ts.txt run with node in the
// project folder). If these hold, the same seed grows the same meadow, seats the same cats and bends the
// cat the same way.

struct Captured: @unchecked Sendable {
    let json: [String: Any]
    static let shared: Captured = {
        let url = Bundle.module.url(forResource: "typescript-values", withExtension: "json", subdirectory: "Fixtures")!
        return Captured(json: try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])
    }()
    subscript(_ path: String...) -> Any {
        var v: Any = json
        for key in path { v = (v as! [String: Any])[key]! }
        return v
    }
    func doubles(_ path: String...) -> [Double] { (self[path] as! [NSNumber]).map(\.doubleValue) }
    subscript(_ path: [String]) -> Any {
        var v: Any = json
        for key in path { v = (v as! [String: Any])[key]! }
        return v
    }
}

/// The native vertex at the same rest position as a web one. The weld keeps the same vertices and
/// triangles, but its order can differ (three.js hashes positions slightly differently), so tests match
/// vertices by where they are rather than by number.
private func vertex(at p: [Double]) -> Int {
    let target = Vec3(Float(p[0]), Float(p[1]), Float(p[2]))
    var best = 0, bestDistance = Float.infinity
    for (i, r) in Sculpt.shared.rest.enumerated() {
        let d = simd_distance(r, target)
        if d < bestDistance { best = i; bestDistance = d }
    }
    return best
}

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }
private func close(_ a: Vec3, _ b: [Double], _ tolerance: Float = 1e-4) -> Bool {
    abs(a.x - Float(b[0])) <= tolerance && abs(a.y - Float(b[1])) <= tolerance && abs(a.z - Float(b[2])) <= tolerance
}

@Suite struct RandomnessParity {
    @Test func seededStreamMatchesKit() {
        var r = Seeded(20_261_112)
        for expected in Captured.shared.doubles("seeded") { #expect(r.next() == expected) }
    }

    @Test func chanceMatchesScatter() {
        var r = chance("sim-shop-mwditcdj")
        for expected in Captured.shared.doubles("chanced") { #expect(r.next() == expected) }
    }

    @Test func noiseAndFbmMatch() {
        let fbmValues = Captured.shared.doubles("fbm")
        #expect(close(fbm(1.3, 2.7, 21), fbmValues[0], 1e-9))
        #expect(close(fbm(-5.1, 0.25, 3), fbmValues[1], 1e-9))
        let noiseValues = Captured.shared.doubles("noise")
        #expect(close(noise(3.3, -1.7, 0), noiseValues[0], 1e-9))
        #expect(close(noise(12.9, 4.4, 13), noiseValues[1], 1e-9))
    }

    @Test func settleChoosesTheSameSpot() {
        var r = chance("sim-shop-mwditcdj/main")
        let placed = [Spot(x: 0, z: 0, reach: 1.35), Spot(x: 3, z: 1, reach: 1)]
        let got = settle(&r, placed, 1, 0.65, 0, 0, 2, 4)
        let want = Captured.shared["settled"] as! [String: Any]
        #expect(abs(Double(got.x) - (want["x"] as! NSNumber).doubleValue) < 1e-4)
        #expect(abs(Double(got.z) - (want["z"] as! NSNumber).doubleValue) < 1e-4)
        #expect(got.clear == (want["clear"] as! Bool))
    }
}

@Suite struct CatParity {
    @Test func sculptHasTheSameSkin() {
        let s = Sculpt.shared
        let want = Captured.shared["sculpt"] as! [String: Any]
        #expect(s.count == (want["count"] as! Int))
        #expect(s.index.count / 3 == (want["triangles"] as! Int))
        let pick = (want["pick"] as! [Int])
        let rest = want["rest"] as! [[Double]]
        let weights = want["weights"] as! [[Double]]
        for k in pick.indices {
            let i = vertex(at: rest[k])
            #expect(close(s.rest[i], rest[k]))
            #expect(abs(Double(s.earPull[0][i]) - weights[k][0]) < 1e-4)
            #expect(abs(Double(s.earPull[1][i]) - weights[k][1]) < 1e-4)
            #expect(abs(Double(s.armPull[0][i]) - weights[k][2]) < 1e-4)
            #expect(abs(Double(s.armPull[1][i]) - weights[k][3]) < 1e-4)
            #expect(abs(Double(s.turn[i]) - weights[k][4]) < 1e-4)
        }
        // Eyes found by pressing into the face land in the same spot, facing the same way.
        let eyes = want["eyes"] as! [[Double]]
        for (k, eye) in s.eyes.enumerated() {
            #expect(close(eye.position, eyes[k]))
            let q = eye.facing.vector
            let w = simd_quatf(ix: Float(eyes[k][3]), iy: Float(eyes[k][4]), iz: Float(eyes[k][5]), r: Float(eyes[k][6])).vector
            #expect(simd_distance(q, w) < 1e-3 || simd_distance(q, -w) < 1e-3)
        }
    }

    @Test func poseBendsVerticesTheSameWay() {
        let want = Captured.shared["pose"] as! [String: Any]
        let inputs = want["inputs"] as! [String: Any]
        func f(_ k: String) -> Float { (inputs[k] as! NSNumber).floatValue }
        func v(_ k: String) -> Vec3 { let a = (inputs[k] as! [NSNumber]).map(\.floatValue); return Vec3(a[0], a[1], a[2]) }
        let p = PoseInputs(yaw: f("yaw"), pitch: f("pitch"), roll: f("roll"), earFlat: f("earFlat"), earPerk: f("earPerk"),
                           flickL: f("flickL"), flickR: f("flickR"), pushL: v("pushL"), pushR: v("pushR"))
        let rest = (Captured.shared["sculpt"] as! [String: Any])["rest"] as! [[Double]]
        let pick = (want["pick"] as! [Int]).indices.map { vertex(at: rest[$0]) }
        let posed = want["posed"] as! [[Double]]
        // The reference formula, and the fast one the renderer uses, both against the TypeScript.
        let poser = SkinPoser()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: SkinPoser.byteCount, alignment: 16)
        defer { buffer.deallocate() }
        poser.deform(p, into: buffer)
        let floats = buffer.assumingMemoryBound(to: Float.self)
        for (k, i) in pick.enumerated() {
            #expect(close(SkinPoser.posedVertex(i, p), posed[k]))
            #expect(close(Vec3(floats[i * 6], floats[i * 6 + 1], floats[i * 6 + 2]), posed[k]))
            // Normals come out unit length.
            #expect(abs(simd_length(Vec3(floats[i * 6 + 3], floats[i * 6 + 4], floats[i * 6 + 5])) - 1) < 1e-3)
        }
    }

    /// Each activity asks for the same pose as states.ts at the same moment; except the ones the Mac app's
    /// sidebar redrew so a state reads by its silhouette alone (docs/DESIGN.md): asking stands
    /// tall and still with one paw up, and idle (a loaf) does not exist in the web prototype.
    static let redrawnForTheSidebar: Set<AgentActivity> = [.asking, .idle]

    @Test(arguments: AgentActivity.allCases.filter { !redrawnForTheSidebar.contains($0) })
    func stateWantsTheSamePose(_ activity: AgentActivity) {
        let states = Captured.shared["states"] as! [String: [String: Any]]
        final class Stub: Performer {
            var wards: [Vec3] = []
            var presses = 0
            func pressButton(_ depth: Float) {}
            func thump() {}
            func jump(_ speed: Float, _ stretch: Float) {}
        }
        for t: Float in [0.3, 2.7] {
            let key = "\(activity.rawValue)@\(t == 0.3 ? "0.3" : "2.7")"
            guard let want = states[key] else { Issue.record("no capture for \(key)"); continue }
            var w = Want()
            States.act(activity, &w, t, Stub())
            func num(_ k: String) -> Float { (want[k] as! NSNumber).floatValue }
            for (name, value) in [("lid", w.lid), ("eye", w.eye), ("pupil", w.pupil), ("earFlat", w.earFlat), ("earPerk", w.earPerk),
                                  ("tailSpeed", w.tailSpeed), ("tailAmp", w.tailAmp), ("tailPuff", w.tailPuff), ("tall", w.tall),
                                  ("lie", w.lie), ("prone", w.prone), ("breath", w.breath), ("shiver", w.shiver), ("sway", w.sway)] {
                #expect(abs(value - num(name)) < 1e-5, "\(key) \(name)")
            }
            #expect(["rest", "up", "curl"][w.tail.rawValue] == (want["tail"] as! String), "\(key) tail")
            let prop = want["prop"] as? String
            #expect(w.prop.map { ["book", "desk", "machine", "spyglass", "papers", "cup", "snack"][$0.rawValue] } == prop, "\(key) prop")
            let bubble = want["bubble"] as? String
            #expect(w.bubble?.symbol == bubble, "\(key) bubble")
            switch w.aim {
            case .angles(let y, let p):
                let a = (want["aim"] as! [NSNumber]).map(\.floatValue)
                #expect(abs(y - a[0]) < 1e-5 && abs(p - a[1]) < 1e-5, "\(key) aim")
            case .camera: #expect(want["aim"] as? String == "camera", "\(key) aim")
            case .cursor: #expect(want["aim"] as? String == "cursor", "\(key) aim")
            case .at: #expect(want["aim"] as? String == "spot", "\(key) aim")
            }
            if let look = want["look"] as? [NSNumber] {
                #expect(w.look != nil && abs(w.look!.x - look[0].floatValue) < 1e-5 && abs(w.look!.y - look[1].floatValue) < 1e-5, "\(key) look")
            } else {
                #expect(w.look == nil, "\(key) look")
            }
            let hands = want["hands"] as! [Any]
            for n in 0..<2 {
                if let h = hands[n] as? [NSNumber] {
                    #expect(w.hands[n] != nil && close(w.hands[n]!, h.map(\.doubleValue)), "\(key) hand \(n)")
                } else {
                    #expect(w.hands[n] == nil, "\(key) hand \(n)")
                }
            }
        }
    }
}

@Suite struct ShapeParity {
    private func check(_ g: Geometry, _ want: [String: Any], vertexTolerance: Int = 0, boundsTolerance: Float = 2e-3) {
        let (lo, hi) = g.bounds
        let min = (want["min"] as! [NSNumber]).map(\.doubleValue), max = (want["max"] as! [NSNumber]).map(\.doubleValue)
        #expect(close(lo, min, boundsTolerance), "min \(lo) vs \(min)")
        #expect(close(hi, max, boundsTolerance), "max \(hi) vs \(max)")
        #expect(abs(g.count - (want["vertices"] as! Int)) <= vertexTolerance, "vertices \(g.count) vs \(want["vertices"]!)")
    }

    @Test func flowersAreModelledTheSame() {
        let flora = Captured.shared["flora"] as! [String: Any]
        check(Flora.daisies[0].shape, flora["daisy0"] as! [String: Any])
        check(Flora.lupins[1].shape, flora["lupin1"] as! [String: Any])
        check(Flora.mushrooms[0].shape, flora["mushroom0"] as! [String: Any], vertexTolerance: 2000)
        check(Flora.stones[1].shape, flora["stone1"] as! [String: Any], vertexTolerance: 2000, boundsTolerance: 0.02)
        #expect(close(Flora.daisies[0].top, (flora["daisyTop"] as! [NSNumber]).map(\.doubleValue)))
    }

    /// A tree grown from the same seed has the same shape and uses up exactly as much of the random stream.
    @Test func treesGrowTheSame() {
        let trees = Captured.shared["trees"] as! [String: Any]
        var r = Seeded(5)
        let oak = Trees.grow(.oak, &r)
        let want = trees["oak"] as! [String: Any]
        check(oak.shape, want, vertexTolerance: 2000, boundsTolerance: 0.05)
        #expect(abs(Double(oak.crown) - (want["crown"] as! NSNumber).doubleValue) < 1e-3)
        #expect(abs(Double(oak.bulk) - (want["bulk"] as! NSNumber).doubleValue) < 1e-3)
        #expect(close(oak.middle, (want["middle"] as! [NSNumber]).map(\.doubleValue), 1e-3))
        #expect(r.next() == (trees["afterOak"] as! NSNumber).doubleValue)
    }
}
