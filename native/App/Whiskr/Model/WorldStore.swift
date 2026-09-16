import AppKit
import CoreLocation
import Foundation
import MeadowScene
import Observation
import WhiskrKit

/// Settings › Meadow, kept in the user defaults, and the weather where you are when you want it.
///
/// Your location is asked for once, when you turn real weather on (never at launch, and never for the
/// sun). It is rounded to about a kilometre, remembered, and sent to Open-Meteo (a free weather service that
/// needs no account) in one request every 15 minutes while weather is on, as the web version does
/// (`src/meadow/weather.ts`). If you say no, weather turns itself off and Settings says why. Sunrise,
/// sunset and the moon are worked out on this Mac (`MeadowMapping.place`): they send nothing.
@Observable
final class WorldStore: NSObject {
    static let shared = WorldStore()

    enum WeatherProblem: Equatable {
        /// Location access was refused: weather has turned itself off.
        case locationRefused
        /// Where you are could not be found yet.
        case locationUnavailable
        /// The weather service did not answer; the last weather is kept.
        case serviceUnavailable
    }

    var settings: WorldSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.write(to: AppPlaces.defaults)
            if settings.realWeather != oldValue.realWeather { weatherSwitched() }
        }
    }
    /// View › Animate Meadow and Settings › Meadow: off, the meadow's own motion (grass, butterflies, a
    /// cat's fidgets) holds still while cats still change as Claude does (WCAG 2.2.2's pause). Until
    /// chosen it follows Reduce Motion.
    var animatesMeadow: Bool {
        get {
            access(keyPath: \.animatesMeadow)
            return AppPlaces.defaults.object(forKey: Self.animateKey) as? Bool ?? !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        set {
            withMutation(keyPath: \.animatesMeadow) { AppPlaces.defaults.set(newValue, forKey: Self.animateKey) }
        }
    }
    private static let animateKey = "animateMeadow"
    /// The latest conditions; nil until the first answer, and while weather is off.
    private(set) var weather: MeadowWeather?
    private(set) var weatherProblem: WeatherProblem?
    /// When the weather was last looked up successfully.
    private(set) var weatherUpdated: Date?
    /// Waiting for you to answer the location question.
    private(set) var askingForLocation = false

    @ObservationIgnored private var locator: CLLocationManager?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fetching: Task<Void, Never>?

    private override init() {
        settings = WorldSettings.read(from: AppPlaces.defaults)
        super.init()
    }

    /// At launch: weather that was on carries on, from where you were last found, without asking anything.
    func start() {
        guard settings.realWeather else { return }
        startTimer()
        if let place = settings.place { fetch(at: place) }
        // Already allowed: find where you are now, quietly. Never asks at launch.
        let status = CLLocationManager().authorizationStatus
        if status == .authorizedAlways { locate() }
    }

    #if DEBUG
    /// Debug builds: where you are is given rather than asked (`--weather-place`, `--weather-fixture`), so
    /// nothing ever asks the system for your location.
    @ObservationIgnored private var placeGiven = false
    /// The weather is given too: nothing is fetched.
    @ObservationIgnored private var weatherGiven = false
    /// Debug builds: the meadow's clock stopped at this moment (`--sky-moment`), for the sun and moon.
    var clockStoppedAt: Date?

    /// `--weather-place <lat>,<lon>`: real weather for a place, fetched from Open-Meteo, without asking for
    /// your location, so the path can be checked from the command line.
    func useFixedPlace(_ place: WorldSettings.Place) {
        placeGiven = true
        settings.place = place
        if !settings.realWeather { settings.realWeather = true } else { fetch(at: place) }
    }

    /// `--weather-fixture <file>` and the checks: these conditions, as if Open-Meteo had just answered with
    /// them, with no request made and no location asked for. Weather is turned on for them.
    func useWeather(_ weather: MeadowWeather) {
        placeGiven = true
        weatherGiven = true
        if !settings.realWeather { settings.realWeather = true }
        timer?.invalidate()
        timer = nil
        fetching?.cancel()
        self.weather = weather
        weatherUpdated = Date()
        weatherProblem = nil
    }
    #else
    private let placeGiven = false
    #endif

    /// The time the meadow and Settings go by: now (a debug run's stopped clock, when it has one).
    var now: Date {
        #if DEBUG
        clockStoppedAt ?? Date()
        #else
        Date()
        #endif
    }

    // MARK: Weather on and off

    private func weatherSwitched() {
        if settings.realWeather {
            weatherProblem = nil
            startTimer()
            if let place = settings.place { fetch(at: place) }
            if !placeGiven { locateAsking() }
        } else {
            timer?.invalidate()
            timer = nil
            fetching?.cancel()
            weather = nil
            askingForLocation = false
            if weatherProblem != .locationRefused { weatherProblem = nil }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: WorldSettings.weatherInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, let place = self.settings.place else { return }
                self.fetch(at: place)
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Where you are

    private func manager() -> CLLocationManager {
        if let locator { return locator }
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.delegate = self
        locator = manager
        return manager
    }

    /// Turning weather on: the one moment the question is asked, if it has not been answered before.
    private func locateAsking() {
        let manager = manager()
        switch manager.authorizationStatus {
        case .notDetermined:
            askingForLocation = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            refused()
        default:
            manager.requestLocation()
        }
    }

    private func locate() {
        manager().requestLocation()
    }

    private func refused() {
        askingForLocation = false
        weatherProblem = .locationRefused
        if settings.realWeather { settings.realWeather = false }
    }

    // MARK: The weather service

    private func fetch(at place: WorldSettings.Place) {
        #if DEBUG
        if weatherGiven { return }
        #endif
        fetching?.cancel()
        let url = MeadowWeather.openMeteoURL(latitude: place.latitude, longitude: place.longitude)
        fetching = Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let answer = try? await URLSession.shared.data(for: request)
            guard !Task.isCancelled, let self, self.settings.realWeather else { return }
            if let (data, response) = answer, (response as? HTTPURLResponse)?.statusCode == 200, let weather = MeadowWeather(openMeteo: data) {
                if self.weather != weather { self.weather = weather }
                self.weatherUpdated = Date()
                if self.weatherProblem == .serviceUnavailable { self.weatherProblem = nil }
            } else {
                self.weatherProblem = .serviceUnavailable
            }
        }
    }
}

extension WorldStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard settings.realWeather || askingForLocation else { return }
            switch status {
            case .notDetermined:
                break
            case .denied, .restricted:
                refused()
            default:
                askingForLocation = false
                locate()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let place = WorldSettings.Place(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        MainActor.assumeIsolated {
            guard settings.realWeather else { return }
            if weatherProblem == .locationUnavailable { weatherProblem = nil }
            let moved = settings.place != place
            if moved { settings.place = place }
            if moved || weather == nil { fetch(at: place) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated {
            guard settings.realWeather else { return }
            if denied {
                refused()
            } else if settings.place == nil {
                weatherProblem = .locationUnavailable
            }
        }
    }
}
