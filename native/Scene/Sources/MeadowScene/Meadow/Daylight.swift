import Foundation
import simd

// Meadow.ts `light()`: sky, haze and lights for the time of day, with the weather laid over them.
// Night is properly dark: a deep blue sky and a meadow in soft, moonlit shadow; the picnics carry their
// own warm light (`picnicLight` in the shaders).

struct Light: Equatable {
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
    /// How hard the wind blows at the height of a gust, as a multiple of a breeze.
    var wind: Float = 1
    /// Which way the wind blows, toward, on the ground (x east, z south): unit length.
    var windToward = Light.breeze
    /// How much of a gust's push stays between gusts, 0…1: low in a gusty wind, high in a steady one.
    var windCalm: Float = 0.12
    /// Rain or snow falling, 0 for none, up to 1 for heavy.
    var falling: Float = 0
    var snowing = false
    /// The colour drops of rain or snow are drawn in (unlit), linear.
    var dropColor = linear(0xd6e6f5)
    /// Fog and haze closing in, 0 (a clear day) … 1 (fog).
    var mist: Float = 0
    /// A thunderstorm overhead: sheet lightning now and then (`Lightning`).
    var thunder = false
    var moon = Moon.Phase.full
    /// How far the moon is above the horizon to be seen, 0 (set) … 1 (up).
    var moonUp: Float = 1
    /// The moon showing, 0…1: risen, after dark, and not behind cloud.
    var moonShown: Float = 0
    /// Which way its lit edge faces on the sky (up, right as you look at it), unit length; nil for the
    /// meadow's own moon, lit from the right.
    var moonLimb: Vec2?
    /// The sun's height above the horizon, degrees, when the light follows the real sun.
    var sunElevation: Double?
    /// Garden lamps are lit (`MeadowLamps`): it is dark enough for their light sensors, and lamps light at night.
    var lampsLit = false

    /// The meadow's own breeze, when no real wind is shown.
    static let breeze = simd_normalize(Vec2(1, 0.35))

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
    /// Part way from this mood to another.
    func toward(_ o: Mood, _ t: Float) -> Mood {
        var m = self
        m.top = mix(top, o.top, t: t); m.mid = mix(mid, o.mid, t: t); m.horizon = mix(horizon, o.horizon, t: t)
        m.sun = mix(sun, o.sun, t: t); m.sunPower = lerp(sunPower, o.sunPower, t)
        m.above = mix(above, o.above, t: t); m.below = mix(below, o.below, t: t)
        m.fill = lerp(fill, o.fill, t); m.night = lerp(night, o.night, t)
        return m
    }
}

enum Daylight {
    private static let NIGHT = Mood(0x050a1d, 0x0c1634, 0x1b2a50, 0x7c94e0, 0.32, 0x3a5596, 0x0e1428, 0.48, 1)
    private static let TWILIGHT = Mood(0x101a44, 0x26346c, 0x5a5584, 0xa4b2ee, 0.9, 0x6a78b0, 0x2a2c48, 0.75, 0.75)
    private static let DAWN = Mood(0x7fa8e8, 0xf2c8c4, 0xffe2c2, 0xffd9b0, 1.8, 0xffe4de, 0xffd0c0, 1.12, 0)
    private static let DAY = Mood(0x6aaef0, 0xa9d6f7, 0xfbefd8, 0xfff0d2, 2.2, 0xd4e8ff, 0xffdccf, 1.2, 0)
    private static let DUSK = Mood(0x4a5aa8, 0xe69a84, 0xffc596, 0xffac70, 1.7, 0xf0c4b4, 0xd0a092, 1.0, 0.3)
    /// The moods at fixed hours of the clock, when the real sun is not followed.
    private static let HOURS: [(Double, Mood)] = [
        (0, NIGHT), (4.8, NIGHT), (5.8, TWILIGHT), (6.75, DAWN), (9, DAY), (16.5, DAY), (19, DUSK), (20, TWILIGHT), (21.2, NIGHT), (24, NIGHT),
    ]
    /// The same moods by the real sun's height (degrees): night once it is 12° down (nautical dusk), the
    /// blue of twilight at civil dusk, dawn's pink or dusk's gold as it crosses the horizon, full day from
    /// 12° up. Morning and evening differ only in that pink and gold.
    private static let RISING: [(Double, Mood)] = [(-12, NIGHT), (-5, TWILIGHT), (3, DAWN), (12, DAY)]
    private static let SETTING: [(Double, Mood)] = [(-12, NIGHT), (-5, TWILIGHT), (2, DUSK), (12, DAY)]
    // The moon's cool light on the cats' backs at night, against the picnic's warm light on their fronts.
    private static let MOONLIT_RIM = linear(0x9fb6ff)
    // Under cloud the sky drains toward this grey, and the grass pales in the cold or yellows in the heat.
    private static let OVERCAST = linear(0xaab4bf)
    private static let TURF = (low: linear(0x82b545), high: linear(0xb6d15a), frosty: linear(0xa8c7a6), parched: linear(0xbcc052))

    /// The mood at `x` along a table of (place, mood), eased between neighbours, held past its ends.
    private static func along(_ table: [(Double, Mood)], _ x: Double) -> Mood {
        guard let next = table.firstIndex(where: { $0.0 > x }) else { return table[table.count - 1].1 }
        guard next > 0 else { return table[0].1 }
        let (from, a) = table[next - 1], (to, b) = table[next]
        return a.toward(b, Float(smooth((x - from) / (to - from))))
    }

    /// The mood under the real sun: by its height, the morning's or the evening's, eased from one to the
    /// other across solar noon and solar midnight (where a low sun, in a polar winter's day or a summer's
    /// midnight sun, would otherwise jump from pink to gold).
    private static func mood(_ sun: Sun.Position) -> Mood {
        let evening = Float(smooth(0.5 + sin(sun.hourAngle * .pi / 180)))
        return along(RISING, sun.elevation).toward(along(SETTING, sun.elevation), evening)
    }

    /// Garden lamps on a light sensor come on once dusk has dimmed well past sunset and go out only once the
    /// morning is brighter than that (a sensor's "off" level is several times its "on" level, so it does not
    /// flicker at the edge): lit while the sun is 2° down in the evening, out once it is 1° up in the morning.
    static func lampsLit(_ sun: Sun.Position) -> Bool {
        sin(sun.hourAngle * .pi / 180) > 0 ? sun.elevation < -2 : sun.elevation < 1
    }
    /// At fixed hours: lit from a little after dusk's gold until a little before dawn's pink.
    static let lampsDark: Float = 0.4

    /// The light for these settings at `now` (a stopped clock, `.instant`, overrides it).
    static func light(_ settings: MeadowSettings, now: Date = Date()) -> Light {
        let effects = settings.effects
        let moment: Date? = switch settings.timeOfDay {
        case .followClock: now
        case .instant(let date): date
        case .day, .night, .hour: nil
        }
        var l = Light()
        let m: Mood
        if let moment, effects.contains(.sunTimes), let place = settings.place {
            let sun = Sun.position(at: moment, latitude: place.latitude, longitude: place.longitude)
            m = mood(sun)
            l.sunElevation = sun.elevation
            l.lampsLit = lampsLit(sun)
        } else {
            m = along(HOURS, min(max(hour(settings.timeOfDay, now: moment ?? now), 0), 23.999))
        }
        l.skyTop = m.top
        l.skyMid = m.mid
        l.horizon = m.horizon
        l.night = m.night
        if l.sunElevation == nil { l.lampsLit = m.night > Self.lampsDark }
        l.lampsLit = l.lampsLit && effects.contains(.lamps)
        // The real moon needs somewhere to be seen from: its phase, where its lit edge faces, and whether it
        // has risen. Without a place, or switched off, it is the meadow's own steady full moon.
        if effects.contains(.moonPhase), let place = settings.place {
            let date = moment ?? now
            l.moon = Moon.phase(at: date)
            let sky = Moon.sky(at: date, latitude: place.latitude, longitude: place.longitude)
            l.moonUp = Float(smooth((sky.altitude + 1) / 3))
            l.moonLimb = Vec2(Float(sky.limbUp), Float(sky.limbRight))
        }

        let weather = settings.weather
        // Weather on top of the hour: cloud, rain, snow and fog grey the sky and take the edge off the sun.
        let clouds = effects.contains(.clouds) ? weather : nil
        let cover: Float = clouds.map { $0.sky == .clear ? $0.cover * 0.6 : max($0.cover, 0.8) } ?? 0
        // A clouded night is a dull slate rather than black, but no brighter than a clear one.
        let grey = OVERCAST * (1 - 0.85 * l.night)
        l.skyTop = mix(l.skyTop, grey, t: cover * 0.75)
        l.skyMid = mix(l.skyMid, grey, t: cover * 0.75)
        l.horizon = mix(l.horizon, grey, t: cover * 0.75)
        l.keyColor = m.sun * m.sunPower * (1 - 0.5 * cover)
        let fill = m.fill * (1 - 0.1 * cover)
        l.hemiSky = m.above * fill
        l.hemiGround = m.below * fill
        // By day the rim light keeps a black cat readable against the field. At night it becomes the moon
        // behind them, cool and soft; the picnic's warm light does the rest.
        l.rimColor = mix(Vec3(1, 1, 1), MOONLIT_RIM, t: l.night) * (1.8 - 1.1 * l.night)
        l.cloudGlow = 0.5 - 0.46 * l.night
        l.stars = l.night * (1 - cover)
        l.moonShown = l.stars * l.moonUp
        if l.moonLimb != nil {
            // A moonlit night is lighter than a moonless one (which is the night as it always was), unless
            // the moon has set or cloud hides it; a bright moon washes out the fainter stars.
            let moonlight = Float(l.moon.lit) * l.moonUp * l.night * (1 - cover)
            l.hemiSky *= 1 + 0.3 * moonlight
            l.hemiGround *= 1 + 0.2 * moonlight
            l.rimColor *= 1 + 0.25 * moonlight
            l.stars *= 1 - 0.35 * Float(l.moon.lit) * l.moonUp
        }
        // Fog, and the haze of a day one cannot see far in (under 8 km, closing in fully by 1 km).
        if let clouds {
            l.mist = clouds.sky == .fog ? 1 : clouds.visibilityMeters.map { Float(smooth(Double((8000 - $0) / 7000))) } ?? 0
        }
        if effects.contains(.rainAndSnow), let w = weather, w.sky == .rain || w.sky == .snow {
            l.falling = max(w.intensity, 0.05)
            l.snowing = w.sky == .snow
            // Heavy rain blurs the far side of the meadow too.
            if !l.snowing { l.mist = max(l.mist, 0.35 * w.intensity) }
        }
        l.dropColor = (l.snowing ? Vec3(1, 1, 1) : linear(0xd6e6f5)) * (1 - 0.6 * l.night)
        l.thunder = effects.contains(.lightning) && weather?.thunder == true
        if effects.contains(.wind), let w = weather {
            // A breeze at a calm day's strength, more with the wind, up to a gale's at 40 km/h. The gusts set
            // how hard the grass is pushed at their height; between them the wind's steady share holds.
            let peak = max(w.windKmh, w.gustKmh ?? 0)
            l.wind = min(max(0.6 + peak / 20, 0.6), 2.6)
            if let gust = w.gustKmh, gust > 0.5 {
                l.windCalm = min(max(1 - 1.76 * (1 - min(w.windKmh / gust, 1)), 0.12), 0.75)
            }
            // Weather services say where the wind comes from; it blows the other way. North is away from
            // you along the meadow's length (−z), east to the right.
            if let from = w.windFromDegrees {
                let toward = (Double(from) + 180) * .pi / 180
                l.windToward = Vec2(Float(sin(toward)), Float(-cos(toward)))
            }
        }
        if effects.contains(.grassColor), let w = weather {
            // Near freezing the grass goes pale; in real heat it yellows.
            let cold = smooth((6 - w.temperatureC) / 8), hot = smooth((w.temperatureC - 27) / 8)
            l.turfLow = mix(mix(TURF.low, TURF.frosty, t: cold * 0.6), TURF.parched, t: hot * 0.5)
            l.turfHigh = mix(mix(TURF.high, TURF.frosty, t: cold * 0.7), TURF.parched, t: hot * 0.6)
        }
        return l
    }

    /// The hour on the clock the fixed table reads.
    static func hour(_ setting: MeadowSettings.TimeOfDay, now: Date = Date()) -> Double {
        switch setting {
        case .day: return 12
        case .night: return 23
        case .hour(let h): return h
        case .followClock, .instant:
            let c = Calendar.current.dateComponents([.hour, .minute], from: now)
            return Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        }
    }
}

@inline(__always) func mix(_ a: Vec3, _ b: Vec3, t: Float) -> Vec3 { a + (b - a) * t }
