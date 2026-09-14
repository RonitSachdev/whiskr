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

    /// How often the weather is looked up while it is on.
    public static let weatherInterval: TimeInterval = 15 * 60

    public init(map: Map = .meadow, timeOfDay: TimeOfDay = .followClock, picnic: Picnic = .hamper, flagSize: FlagSize = .medium,
                realWeather: Bool = false, place: Place? = nil) {
        self.map = map
        self.timeOfDay = timeOfDay
        self.picnic = picnic
        self.flagSize = flagSize
        self.realWeather = realWeather
        self.place = place
    }

    // MARK: Saving

    private enum CodingKeys: String, CodingKey { case map, timeOfDay, picnic, flagSize, realWeather, place }

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
