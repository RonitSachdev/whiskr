import Foundation

/// Settings › World: how the meadow looks and behaves. Kept as one value in the user defaults.
public struct WorldSettings: Equatable, Sendable, Codable {
    /// The worlds to choose from. Only the meadow exists so far; the settings list whatever is here.
    public enum Map: String, Codable, Sendable, CaseIterable, Identifiable {
        case meadow
        public var id: String { rawValue }
    }

    public enum TimeOfDay: String, Codable, Sendable, CaseIterable, Identifiable {
        case followClock, day, night
        public var id: String { rawValue }
    }

    /// What is laid out on each blanket. One tidy spread beside the hamper, never scattered.
    public enum Picnic: String, Codable, Sendable, CaseIterable, Identifiable {
        case nothing, hamper, spread
        public var id: String { rawValue }
    }

    public enum FlagSize: String, Codable, Sendable, CaseIterable, Identifiable {
        case small, medium, large
        public var id: String { rawValue }
        /// As a multiple of the usual size.
        public var scale: Double {
            switch self { case .small: 0.8; case .medium: 1; case .large: 1.3 }
        }
    }

    /// Where you are, rounded to two decimals (about a kilometre): all that is sent to the weather service.
    public struct Place: Equatable, Sendable, Codable {
        public let latitude: Double
        public let longitude: Double
        public init(latitude: Double, longitude: Double) {
            self.latitude = (latitude * 100).rounded() / 100
            self.longitude = (longitude * 100).rounded() / 100
        }
    }

    public var map: Map
    public var timeOfDay: TimeOfDay
    public var picnic: Picnic
    public var flagSize: FlagSize
    /// The meadow shows the weather where you are.
    public var realWeather: Bool
    /// Where you were found the last time it was asked, kept so it is asked only once.
    public var place: Place?

    // What of the real world the meadow shows, each on its own; all on until turned off. The weather's
    // count only while real weather is on.
    /// Following the clock, dawn, day, dusk and night come with the real sunrise and sunset (worked out on
    /// this Mac for `place`, or a place guessed from the time zone), not at fixed hours.
    public var sunTimes: Bool
    /// The moon waxes and wanes as the real one does, and full-moon nights are lighter.
    public var moonPhase: Bool
    /// Cloud greys the sky and dims the sun; fog and haze close in.
    public var clouds: Bool
    /// The wind's strength, direction and gusts.
    public var wind: Bool
    /// Rain or snow, light to heavy.
    public var rainAndSnow: Bool
    /// Sheet lightning in a thunderstorm.
    public var lightning: Bool
    /// The grass pales in the cold and yellows in the heat.
    public var grassColor: Bool

    /// How often the weather is looked up while it is on.
    public static let weatherInterval: TimeInterval = 15 * 60

    public init(map: Map = .meadow, timeOfDay: TimeOfDay = .followClock, picnic: Picnic = .hamper, flagSize: FlagSize = .medium,
                realWeather: Bool = false, place: Place? = nil, sunTimes: Bool = true, moonPhase: Bool = true, clouds: Bool = true,
                wind: Bool = true, rainAndSnow: Bool = true, lightning: Bool = true, grassColor: Bool = true) {
        self.map = map
        self.timeOfDay = timeOfDay
        self.picnic = picnic
        self.flagSize = flagSize
        self.realWeather = realWeather
        self.place = place
        self.sunTimes = sunTimes
        self.moonPhase = moonPhase
        self.clouds = clouds
        self.wind = wind
        self.rainAndSnow = rainAndSnow
        self.lightning = lightning
        self.grassColor = grassColor
    }

    // MARK: Saving

    private enum CodingKeys: String, CodingKey {
        case map, timeOfDay, picnic, flagSize, realWeather, place, sunTimes, moonPhase, clouds, wind, rainAndSnow, lightning, grassColor
    }

    /// Reads what it can: anything missing or no longer known (a map since removed) keeps its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let value = try? container.decodeIfPresent(Map.self, forKey: .map) { map = value }
        if let value = try? container.decodeIfPresent(TimeOfDay.self, forKey: .timeOfDay) { timeOfDay = value }
        if let value = try? container.decodeIfPresent(Picnic.self, forKey: .picnic) { picnic = value }
        if let value = try? container.decodeIfPresent(FlagSize.self, forKey: .flagSize) { flagSize = value }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .realWeather) { realWeather = value }
        if let value = try? container.decodeIfPresent(Place.self, forKey: .place) { place = value }
        for (key, path) in [(CodingKeys.sunTimes, \Self.sunTimes), (.moonPhase, \.moonPhase), (.clouds, \.clouds), (.wind, \.wind),
                            (.rainAndSnow, \.rainAndSnow), (.lightning, \.lightning), (.grassColor, \.grassColor)] {
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { self[keyPath: path] = value }
        }
    }

    public static let defaultsKey = "world"

    public static func read(from defaults: UserDefaults) -> WorldSettings {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(WorldSettings.self, from: $0) } ?? WorldSettings()
    }

    public func write(to defaults: UserDefaults) {
        // Keys in a fixed order, so the same settings are always the same bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
