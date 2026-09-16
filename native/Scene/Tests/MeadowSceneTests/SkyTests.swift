import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The real sky (`Sky.swift`, `Daylight`): sunrise and sunset against published almanac times, the polar day
// and night, clock changes, the moon's phase on known dates, the light following the sun, each of
// Settings › Meadow's switches taking its effect away, Open-Meteo's answer read, and the lightning kept rare,
// gentle and still when motion is not wanted.

private func moment(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func clock(_ date: Date, _ zone: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: zone)
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

/// Minutes between two clock readings written "yyyy-MM-dd HH:mm" in the same zone.
private func minutesApart(_ a: Date, _ wanted: String, _ zone: String) -> Double {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: zone)
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return abs(a.timeIntervalSince(f.date(from: wanted)!)) / 60
}

struct SunAndMoon {
    /// Published sunrise and sunset times (local clock, to the minute) for city centres.
    static let almanac: [(city: String, lat: Double, lon: Double, zone: String, day: String, rise: String, set: String)] = [
        ("London, midsummer", 51.5074, -0.1278, "Europe/London", "2024-06-20", "04:43", "21:21"),
        ("London, midwinter", 51.5074, -0.1278, "Europe/London", "2024-12-21", "08:04", "15:53"),
        ("New York, midsummer", 40.7128, -74.0060, "America/New_York", "2024-06-20", "05:25", "20:31"),
        ("Tokyo, midwinter", 35.6895, 139.6917, "Asia/Tokyo", "2024-12-21", "06:47", "16:32"),
        ("Tokyo, midsummer", 35.6895, 139.6917, "Asia/Tokyo", "2024-06-21", "04:25", "19:00"),
        ("Sydney, its midsummer", -33.8688, 151.2093, "Australia/Sydney", "2024-12-21", "05:41", "20:05"),
        ("Sydney, its midwinter", -33.8688, 151.2093, "Australia/Sydney", "2024-06-21", "07:00", "16:54"),
    ]

    @Test("sunrise and sunset agree with the almanac to within two minutes", arguments: almanac.indices)
    func almanacTimes(_ i: Int) throws {
        let a = Self.almanac[i]
        let zone = try #require(TimeZone(identifier: a.zone))
        let day = Sun.day(containing: moment("\(a.day)T12:00:00Z"), latitude: a.lat, longitude: a.lon, timeZone: zone)
        guard case .risesAndSets(let rise, let set) = day else { Issue.record("\(a.city): \(day)"); return }
        #expect(minutesApart(rise, "\(a.day) \(a.rise)", a.zone) <= 2, "\(a.city): rises \(clock(rise, a.zone)), almanac \(a.rise)")
        #expect(minutesApart(set, "\(a.day) \(a.set)", a.zone) <= 2, "\(a.city): sets \(clock(set, a.zone)), almanac \(a.set)")
    }

    @Test("a sunset after midnight belongs to the day it ends (Reykjavík at midsummer: 00:04 the next morning)")
    func sunsetAfterMidnight() throws {
        let zone = try #require(TimeZone(identifier: "Atlantic/Reykjavik"))
        let day = Sun.day(containing: moment("2024-06-21T12:00:00Z"), latitude: 64.1466, longitude: -21.9426, timeZone: zone)
        guard case .risesAndSets(let rise, let set) = day else { Issue.record("\(day)"); return }
        #expect(minutesApart(rise, "2024-06-21 02:55", "Atlantic/Reykjavik") <= 2, "\(clock(rise, "Atlantic/Reykjavik"))")
        #expect(minutesApart(set, "2024-06-22 00:04", "Atlantic/Reykjavik") <= 2, "\(clock(set, "Atlantic/Reykjavik"))")
    }

    @Test("past the Arctic Circle the sun stays up all midsummer and down all midwinter")
    func polar() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Oslo"))
        #expect(Sun.day(containing: moment("2024-06-21T12:00:00Z"), latitude: 69.6492, longitude: 18.9553, timeZone: zone) == .alwaysUp)
        #expect(Sun.day(containing: moment("2024-12-21T12:00:00Z"), latitude: 69.6492, longitude: 18.9553, timeZone: zone) == .alwaysDown)
        // At the South Pole the seasons are the other way round.
        #expect(Sun.day(containing: moment("2024-12-21T12:00:00Z"), latitude: -89.9, longitude: 0, timeZone: .gmt) == .alwaysUp)
    }

    @Test("the clocks going forward move sunrise on the clock by an hour, less the day's two minutes")
    func clocksChange() throws {
        let zone = try #require(TimeZone(identifier: "Europe/London"))
        func rise(_ day: String) -> Date? {
            if case .risesAndSets(let rise, _) = Sun.day(containing: moment("\(day)T12:00:00Z"), latitude: 51.5074, longitude: -0.1278, timeZone: zone) { return rise }
            return nil
        }
        let before = try #require(rise("2024-03-30")), after = try #require(rise("2024-03-31"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func clockMinutes(_ d: Date) -> Int { let c = calendar.dateComponents([.hour, .minute], from: d); return c.hour! * 60 + c.minute! }
        let jump = clockMinutes(after) - clockMinutes(before)
        #expect((56...59).contains(jump), "sunrise on the clock moved \(jump) minutes")
    }

    @Test("the moon's phase on known dates: new, first quarter, full, last quarter")
    func moonPhases() {
        let new = Moon.phase(at: moment("2024-04-08T18:21:00Z"))
        let first = Moon.phase(at: moment("2024-04-15T19:13:00Z"))
        let full = Moon.phase(at: moment("2024-04-23T23:49:00Z"))
        let last = Moon.phase(at: moment("2024-05-01T11:27:00Z"))
        #expect(new.lit < 0.01)
        #expect(abs(first.lit - 0.5) < 0.03 && first.waxing)
        #expect(full.lit > 0.99)
        #expect(abs(last.lit - 0.5) < 0.03 && !last.waxing)
        // A crescent three days after new, waxing.
        let crescent = Moon.phase(at: moment("2024-04-11T20:00:00Z"))
        #expect(crescent.lit > 0.03 && crescent.lit < 0.2 && crescent.waxing, "\(crescent)")
    }

    @Test("a place from the time zone alone: its city when known, else its offset's longitude")
    func placeFromTimeZone() throws {
        let tokyo = MeadowPlace.estimate(for: try #require(TimeZone(identifier: "Asia/Tokyo")))
        #expect(abs(tokyo.latitude - 35.68) < 0.1 && abs(tokyo.longitude - 139.69) < 0.1)
        // A zone not in the table: UTC+11 all year, in Asia.
        let far = MeadowPlace.estimate(for: try #require(TimeZone(identifier: "Asia/Srednekolymsk")))
        #expect(abs(far.longitude - 165) < 0.01 && far.latitude == 32)
        // Daylight saving does not move the guess: New York in July is still at New York.
        let zone = try #require(TimeZone(identifier: "America/Indiana/Vincennes"))
        let summer = MeadowPlace.estimate(for: zone, at: moment("2024-07-01T12:00:00Z")), winter = MeadowPlace.estimate(for: zone, at: moment("2024-01-01T12:00:00Z"))
        #expect(summer == winter && abs(summer.longitude + 75) < 0.01)
        // Every place in the table is on Earth.
        for (name, city) in MeadowPlace.zoneCities {
            #expect(abs(city.0) <= 90 && abs(city.1) <= 180, "\(name)")
            #expect(TimeZone(identifier: name) != nil, "\(name) is not a time zone this Mac knows")
        }
    }
}

struct LightFollowsTheSun {
    static let london = MeadowPlace(latitude: 51.5074, longitude: -0.1278)
    static let tokyo = MeadowPlace(latitude: 35.6895, longitude: 139.6917)

    func light(_ at: String, _ place: MeadowPlace?, weather: MeadowWeather? = nil, effects: MeadowSettings.Effects = .all) -> Light {
        Daylight.light(MeadowSettings(timeOfDay: .instant(moment(at)), weather: weather, place: place, effects: effects))
    }

    @Test("in London at midsummer: day at one, dusk at sunset, still twilight at ten, night by midnight")
    func londonSummer() {
        #expect(light("2024-06-20T13:00:00+01:00", Self.london).night == 0)
        let sunset = light("2024-06-20T21:21:00+01:00", Self.london)
        #expect(sunset.night > 0.3 && sunset.night < 0.75, "\(sunset.night)")
        let ten = light("2024-06-20T22:00:00+01:00", Self.london)
        #expect(ten.night > sunset.night && ten.night < 1, "\(ten.night)")
        #expect(light("2024-06-20T23:59:00+01:00", Self.london).night == 1)
        // The same hour in December is long dark, and at nine in the morning the sun has only just risen.
        #expect(light("2024-12-21T21:21:00Z", Self.london).night == 1)
        let morning = light("2024-12-21T09:00:00Z", Self.london)
        #expect(morning.night == 0 && morning.keyColor != light("2024-12-21T12:00:00Z", Self.london).keyColor)
    }

    @Test("half past seven in Tokyo: twilight in June, night in December")
    func tokyoEvenings() {
        let june = light("2024-06-21T19:30:00+09:00", Self.tokyo).night, december = light("2024-12-21T19:30:00+09:00", Self.tokyo).night
        #expect(june > 0.3 && june < 1, "\(june)")
        #expect(december == 1)
    }

    @Test("without the real sun (switched off, or nowhere known) the clock's fixed hours rule")
    func fixedHours() {
        let at = "2024-12-21T17:00:00Z"
        // The moon is left out here: on a fixed hour it is tonight's, not that day's.
        let sunOnly = MeadowSettings.Effects.all.subtracting(.moonPhase), hours = sunOnly.subtracting(.sunTimes)
        let table = Daylight.light(MeadowSettings(timeOfDay: .hour(Daylight.hour(.instant(moment(at)), now: moment(at))), effects: hours))
        #expect(light(at, Self.london, effects: hours) == table)
        #expect(light(at, nil, effects: sunOnly) == table)
        #expect(light(at, Self.london, effects: hours).sunElevation == nil)
        #expect(light(at, Self.london).sunElevation != nil)
    }

    @Test("a polar winter's noon is twilight, never day; a midsummer midnight there is golden; neither jumps at solar noon or midnight")
    func polarLight() {
        let tromso = MeadowPlace(latitude: 69.6492, longitude: 18.9553)
        let noon = light("2024-12-21T10:45:00Z", tromso)
        #expect(noon.night > 0.2, "\(noon.night)")
        // The midnight sun, 3° up: a low gold, no darker than an evening before sunset.
        let midnight = light("2024-06-21T22:45:00Z", tromso)
        #expect(midnight.night < 0.3, "\(midnight.night)")
        // Across solar noon (about 10:44 UTC there) and solar midnight the light eases, a minute apart.
        for (a, b) in [("2024-12-21T10:43:00Z", "2024-12-21T10:45:00Z"), ("2024-06-21T22:43:00Z", "2024-06-21T22:45:00Z")] {
            let x = light(a, tromso), y = light(b, tromso)
            #expect(simd_length(x.skyMid - y.skyMid) < 0.01 && simd_length(x.keyColor - y.keyColor) < 0.02, "\(a) to \(b)")
        }
    }
}

struct TheRealMoon {
    static let london = MeadowPlace(latitude: 51.51, longitude: -0.13)

    func light(_ at: String, _ place: MeadowPlace? = london) -> Light {
        Daylight.light(MeadowSettings(timeOfDay: .instant(moment(at)), place: place))
    }

    @Test("the moon rises and sets: the full moon of 23 April 2024 is up over London at half past eleven at night, not at midday")
    func risesAndSets() {
        let night = light("2024-04-23T23:30:00+01:00"), noon = light("2024-04-24T13:00:00+01:00")
        #expect(night.moonUp == 1 && night.moonShown > 0.9 && night.moon.lit > 0.99)
        // Set by day; and at night a set moon is not shown (a waning crescent before it rises, 30 April).
        #expect(noon.moonUp == 0)
        let beforeRise = light("2024-05-03T22:30:00+01:00")
        #expect(beforeRise.night == 1 && beforeRise.moonUp == 0 && beforeRise.moonShown == 0)
    }

    @Test("an evening crescent is lit on its low, sunward side: down and to the right in the north, down and to the left in the south")
    func crescentFacesTheSun() throws {
        let north = light("2024-04-11T21:45:00+01:00")
        let limb = try #require(north.moonLimb)
        #expect(north.moon.waxing && north.moon.lit < 0.15 && north.moonUp > 0.9)
        #expect(limb.x < 0 && limb.y > 0, "\(limb)")
        let sydney = light("2024-04-11T19:00:00+10:00", MeadowPlace(latitude: -33.87, longitude: 151.21))
        let south = try #require(sydney.moonLimb)
        #expect(south.x < 0 && south.y < 0, "\(south)")
    }

    @Test("with nowhere to see it from, or switched off, the moon is the meadow's own: full, always up, the same whatever the date")
    func withoutAPlace() {
        let a = light("2024-04-11T21:45:00Z", nil), b = light("2024-04-23T21:45:00Z", nil)
        #expect(a == b && a.moon == .full && a.moonLimb == nil && a.moonUp == 1)
    }

    @Test("lit from the side its edge faces: from behind you at full, from behind it at new, from the side between")
    func sunlightOnTheMoon() {
        let toward = simd_normalize(Vec3(-0.3, 0.05, -0.95))
        let full = MeadowDrawer.sunlight(on: .full, limb: nil, toward: toward)
        #expect(simd_distance(full, -toward) < 1e-5)
        let new = MeadowDrawer.sunlight(on: Moon.Phase(angle: .pi, waxing: true), limb: Vec2(0, 1), toward: toward)
        #expect(simd_distance(new, toward) < 1e-5)
        let quarter = MeadowDrawer.sunlight(on: Moon.Phase(angle: .pi / 2, waxing: true), limb: Vec2(0, 1), toward: toward)
        let right = simd_normalize(simd_cross(toward, Vec3(0, 1, 0)))
        #expect(abs(simd_dot(quarter, toward)) < 1e-5 && simd_dot(quarter, right) > 0.99)
    }
}

struct WeatherEffects {
    /// Everything at once: a gusty thunderstorm from the south-west, heavy rain, poor visibility, hot.
    static let storm = MeadowWeather(sky: .rain, cover: 1, windKmh: 25, temperatureC: 31, windFromDegrees: 225, gustKmh: 60,
                                     intensity: 0.9, thunder: true, visibilityMeters: 3000)

    func light(_ effects: MeadowSettings.Effects, weather: MeadowWeather? = storm) -> Light {
        Daylight.light(MeadowSettings(timeOfDay: .hour(13), weather: weather, effects: effects))
    }

    @Test("each switch takes its own effect away and leaves the rest")
    func eachSwitch() {
        let all = light(.all), clear = light(.all, weather: nil)
        #expect(all.wind > 2 && all.windCalm < 0.3 && all.falling > 0.8 && all.thunder && all.mist > 0.3 && all.turfLow != clear.turfLow && all.skyTop != clear.skyTop)

        let noWind = light(MeadowSettings.Effects.all.subtracting(.wind))
        #expect(noWind.wind == clear.wind && noWind.windToward == clear.windToward && noWind.windCalm == clear.windCalm)
        #expect(noWind.falling == all.falling && noWind.thunder)

        let noClouds = light(MeadowSettings.Effects.all.subtracting(.clouds))
        #expect(noClouds.skyTop == clear.skyTop && noClouds.keyColor == clear.keyColor && noClouds.stars == clear.stars)
        // Only heavy rain's own haze is left.
        #expect(abs(noClouds.mist - 0.35 * 0.9) < 1e-5)

        let noRain = light(MeadowSettings.Effects.all.subtracting(.rainAndSnow))
        #expect(noRain.falling == 0 && noRain.skyTop == all.skyTop)

        let noLightning = light(MeadowSettings.Effects.all.subtracting(.lightning))
        #expect(!noLightning.thunder && noLightning.falling == all.falling)

        let noGrass = light(MeadowSettings.Effects.all.subtracting(.grassColor))
        #expect(noGrass.turfLow == clear.turfLow && noGrass.turfHigh == clear.turfHigh)

        let london = MeadowPlace(latitude: 51.51, longitude: -0.13)
        let night = Daylight.light(MeadowSettings(timeOfDay: .instant(moment("2024-04-11T20:45:00Z")), place: london,
                                                  effects: MeadowSettings.Effects.all.subtracting(.moonPhase)))
        #expect(night.moon == .full && night.moonLimb == nil && night.moonUp == 1)
        let phased = Daylight.light(MeadowSettings(timeOfDay: .instant(moment("2024-04-11T20:45:00Z")), place: london))
        #expect(phased.moon.lit < 0.3 && phased.moonLimb != nil)

        // Nothing at all: as if there were no weather.
        #expect(light([]) == light([], weather: nil))
    }

    @Test("the wind blows the way the weather says: from the west toward the east, from the north toward you")
    func windDirection() {
        func toward(_ from: Float) -> Vec2 {
            light(.all, weather: MeadowWeather(sky: .clear, cover: 0, windKmh: 20, temperatureC: 15, windFromDegrees: from)).windToward
        }
        #expect(simd_distance(toward(270), Vec2(1, 0)) < 1e-5)
        #expect(simd_distance(toward(0), Vec2(0, 1)) < 1e-5)
        #expect(simd_distance(toward(90), Vec2(-1, 0)) < 1e-5)
        // A steady wind keeps most of its push between gusts; a gusty one little.
        let steady = light(.all, weather: MeadowWeather(sky: .clear, cover: 0, windKmh: 30, temperatureC: 15, gustKmh: 33)).windCalm
        let gusty = light(.all, weather: MeadowWeather(sky: .clear, cover: 0, windKmh: 12, temperatureC: 15, gustKmh: 45)).windCalm
        #expect(steady > 0.6 && gusty == 0.12)
    }

    @MainActor @Test("rain and snow from light to heavy: fewer or more drops")
    func intensity() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), mode: .meadow)
        var counts: [Int] = []
        for amount: Float in [0.1, 0.5, 1] {
            view.settings = MeadowSettings(timeOfDay: .day, weather: MeadowWeather(sky: .rain, cover: 0.9, windKmh: 10, temperatureC: 12, intensity: amount))
            view.advance(seconds: 0.2)
            counts.append(view.sky.drops)
        }
        #expect(counts[0] > 0 && counts[0] < counts[1] && counts[1] < counts[2] && counts[2] == Meadow.fall.drops, "\(counts)")
        view.settings = MeadowSettings(timeOfDay: .day, weather: MeadowWeather(sky: .rain, cover: 0.9, windKmh: 10, temperatureC: 12),
                                       effects: MeadowSettings.Effects.all.subtracting(.rainAndSnow))
        view.advance(seconds: 0.2)
        #expect(view.sky.drops == 0)
    }

    @MainActor @Test("a switch turned off in the view's settings takes its effect away at once, and on gives it back")
    func viewSettings() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), mode: .meadow)
        view.settings = MeadowSettings(timeOfDay: .day, weather: Self.storm)
        view.advance(seconds: 0.1)
        #expect(view.sky.mist > 0.5 && view.sky.falling > 0.8 && view.sky.wind > 2)
        let all = view.settings
        let switches: [(MeadowSettings.Effects, (MeadowView.SkyReading) -> Bool)] = [
            (.clouds, { $0.mist < 0.33 }), (.rainAndSnow, { $0.falling == 0 && $0.drops == 0 }), (.wind, { $0.wind == 1 }), (.lightning, { !$0.thunder }),
        ]
        for (effect, gone) in switches {
            var settings = all
            settings.effects.remove(effect)
            view.settings = settings
            view.advance(seconds: 0.1)
            #expect(gone(view.sky), "\(effect): \(view.sky)")
            view.settings = all
            view.advance(seconds: 0.1)
            #expect(!gone(view.sky), "\(effect) back: \(view.sky)")
        }
    }

    @Test("Open-Meteo's answer read whole, and with only the temperature")
    func openMeteo() throws {
        let full = Data("""
        {"latitude":35.7,"longitude":139.69,"current":{"time":"2024-06-20T12:00","interval":900,"temperature_2m":22.4,"weather_code":95,
        "cloud_cover":100,"wind_speed_10m":18.7,"wind_direction_10m":225,"wind_gusts_10m":46.8,"precipitation":3.2,"rain":2.0,"showers":1.2,
        "snowfall":0.0,"visibility":6400.0}}
        """.utf8)
        let w = try #require(MeadowWeather(openMeteo: full))
        #expect(w.sky == .rain && w.thunder && w.cover == 1 && w.windKmh == 18.7 && w.windFromDegrees == 225 && w.gustKmh == 46.8)
        #expect(w.visibilityMeters == 6400 && w.temperatureC == 22.4)
        // 3.2 mm an hour is moderate rain, but the code says a thunderstorm's: the harder of the two.
        #expect(abs(w.intensity - 0.65) < 0.01, "\(w.intensity)")

        let bare = try #require(MeadowWeather(openMeteo: Data(#"{"current":{"temperature_2m":-1.5,"weather_code":73,"snowfall":0.2}}"#.utf8)))
        #expect(bare.sky == .snow && bare.windFromDegrees == nil && bare.gustKmh == nil && bare.visibilityMeters == nil && !bare.thunder)
        #expect(bare.intensity == MeadowWeather.intensity(wmo: 73))
        let heavy = try #require(MeadowWeather(openMeteo: Data(#"{"current":{"temperature_2m":12,"weather_code":61,"rain":9.5}}"#.utf8)))
        #expect(heavy.intensity > 0.9)
        #expect(MeadowWeather(openMeteo: Data(#"{"current":{"weather_code":3}}"#.utf8)) == nil)
        // Every field the meadow reads is asked for, in the one request.
        let url = MeadowWeather.openMeteoURL(latitude: 35.68, longitude: 139.69).absoluteString
        for field in ["temperature_2m", "weather_code", "cloud_cover", "wind_speed_10m", "wind_direction_10m", "wind_gusts_10m", "precipitation", "rain", "showers", "snowfall", "visibility"] {
            #expect(url.contains(field), "\(field)")
        }
    }
}

@MainActor
@Suite(.serialized) struct LightningTests {
    @Test("flashes are soft, rare and never more than two pulses a second, with ten seconds or more between flashes")
    func rareAndSlow() {
        var starts: [Double] = []
        var last: Float = 0, peak: Float = 0
        var t = 0.0
        while t < 20_000 {
            let f = Lightning.flash(at: t)
            if f > 0.02 && last <= 0.02 { starts.append(t) }
            peak = max(peak, f)
            last = f
            t += 0.005
        }
        #expect(peak <= 1 && peak > 0.5)
        var worst = 0
        for (i, a) in starts.enumerated() { worst = max(worst, starts[i...].prefix { $0 - a < 1 }.count) }
        #expect(worst <= 2, "\(worst) pulses within a second")
        // Groups of pulses (a flash and its echo) are at least ten seconds apart.
        var groups: [Double] = []
        for s in starts where groups.last.map({ s - $0 > 1 }) ?? true { groups.append(s) }
        let gaps = zip(groups.dropFirst(), groups).map { $0 - $1 }
        #expect(gaps.min() ?? 0 >= 10, "\(gaps.min() ?? 0)")
        let perMinute = Double(groups.count) / (20_000 / 60)
        #expect(perMinute > 1 && perMinute < 3.5, "\(perMinute) flashes a minute")
    }

    func stormView() -> MeadowView {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), mode: .meadow)
        view.settings = MeadowSettings(timeOfDay: .day, weather: WeatherEffects.storm)
        view.reduceMotion = false
        return view
    }

    func brightest(_ view: MeadowView, seconds: Double) -> Float {
        var most: Float = 0
        for _ in 0..<Int(seconds * 30) {
            view.advance(seconds: 1.0 / 30)
            most = max(most, view.sky.flash)
        }
        return most
    }

    @Test("in a thunderstorm the sky flashes now and then; never with the animation off, Reduce Motion on or the switch off")
    func onlyWhenMotionIsWanted() {
        let view = stormView()
        #expect(brightest(view, seconds: 70) > 0.3)

        view.animatesAmbient = false
        #expect(brightest(view, seconds: 70) == 0)
        view.animatesAmbient = true

        view.reduceMotion = true
        #expect(brightest(view, seconds: 70) == 0)
        view.reduceMotion = false

        var settings = view.settings
        settings.effects.remove(.lightning)
        view.settings = settings
        #expect(brightest(view, seconds: 70) == 0)
    }
}
