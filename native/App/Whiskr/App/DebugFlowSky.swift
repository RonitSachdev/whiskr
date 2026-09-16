#if DEBUG
import AppKit
@_spi(Diagnostics) import MeadowScene
import WhiskrKit

/// `--perf-flows sky` (`make perf`'s checks): the real sky and weather in the app's own meadow, through the
/// app's own settings. The clock is stopped at known moments (`WorldStore.clockStoppedAt`) and the weather
/// given as Open-Meteo's answer would be (`WorldStore.useWeather`): nothing asks for the location and,
/// unless the run was given `--weather-place`, nothing goes to the network.
///
/// - The light follows the real sun over a fixed place: midday, sunset and midnight in London at
///   midsummer, the same evening hour in December; off, the sun is no longer followed.
/// - Settings saved before these switches existed load with every switch on.
/// - Each switch in Settings › Meadow, worked as a click works it, takes its effect away and gives it back;
///   the weather's are disabled while real weather is off.
/// - Lightning flashes in a thunderstorm, and never with the animation off or Reduce Motion on.
/// - The meadow still comes to rest in the weather.
/// - With `--weather-place`, Open-Meteo's real answer is read whole, once.
extension PerfSuite {
    /// A thunderstorm from the south-west, as Open-Meteo answers it: gusty, heavy rain, poor visibility, hot.
    static let stormAnswer = #"""
    {"latitude":51.5,"longitude":-0.12,"current":{"time":"2024-06-20T12:00","interval":900,"temperature_2m":31.0,"weather_code":95,
    "cloud_cover":100,"wind_speed_10m":25.0,"wind_direction_10m":225,"wind_gusts_10m":60.0,"precipitation":8.4,"rain":6.1,"showers":2.3,
    "snowfall":0.0,"visibility":3000.0}}
    """#

    func skyCheck() async {
        let store = WorldStore.shared, meadow = controller.navigator.meadow
        let saved = store.settings, animates = store.animatesMeadow, reduces = meadow.reduceMotion
        defer {
            store.clockStoppedAt = nil
            store.settings = saved
            store.animatesMeadow = animates
            meadow.reduceMotion = reduces
        }
        if DebugScenario.value("--weather-place") != nil { await realAnswer() }
        await sunTimes()
        olderSettings()
        await sunLine()
        await switches()
        await moonInView()
        await lightning()
        await rests()
    }

    /// The meadow once the settings have reached it (through an observer, a turn or two later).
    private func shown(_ settled: @escaping @MainActor (MeadowView) -> Bool) async -> MeadowView.SkyReading? {
        let meadow = controller.navigator.meadow
        guard await PerfWait.until(3000, { settled(meadow) }) != nil else { return nil }
        meadow.advance(seconds: 0.1)
        return meadow.sky
    }

    private func realAnswer() async {
        let store = WorldStore.shared
        let answered = await PerfWait.until(30000) { store.weather != nil || store.weatherProblem != nil }
        guard answered != nil, let weather = store.weather else {
            return check("sky: Open-Meteo answered the one request", false, "\(String(describing: store.weatherProblem))")
        }
        check("sky: Open-Meteo's real answer is read whole (wind direction, gusts, visibility as well as sky and temperature)",
              weather.windFromDegrees != nil && weather.gustKmh != nil && weather.visibilityMeters != nil,
              "\(weather)")
    }

    private func sunTimes() async {
        let store = WorldStore.shared
        store.settings.timeOfDay = .followClock
        store.settings.sunTimes = true
        store.settings.realWeather = false
        store.settings.place = WorldSettings.Place(latitude: 51.51, longitude: -0.13)
        let formatter = ISO8601DateFormatter()
        func at(_ text: String) async -> MeadowView.SkyReading? {
            let moment = formatter.date(from: text)!
            store.clockStoppedAt = moment
            return await shown { $0.settings.timeOfDay == .instant(moment) }
        }
        let noon = await at("2024-06-20T13:00:00+01:00"), sunset = await at("2024-06-20T21:21:00+01:00")
        let midnight = await at("2024-06-20T23:59:00+01:00"), december = await at("2024-12-21T21:21:00Z")
        check("sky: London at midsummer is day at one, dusk at its 21:21 sunset, night by midnight; December's 21:21 is night",
              noon?.night == 0 && (noon?.sunElevation ?? 0) > 55 && (0.3..<0.75).contains(sunset?.night ?? -1)
                  && midnight?.night == 1 && december?.night == 1,
              "night \(noon?.night ?? -1), \(sunset?.night ?? -1), \(midnight?.night ?? -1), \(december?.night ?? -1); sun at one \(noon?.sunElevation ?? -99)°")
        store.settings.sunTimes = false
        let fixed = await shown { $0.sky.sunElevation == nil }
        check("sky: Real sunrise and sunset off, the light keeps to the clock's fixed hours", fixed != nil)
        store.settings.sunTimes = true
        _ = await shown { $0.sky.sunElevation != nil }
        // Where the sun is reckoned without a place: the time zone's guess, never a question.
        store.settings.place = nil
        let guessed = await shown { $0.settings.place == MeadowPlace.estimate(for: .autoupdatingCurrent) }
        check("sky: with no place found, the sun is reckoned from the time zone", guessed != nil && !store.askingForLocation)
        store.clockStoppedAt = nil
    }

    private func olderSettings() {
        let defaults = AppPlaces.defaults
        let before = defaults.data(forKey: WorldSettings.defaultsKey)
        defer { defaults.set(before, forKey: WorldSettings.defaultsKey) }
        defaults.set(Data(#"{"flagSize":"large","map":"meadow","picnic":"spread","realWeather":false,"timeOfDay":"night"}"#.utf8), forKey: WorldSettings.defaultsKey)
        let read = WorldSettings.read(from: defaults)
        check("sky: settings saved before the sky's switches load as they were, every new switch on",
              read.timeOfDay == .night && read.picnic == .spread && read.flagSize == .large
                  && read.sunTimes && read.moonPhase && read.clouds && read.wind && read.rainAndSnow && read.lightning && read.grassColor)
    }

    /// Settings › Meadow's "Today: sunrise …, sunset …" is worked out again when the day or the time zone
    /// changes while it shows, and only then.
    private func sunLine() async {
        let store = WorldStore.shared
        store.settings.timeOfDay = .followClock
        store.settings.sunTimes = true
        store.settings.place = WorldSettings.Place(latitude: 51.51, longitude: -0.13)
        let formatter = ISO8601DateFormatter()
        let june = formatter.date(from: "2024-06-20T12:00:00Z")!, december = formatter.date(from: "2024-12-21T12:00:00Z")!
        store.clockStoppedAt = june
        let settings = SettingsWindowController.shared
        settings.show()
        guard let window = settings.window, let tabs = window.contentViewController as? SettingsTabs else {
            return check("sky: Settings opened", false)
        }
        tabs.select(pane: "meadow")
        defer { window.orderOut(nil) }
        // What the line was last worked out for, by its day.
        func shows(_ day: Date) -> Bool { SunTodayProbe.shownDay.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
        // The pane opened on the stopped clock's day.
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        let juneShown = await PerfWait.until(3000) { shows(june) }
        store.clockStoppedAt = december
        await PerfWait.sleep(500)
        let stayed = shows(june)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        let decemberShown = await PerfWait.until(3000) { shows(december) }
        store.clockStoppedAt = june
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        let zoneShown = await PerfWait.until(3000) { shows(june) }
        check("sky: Settings' sunrise line follows a change of day and of time zone while it shows",
              juneShown != nil && stayed && decemberShown != nil && zoneShown != nil,
              "June \(juneShown != nil), kept until told \(stayed), December \(decemberShown != nil), after a time zone change \(zoneShown != nil)")
        store.clockStoppedAt = nil
    }

    /// At night with the moon up, a view tilted as low as it goes shows the moon whole inside it.
    private func moonInView() async {
        let store = WorldStore.shared, meadow = controller.navigator.meadow
        store.settings.realWeather = false
        store.settings.timeOfDay = .followClock
        store.settings.moonPhase = true
        store.settings.place = WorldSettings.Place(latitude: 51.51, longitude: -0.13)
        store.clockStoppedAt = ISO8601DateFormatter().date(from: "2024-04-23T23:30:00+01:00")
        _ = await shown { $0.sky.moonShown > 0.5 }
        meadow.turn(toBearing: meadow.cameraAngle.bearing, pitch: 0)
        meadow.advance(seconds: 3)
        let low = meadow.moonRect
        let inside = low.map { meadow.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) } ?? false
        check("sky: the full moon is up over London at 23:30 on 23 April 2024, and a view tilted low shows it whole",
              meadow.sky.moonShown > 0.5 && meadow.sky.moonLit > 0.99 && inside, "\(String(describing: low)) in \(meadow.bounds)")
        store.clockStoppedAt = nil
    }

    /// The switches in Settings › Meadow, worked as clicks work them.
    private func switches() async {
        let store = WorldStore.shared, meadow = controller.navigator.meadow
        // Midday in London three days after a new moon: the sun high, a thin crescent.
        store.settings.timeOfDay = .followClock
        store.settings.place = WorldSettings.Place(latitude: 51.51, longitude: -0.13)
        store.clockStoppedAt = ISO8601DateFormatter().date(from: "2024-04-11T12:00:00Z")
        store.settings.realWeather = false
        let settings = SettingsWindowController.shared
        settings.show()
        guard let window = settings.window, let tabs = window.contentViewController as? SettingsTabs, let root = window.contentView else {
            return check("sky: Settings opened", false)
        }
        tabs.select(pane: "meadow")
        defer { window.orderOut(nil) }
        func switchesNow() -> [NSSwitch] { Self.controls(in: root).compactMap { $0 as? NSSwitch } }
        // Off: the sun's, the moon's, real weather's and the animation's only (the weather's are disabled,
        // with a reason).
        let off = await PerfWait.until(3000) { switchesNow().count == 4 }
        check("sky: with real weather off, its five switches are disabled", off != nil, "\(switchesNow().count) switches enabled")

        guard let answer = MeadowWeather(openMeteo: Data(Self.stormAnswer.utf8)) else { return check("sky: the storm's answer reads", false) }
        store.useWeather(answer)
        let on = await PerfWait.until(3000) { switchesNow().count == 9 }
        check("sky: with real weather on, all nine switches can be worked", on != nil, "\(switchesNow().count) switches enabled")
        // The wind eases round to the storm's over a few seconds.
        guard let all = await shown({ $0.settings.weather != nil && $0.sky.windToward.z < -0.68 }) else {
            return check("sky: the storm reaches the meadow, its wind eased round", false, "\(meadow.sky)")
        }
        check("sky: the storm shows: a gusty wind from the south-west, heavy rain, haze, thunder, hot grass",
              all.wind > 2 && all.windToward.x > 0.6 && all.windToward.z < -0.6 && all.windCalm < 0.3 && all.falling > 0.8 && all.drops > 600
                  && all.mist > 0.3 && all.thunder,
              "\(all)")

        // In the order they are laid out: sun, moon, real weather, then the weather's five.
        let effects: [(String, WritableKeyPath<WorldSettings, Bool>, MeadowSettings.Effects, @MainActor (MeadowView.SkyReading) -> Bool)] = [
            ("Real sunrise and sunset", \.sunTimes, .sunTimes, { $0.sunElevation == nil }),
            ("Moon phase", \.moonPhase, .moonPhase, { $0.moonLit == 1 }),
            // Only heavy rain's own haze is left.
            ("Clouds and fog", \.clouds, .clouds, { $0.mist <= 0.35 * $0.falling + 0.001 }),
            ("Wind", \.wind, .wind, { $0.wind == 1 && $0.windCalm == 0.12 }),
            ("Rain and snow", \.rainAndSnow, .rainAndSnow, { $0.falling == 0 && $0.drops == 0 }),
            ("Lightning", \.lightning, .lightning, { !$0.thunder }),
            ("Grass color from the temperature", \.grassColor, .grassColor, { $0.turf != all.turf }),
        ]
        for (index, (name, path, effect, gone)) in effects.enumerated() {
            let place = index < 2 ? index : index + 1
            guard switchesNow().indices.contains(place) else { check("sky: \(name)'s switch", false); continue }
            Self.set(switchesNow()[place], to: 0)
            let turnedOff = await PerfWait.until(2000) { !store.settings[keyPath: path] }
            let reading = await shown { !$0.settings.effects.contains(effect) }
            let took = reading.map(gone) ?? false
            if switchesNow().indices.contains(place) { Self.set(switchesNow()[place], to: 1) }
            let back = await shown { $0.settings.effects.contains(effect) }
            check("sky: \(name) off takes its effect away, and on gives it back", turnedOff != nil && took && back.map(gone) == false,
                  reading.map { "\($0)" } ?? "not shown")
        }
        store.clockStoppedAt = nil
    }

    private func lightning() async {
        let store = WorldStore.shared, meadow = controller.navigator.meadow
        guard let answer = MeadowWeather(openMeteo: Data(Self.stormAnswer.utf8)) else { return }
        store.useWeather(answer)
        meadow.reduceMotion = false
        _ = await shown { $0.sky.thunder }
        func brightest(seconds: Double) -> Float {
            var most: Float = 0
            for _ in 0..<Int(seconds * 30) {
                meadow.advance(seconds: 1.0 / 30)
                most = max(most, meadow.sky.flash)
            }
            return most
        }
        store.animatesMeadow = true
        _ = await PerfWait.until(2000) { meadow.animatesAmbient }
        let flashes = brightest(seconds: 70)
        store.animatesMeadow = false
        _ = await PerfWait.until(2000) { !meadow.animatesAmbient }
        let stillOff = brightest(seconds: 70)
        store.animatesMeadow = true
        _ = await PerfWait.until(2000) { meadow.animatesAmbient }
        meadow.reduceMotion = true
        let stillCalm = brightest(seconds: 70)
        meadow.reduceMotion = false
        check("sky: lightning flashes in a thunderstorm, and never with the animation off or Reduce Motion on",
              flashes > 0.3 && stillOff == 0 && stillCalm == 0, "brightest \(flashes), animation off \(stillOff), Reduce Motion \(stillCalm)")
    }

    private func rests() async {
        let store = WorldStore.shared, meadow = controller.navigator.meadow
        for (name, thunder) in [("rain and wind", false), ("a thunderstorm", true)] {
            guard var answer = MeadowWeather(openMeteo: Data(Self.stormAnswer.utf8)) else { return }
            answer.thunder = thunder
            store.useWeather(answer)
            let rested = await PerfWait.until(20000) { meadow.isResting }
            check("sky: the meadow comes to rest in \(name)", rested != nil)
        }
    }
}
#endif
