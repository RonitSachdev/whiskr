import Foundation
import simd

// Meadow.ts `light()`: sky, haze and lights for an hour of the day, with the weather laid over them.
// Night is properly dark: a deep blue sky and a meadow in soft, moonlit shadow; the picnics carry their
// own warm light (`picnicLight` in the shaders).

struct Light {
    var skyTop = linear(0x6aaef0), skyMid = linear(0xa9d6f7), horizon = linear(0xfbefd8)
    var hemiSky = linear(0xd4e8ff) * 1.2, hemiGround = linear(0xffdccf) * 1.2
    var keyColor = linear(0xfff0d2) * 2.2
    var rimColor = Vec3(repeating: 1.8)
    var keyDir = simd_normalize(Vec3(-3, 6, 5)), rimDir = simd_normalize(Vec3(4, 3, -6))
    /// How far the fireflies and lamplight are out, 0 by day to 1 at night.
    var night: Float = 0
    /// Stars and moon showing, 0…1 (night less cloud).
    var stars: Float = 0
    var cloudGlow: Float = 0.5
    var turfLow = linear(0x82b545), turfHigh = linear(0xb6d15a)
    var wind: Float = 1
    /// The colour drops of rain or snow are drawn in (unlit), linear.
    var dropColor = linear(0xd6e6f5)

    /// stage.ts lights with a plain paper background: the web playground.
    static var playground: Light {
        var l = Light()
        l.hemiSky = Vec3(repeating: 1.2)
        l.hemiGround = linear(0xcfc8bd) * 1.2
        l.keyColor = Vec3(repeating: 2.2)
        l.horizon = linear(0xfaf9f6)
        l.skyTop = l.horizon; l.skyMid = l.horizon
        return l
    }
}

private struct Mood {
    var top: Vec3, mid: Vec3, horizon: Vec3, sun: Vec3, sunPower: Float, above: Vec3, below: Vec3, fill: Float, night: Float
    init(_ top: UInt32, _ mid: UInt32, _ horizon: UInt32, _ sun: UInt32, _ sunPower: Float, _ above: UInt32, _ below: UInt32, _ fill: Float, _ night: Float) {
        self.top = linear(top); self.mid = linear(mid); self.horizon = linear(horizon); self.sun = linear(sun); self.sunPower = sunPower
        self.above = linear(above); self.below = linear(below); self.fill = fill; self.night = night
    }
}

enum Daylight {
    private static let NIGHT = Mood(0x050a1d, 0x0c1634, 0x1b2a50, 0x7c94e0, 0.32, 0x3a5596, 0x0e1428, 0.48, 1)
    private static let TWILIGHT = Mood(0x101a44, 0x26346c, 0x5a5584, 0xa4b2ee, 0.9, 0x6a78b0, 0x2a2c48, 0.75, 0.75)
    private static let DAWN = Mood(0x7fa8e8, 0xf2c8c4, 0xffe2c2, 0xffd9b0, 1.8, 0xffe4de, 0xffd0c0, 1.12, 0)
    private static let DAY = Mood(0x6aaef0, 0xa9d6f7, 0xfbefd8, 0xfff0d2, 2.2, 0xd4e8ff, 0xffdccf, 1.2, 0)
    private static let DUSK = Mood(0x4a5aa8, 0xe69a84, 0xffc596, 0xffac70, 1.7, 0xf0c4b4, 0xd0a092, 1.0, 0.3)
    private static let HOURS: [(Double, Mood)] = [
        (0, NIGHT), (4.8, NIGHT), (5.8, TWILIGHT), (6.75, DAWN), (9, DAY), (16.5, DAY), (19, DUSK), (20, TWILIGHT), (21.2, NIGHT), (24, NIGHT),
    ]
    // The moon's cool light on the cats' backs at night, against the picnic's warm light on their fronts.
    private static let MOONLIT_RIM = linear(0x9fb6ff)
    // Under cloud the sky drains toward this grey, and the grass pales in the cold or yellows in the heat.
    private static let OVERCAST = linear(0xaab4bf)
    private static let TURF = (low: linear(0x82b545), high: linear(0xb6d15a), frosty: linear(0xa8c7a6), parched: linear(0xbcc052))

    static func light(hour h: Double, weather: MeadowWeather?) -> Light {
        let hour = min(max(h, 0), 23.999)
        let next = HOURS.firstIndex { $0.0 > hour } ?? HOURS.count - 1
        let (from, a) = HOURS[next - 1], (to, b) = HOURS[next]
        let t = Float(smooth((hour - from) / (to - from)))
        var l = Light()
        l.skyTop = mix(a.top, b.top, t: t)
        l.skyMid = mix(a.mid, b.mid, t: t)
        l.horizon = mix(a.horizon, b.horizon, t: t)
        l.night = lerp(a.night, b.night, t)
        // Weather on top of the hour: cloud, rain, snow and fog grey the sky and take the edge off the sun.
        let cover: Float = weather.map { $0.sky == .clear ? $0.cover * 0.6 : max($0.cover, 0.8) } ?? 0
        // A clouded night is a dull slate rather than black, but no brighter than a clear one.
        let grey = OVERCAST * (1 - 0.85 * l.night)
        l.skyTop = mix(l.skyTop, grey, t: cover * 0.75)
        l.skyMid = mix(l.skyMid, grey, t: cover * 0.75)
        l.horizon = mix(l.horizon, grey, t: cover * 0.75)
        l.keyColor = mix(a.sun, b.sun, t: t) * lerp(a.sunPower, b.sunPower, t) * (1 - 0.5 * cover)
        let fill = lerp(a.fill, b.fill, t) * (1 - 0.1 * cover)
        l.hemiSky = mix(a.above, b.above, t: t) * fill
        l.hemiGround = mix(a.below, b.below, t: t) * fill
        // By day the rim light keeps a black cat readable against the field. At night it becomes the moon
        // behind them, cool and soft; the picnic's warm light does the rest.
        l.rimColor = mix(Vec3(1, 1, 1), MOONLIT_RIM, t: l.night) * (1.8 - 1.1 * l.night)
        l.cloudGlow = 0.5 - 0.46 * l.night
        l.dropColor = (weather?.sky == .snow ? Vec3(1, 1, 1) : linear(0xd6e6f5)) * (1 - 0.6 * l.night)
        l.stars = l.night * (1 - cover)
        if let w = weather {
            l.wind = min(max(0.6 + w.windKmh / 20, 0.6), 2.6)
            // Near freezing the grass goes pale; in real heat it yellows.
            let cold = smooth((6 - w.temperatureC) / 8), hot = smooth((w.temperatureC - 27) / 8)
            l.turfLow = mix(mix(TURF.low, TURF.frosty, t: cold * 0.6), TURF.parched, t: hot * 0.5)
            l.turfHigh = mix(mix(TURF.high, TURF.frosty, t: cold * 0.7), TURF.parched, t: hot * 0.6)
        }
        return l
    }

    static func hour(for setting: MeadowSettings.TimeOfDay, now: Date = Date()) -> Double {
        switch setting {
        case .day: return 12
        case .night: return 23
        case .hour(let h): return h
        case .followClock:
            let c = Calendar.current.dateComponents([.hour, .minute], from: now)
            return Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        }
    }
}

@inline(__always) func mix(_ a: Vec3, _ b: Vec3, t: Float) -> Vec3 { a + (b - a) * t }
