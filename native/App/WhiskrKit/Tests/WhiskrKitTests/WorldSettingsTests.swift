import Foundation
import Testing
@testable import WhiskrKit

// Settings › Meadow kept in the user defaults: settings saved before a switch existed load with it on, and
// a value that no longer makes sense keeps its default rather than losing the rest.

struct WorldSettingsSaving {
    @Test("settings saved before the sky's switches existed load as they were, with every new switch on")
    func olderSettings() throws {
        let saved = #"{"flagSize":"large","map":"meadow","picnic":"spread","place":{"latitude":35.68,"longitude":139.69},"realWeather":true,"timeOfDay":"night"}"#
        let world = try JSONDecoder().decode(WorldSettings.self, from: Data(saved.utf8))
        #expect(world.timeOfDay == .night && world.picnic == .spread && world.flagSize == .large && world.realWeather)
        #expect(world.place == WorldSettings.Place(latitude: 35.68, longitude: 139.69))
        #expect(world.sunTimes && world.moonPhase && world.clouds && world.wind && world.rainAndSnow && world.lightning && world.grassColor)
    }

    @Test("every switch is kept, and the same settings are always the same bytes")
    func roundTrip() throws {
        let world = WorldSettings(timeOfDay: .day, realWeather: true, sunTimes: false, moonPhase: false, clouds: true, wind: false,
                                  rainAndSnow: false, lightning: false, grassColor: false)
        let suite = "WorldSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        world.write(to: defaults)
        let first = defaults.data(forKey: WorldSettings.defaultsKey)
        #expect(WorldSettings.read(from: defaults) == world)
        WorldSettings.read(from: defaults).write(to: defaults)
        #expect(defaults.data(forKey: WorldSettings.defaultsKey) == first)
    }

    @Test("a value that makes no sense keeps its default; the rest still load")
    func strayValues() throws {
        let saved = #"{"timeOfDay":"dusk","wind":"yes","lightning":false,"picnic":"hamper"}"#
        let world = try JSONDecoder().decode(WorldSettings.self, from: Data(saved.utf8))
        #expect(world.timeOfDay == .followClock && world.wind && !world.lightning && world.picnic == .hamper)
        #expect(WorldSettings() == WorldSettings(sunTimes: true, moonPhase: true, clouds: true, wind: true, rainAndSnow: true, lightning: true, grassColor: true))
        #expect(!WorldSettings().realWeather)
    }

    @Test("the meadow shown: the Default until one of yours is chosen; kept by its file's name; missing in older settings")
    func meadow() throws {
        #expect(WorldSettings().meadow == nil)
        let old = #"{"flagSize":"large","map":"meadow","picnic":"spread","realWeather":false,"timeOfDay":"night"}"#
        #expect(try JSONDecoder().decode(WorldSettings.self, from: Data(old.utf8)).meadow == nil)
        let suite = "WorldSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WorldSettings(meadow: "My Meadow.whiskrmeadow").write(to: defaults)
        #expect(WorldSettings.read(from: defaults).meadow == "My Meadow.whiskrmeadow")
        let stray = #"{"meadow":42,"picnic":"spread"}"#
        let world = try JSONDecoder().decode(WorldSettings.self, from: Data(stray.utf8))
        #expect(world.meadow == nil && world.picnic == .spread)
        #expect(try JSONDecoder().decode(WorldSettings.self, from: Data(#"{"meadow":""}"#.utf8)).meadow == nil)
    }
}
