import MeadowScene
import SwiftUI
import WhiskrKit

/// Settings › Meadow: the meadow's time of day, real weather, picnic things, flag size and, once there is
/// more than one, the map.
struct WorldSettingsView: View {
    @Bindable var store: WorldStore

    var body: some View {
        Form {
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
                Toggle("Real weather where you are", isOn: $store.settings.realWeather)
                weatherStatus
            } footer: {
                Text("Weather asks for your location once. It is rounded to about a kilometer and sent to Open-Meteo, a free weather service, every 15 minutes while weather is on.")
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

    private func mapName(_ map: WorldSettings.Map) -> Text {
        switch map {
        case .meadow: Text("Meadow", comment: "The meadow map")
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
                Label("\(skyName(weather.sky)), \(temperature) · updated \(updated, format: .relative(presentation: .named))", systemImage: "cloud.sun")
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
