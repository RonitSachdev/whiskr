import AppKit
import Combine
import MeadowScene
import SwiftUI
import WhiskrKit
import WhiskrMeadow

/// Settings › Meadow: My Meadows' cards (`MeadowLibraryView`), the meadow's time of day with the real sun and moon, real weather and a switch for each
/// thing it shows, picnic things, flag size and, once there is more than one, the map.
struct WorldSettingsView: View {
    @Bindable var store: WorldStore
    private let library = MeadowLibrary.shared
    /// The Settings window, for the panels and questions My Meadows shows.
    @State private var host = HostWindow()

    var body: some View {
        Form {
            yourMeadow

            // A choice of one is no choice: the map shows once there is a second to choose.
            if WorldSettings.Map.allCases.count > 1 {
                Section {
                    Picker("Map", selection: $store.settings.map) {
                        ForEach(WorldSettings.Map.allCases) { map in
                            mapName(map).tag(map)
                        }
                    }
                } footer: {
                    Text("The world your workspaces live in.").font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Time of day", selection: $store.settings.timeOfDay) {
                    Text("Follow the Clock").tag(WorldSettings.TimeOfDay.followClock)
                    Text("Always Day").tag(WorldSettings.TimeOfDay.day)
                    Text("Always Night").tag(WorldSettings.TimeOfDay.night)
                }
                .pickerStyle(.segmented)
                Toggle("Real sunrise and sunset", isOn: $store.settings.sunTimes)
                sunStatus
                Toggle("Moon phase", isOn: $store.settings.moonPhase)
                Toggle("Lamps light at night", isOn: $store.settings.lamps)
            } footer: {
                Text("Worked out on this Mac for where real weather last found you, or else for your time zone. Nothing is sent and nothing is asked.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Real weather where you are", isOn: $store.settings.realWeather)
                weatherStatus
                Group {
                    Toggle("Clouds and fog", isOn: $store.settings.clouds)
                    Toggle(isOn: $store.settings.wind) { Text("Wind", comment: "Settings › Meadow: the real wind in the grass") }
                    Toggle("Rain and snow", isOn: $store.settings.rainAndSnow)
                    Toggle("Lightning", isOn: $store.settings.lightning)
                    Toggle("Grass color from the temperature", isOn: $store.settings.grassColor)
                }
                .disabled(!store.settings.realWeather)
                if !store.settings.realWeather {
                    Text("These show real weather, which is off.").font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Real weather asks for your location once. It is rounded to about a kilometer and sent to Open-Meteo, a free weather service, in one request every 15 minutes while real weather is on. Lightning is a soft, rare glow, never with Reduce Motion or the meadow's animation off.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "Animate the meadow"), isOn: $store.animatesMeadow)
            } footer: {
                Text(String(localized: "Off, the grass, butterflies and cats' little movements hold still, and there is no lightning. Cats still change as Claude does. Also in View › Animate Meadow."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Picker("Picnic things", selection: $store.settings.picnic) {
                    Text("Nothing", comment: "Picnic things on each blanket").tag(WorldSettings.Picnic.nothing)
                    Text("Just the hamper").tag(WorldSettings.Picnic.hamper)
                    Text("Hamper and a few things").tag(WorldSettings.Picnic.spread)
                }
                .pickerStyle(.radioGroup)
                Picker("Name flags", selection: $store.settings.flagSize) {
                    Text("Small", comment: "Size of the name flags").tag(WorldSettings.FlagSize.small)
                    Text("Medium", comment: "Size of the name flags").tag(WorldSettings.FlagSize.medium)
                    Text("Large", comment: "Size of the name flags").tag(WorldSettings.FlagSize.large)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    /// Your Meadow: My Meadows' cards (the Default and yours, the one shown checked), New Meadow, Import… and Edit
    /// Meadow…. Choosing one is a step Edit › Undo takes back while the meadow is edited; choosing the Default is
    /// Revert to Default.
    private var yourMeadow: some View {
        Section {
            MeadowLibraryView(window: { host.window })
        } header: {
            Text(String(localized: "Your Meadow", comment: "Settings › Meadow: the section choosing and editing the meadow"))
        } footer: {
            Group {
                if let unreadable = library.unreadable {
                    Text(String(localized: "“\(library.displayName(unreadable))” couldn't be read and is kept as it was. The Default is shown.",
                                comment: "Settings › Meadow: the meadow chosen could not be read"))
                } else if let removed = library.removedOnDisk {
                    Text(String(localized: "“\(library.displayName(removed))” was moved out of the Meadows folder, so the Default is shown.",
                                comment: "Settings › Meadow: the meadow shown was removed by something else"))
                } else {
                    Text(String(localized: "Your meadows are saved as you change them, as .whiskrmeadow files you can share. The Default never changes: your first change makes a copy of it, My Meadow. Drop a meadow file here to add it.",
                                comment: "Settings › Meadow: how meadows are kept"))
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .background(HostWindowReader(host: host))
    }

    private func mapName(_ map: WorldSettings.Map) -> Text {
        switch map {
        case .meadow: Text("Meadow", comment: "The meadow map")
        }
    }

    /// Today's sunrise and sunset where the sun is reckoned, while the meadow follows it.
    @ViewBuilder private var sunStatus: some View {
        if store.settings.timeOfDay != .followClock {
            Text("Always Day and Always Night keep to their hour.").font(.callout).foregroundStyle(.secondary)
        } else if store.settings.sunTimes {
            SunToday(place: MeadowMapping.place(store.settings, timeZone: .autoupdatingCurrent), clock: { [store] in store.now })
        }
    }

    @ViewBuilder private var weatherStatus: some View {
        if store.askingForLocation {
            Label("Waiting for you to allow location access…", systemImage: "location")
                .font(.callout).foregroundStyle(.secondary)
        } else if store.weatherProblem == .locationRefused {
            Label("Weather turned itself off: location access was refused. Allow Whiskr in System Settings › Privacy & Security › Location Services, then turn weather on again.",
                  systemImage: "location.slash")
                .font(.callout).foregroundStyle(.secondary)
        } else if store.settings.realWeather {
            if store.weatherProblem == .locationUnavailable {
                Label("Could not find where you are yet; trying again in a while.", systemImage: "location")
                    .font(.callout).foregroundStyle(.secondary)
            } else if store.weatherProblem == .serviceUnavailable {
                Label("The weather service did not answer; trying again in 15 minutes.", systemImage: "exclamationmark.icloud")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let weather = store.weather, let updated = store.weatherUpdated {
                let temperature = Measurement(value: Double(weather.temperatureC), unit: UnitTemperature.celsius)
                    .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
                Label("\(weather.thunder ? String(localized: "Thunderstorm", comment: "Weather") : skyName(weather.sky)), \(temperature) · updated \(updated, format: .relative(presentation: .named))", systemImage: "cloud.sun")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func skyName(_ sky: MeadowWeather.Sky) -> String {
        switch sky {
        case .clear: String(localized: "Clear", comment: "Weather")
        case .cloudy: String(localized: "Cloudy", comment: "Weather")
        case .fog: String(localized: "Fog", comment: "Weather")
        case .rain: String(localized: "Rain", comment: "Weather")
        case .snow: String(localized: "Snow", comment: "Weather")
        }
    }
}

/// "Today: sunrise …, sunset …" for a place, worked out again when the day changes, the Mac's time zone
/// changes or the Mac wakes, while it shows (a change of place comes with the settings).
private struct SunToday: View {
    let place: MeadowPlace
    /// What day it is (the debug harness's stopped clock, else now), read only when it may have changed.
    let clock: @MainActor () -> Date
    @State private var today = Date()
    var body: some View {
        Group {
            switch place.sunDay(containing: today, in: .autoupdatingCurrent) {
            case .risesAndSets(let rise, let set):
                Label("Today: sunrise \(rise.formatted(date: .omitted, time: .shortened)), sunset \(set.formatted(date: .omitted, time: .shortened))",
                      systemImage: "sunrise")
            case .alwaysUp:
                Label("The sun does not set today.", systemImage: "sun.max")
            case .alwaysDown:
                Label("The sun does not rise today.", systemImage: "moon.stars")
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        .onAppear { today = clock() }
        #if DEBUG
        .task(id: today) { SunTodayProbe.shownDay = today }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in today = clock() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in today = clock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)) { _ in today = clock() }
    }
}

#if DEBUG
/// The day Settings' sunrise line was last worked out for (`--perf-flows sky` checks it follows the day).
@MainActor enum SunTodayProbe {
    static var shownDay: Date?
}
#endif
