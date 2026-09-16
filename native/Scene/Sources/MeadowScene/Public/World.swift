import Foundation
import simd

// What the meadow shows, as plain values. The app maps its own model onto these once per change and
// hands the whole thing to `MeadowView.world`; the view works out what moved, arrived or left.
//
//   machine  ──  a clearing of its own, across a stream from the others
//   space    ──  a mown patch of grass holding its blankets (one folder or repository)
//   blanket  ──  one tab: a gingham blanket with a name flag
//   agent    ──  a cat on the blanket; helpers are smaller cats huddled by whoever launched them
//   lantern  ──  a plain terminal pane: lit while running, dark when finished, red if it failed

/// What an agent is doing right now. The same words as `shared/protocol.ts` and the app's `Activity`.
public enum AgentActivity: String, CaseIterable, Sendable, Hashable {
    case awake, reading, editing, running, searching, thinking, tidying, supervising, asking, napping, error
    /// Idle and seen (the app's sidebar): lying as a loaf, paws tucked under, breathing.
    case idle
}

/// A colour given in sRGB, 0…1, as designers write it.
public struct MeadowColor: Hashable, Sendable {
    public var red: Float, green: Float, blue: Float
    public init(red: Float, green: Float, blue: Float) { self.red = red; self.green = green; self.blue = blue }
    public init(hex: UInt32) {
        red = Float((hex >> 16) & 255) / 255; green = Float((hex >> 8) & 255) / 255; blue = Float(hex & 255) / 255
    }
    /// The blanket colours of the web version, in the order accounts take them (`village/colors.ts`).
    public static let accounts: [MeadowColor] = [0xf0606e, 0x4f9be8, 0xf2b632, 0x9b7fe8, 0x2fb39a, 0xf08a3c].map { MeadowColor(hex: $0) }
    /// The account colour for the n-th account, wrapping round.
    public static func account(_ index: Int) -> MeadowColor { accounts[((index % accounts.count) + accounts.count) % accounts.count] }

    var linearRGB: Vec3 {
        func c(_ s: Float) -> Float { s < 0.04045 ? s * 0.0773993808 : pow(s * 0.9478672986 + 0.0521327014, 2.4) }
        return Vec3(c(red), c(green), c(blue))
    }
    var hexString: String { String(format: "#%02x%02x%02x", Int(red * 255 + 0.5), Int(green * 255 + 0.5), Int(blue * 255 + 0.5)) }
}

public struct MeadowAgent: Identifiable, Hashable, Sendable {
    /// Unique within its blanket. The main agent of a Claude session is conventionally "main".
    public var id: String
    /// Who launched it; nil for a blanket's own agent. Helpers huddle by whoever launched them.
    public var parentID: String?
    public var activity: AgentActivity
    /// Waiting on you (a permission, a question): the cat asks with a red bubble whatever it was doing.
    public var needsYou: Bool
    /// Finished a turn you have not looked at yet: the cat sits up facing you with a check bubble.
    public var doneUnseen: Bool
    /// The last turn stopped on an error you have not seen: the cat shows the error pose.
    public var failed: Bool
    /// A short name for hover and accessibility, e.g. "Explore" or the task.
    public var name: String

    public init(id: String, parentID: String? = nil, activity: AgentActivity = .awake, needsYou: Bool = false,
                doneUnseen: Bool = false, failed: Bool = false, name: String = "") {
        self.id = id; self.parentID = parentID; self.activity = activity; self.needsYou = needsYou
        self.doneUnseen = doneUnseen; self.failed = failed; self.name = name
    }
}

public struct MeadowLantern: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        /// Lit: the command in the pane is still running.
        case running
        /// Dark: it finished (exit 0) or the shell is idle.
        case finished
        /// Red: it exited with an error.
        case failed
    }
    public var id: String
    public var title: String
    public var state: State
    public init(id: String, title: String = "", state: State = .running) { self.id = id; self.title = title; self.state = state }
}

public struct MeadowBlanket: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        /// Owned by the app and alive.
        case live
        /// Started outside the app: drawn faded, with a hollow dot on its flag (watch-only).
        case watchOnly
        /// The session ended: its cats pop away, leaving the empty blanket.
        case ended
    }
    public var id: String
    public var title: String
    public var color: MeadowColor
    public var state: State
    /// Launch order, the blanket's own agent first.
    public var agents: [MeadowAgent]
    public var lanterns: [MeadowLantern]
    /// A second, quieter line on the flag after the title: the workspace's git branch (nil outside a
    /// repository), shown after a small branch glyph.
    public var detail: String?
    /// Kept at hand by the user: a small pin at the leading end of the flag.
    public var pinned: Bool
    /// The blanket this one belongs to (a git worktree's, its repository's): it is laid beside that one,
    /// joined to it by a little path of stepping stones. Nil, or an id not in the world, for none.
    public var joinedTo: String?

    public init(id: String, title: String, color: MeadowColor, state: State = .live, agents: [MeadowAgent] = [], lanterns: [MeadowLantern] = [],
                detail: String? = nil, pinned: Bool = false, joinedTo: String? = nil) {
        self.id = id; self.title = title; self.color = color; self.state = state; self.agents = agents; self.lanterns = lanterns
        self.detail = detail; self.pinned = pinned; self.joinedTo = joinedTo
    }
}

public struct MeadowSpace: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var blankets: [MeadowBlanket]
    public init(id: String, name: String, blankets: [MeadowBlanket]) { self.id = id; self.name = name; self.blankets = blankets }
}

public struct MeadowMachine: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The Mac the app runs on sits on the near side of every stream.
    public var isLocal: Bool
    public var spaces: [MeadowSpace]
    public init(id: String, name: String, isLocal: Bool = true, spaces: [MeadowSpace]) {
        self.id = id; self.name = name; self.isLocal = isLocal; self.spaces = spaces
    }
}

/// Everything in the meadow.
public struct MeadowWorld: Hashable, Sendable {
    public var machines: [MeadowMachine]
    public init(machines: [MeadowMachine] = []) { self.machines = machines }

    public static let empty = MeadowWorld()

    /// Every blanket, in machine, space, blanket order.
    public var blankets: [MeadowBlanket] { machines.flatMap { $0.spaces.flatMap(\.blankets) } }
}

/// Something in the meadow that can be pointed at or chosen.
public enum MeadowItem: Hashable, Sendable {
    case blanket(String)
    case cat(blanket: String, agent: String)
    case lantern(blanket: String, lantern: String)

    public var blanketID: String {
        switch self {
        case .blanket(let id), .cat(let id, _), .lantern(let id, _): id
        }
    }
}

/// Live conditions where you are, for the meadow to match. `MeadowWeather(openMeteo:)` reads the free
/// Open-Meteo service's answer; fetching it (and asking where you are) is the app's business.
public struct MeadowWeather: Hashable, Sendable {
    public enum Sky: String, Hashable, Sendable { case clear, cloudy, fog, rain, snow }
    public var sky: Sky
    /// How much of the sky is cloud, 0…1.
    public var cover: Float
    public var windKmh: Float
    public var temperatureC: Float
    /// Where the wind blows from, degrees clockwise from north (as weather services give it); nil unknown.
    public var windFromDegrees: Float?
    /// The strongest gusts, km/h; nil unknown.
    public var gustKmh: Float?
    /// How hard rain or snow is falling, 0 (a trace) … 1 (heavy). Only read while the sky is rain or snow.
    public var intensity: Float
    /// A thunderstorm: sheet lightning now and then.
    public var thunder: Bool
    /// How far one can see, metres; nil unknown. Under 10 km the far meadow goes hazy.
    public var visibilityMeters: Float?

    public init(sky: Sky, cover: Float, windKmh: Float, temperatureC: Float, windFromDegrees: Float? = nil, gustKmh: Float? = nil,
                intensity: Float = 0.5, thunder: Bool = false, visibilityMeters: Float? = nil) {
        self.sky = sky; self.cover = cover; self.windKmh = windKmh; self.temperatureC = temperatureC
        self.windFromDegrees = windFromDegrees; self.gustKmh = gustKmh; self.intensity = min(1, max(0, intensity)); self.thunder = thunder
        self.visibilityMeters = visibilityMeters
    }

    /// What is asked for: one request with everything the meadow shows.
    static let openMeteoFields = ["temperature_2m", "weather_code", "cloud_cover", "wind_speed_10m", "wind_direction_10m", "wind_gusts_10m",
                                  "precipitation", "rain", "showers", "snowfall", "visibility"]

    /// The request for current conditions at a place (rounded by the caller as it sees fit).
    public static func openMeteoURL(latitude: Double, longitude: Double) -> URL {
        URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=\(openMeteoFields.joined(separator: ","))")!
    }

    /// Reads Open-Meteo's JSON answer (weather.ts `readWeather`); nil if it makes no sense. Anything but the
    /// temperature may be missing: it is then left unknown.
    public init?(openMeteo data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.floatValue, temperature.isFinite else { return nil }
        func number(_ key: String) -> Float? { (current[key] as? NSNumber)?.floatValue.nonNegativeFinite }
        let code = (current["weather_code"] as? NSNumber)?.intValue ?? 0
        let sky = Self.sky(wmo: code)
        // Rain by the millimetre an hour (showers are rain too) and snow by the centimetre, each against the
        // service's own word for it in the code: whichever says it is falling harder.
        let rain = (number("rain") ?? 0) + (number("showers") ?? 0)
        let amount: Float = switch sky {
        case .snow: Self.snowIntensity(cmPerHour: number("snowfall") ?? (number("precipitation") ?? 0) * 0.7)
        case .rain: Self.rainIntensity(mmPerHour: rain > 0 ? rain : number("precipitation") ?? 0)
        default: 0
        }
        self.init(sky: sky, cover: min(1, (number("cloud_cover") ?? 0) / 100), windKmh: number("wind_speed_10m") ?? 0, temperatureC: temperature,
                  windFromDegrees: number("wind_direction_10m"), gustKmh: number("wind_gusts_10m"),
                  intensity: max(amount, Self.intensity(wmo: code)), thunder: (95...99).contains(code), visibilityMeters: number("visibility"))
    }

    /// Open-Meteo reports conditions as WMO weather codes.
    public static func sky(wmo code: Int) -> Sky {
        if code <= 2 { return .clear }
        if code == 3 { return .cloudy }
        if code == 45 || code == 48 { return .fog }
        if (71...77).contains(code) || code == 85 || code == 86 { return .snow }
        return .rain
    }

    /// How hard the code says it is falling: drizzle and slight rain or snow light, then moderate, then heavy.
    static func intensity(wmo code: Int) -> Float {
        switch code {
        case 51, 56, 77: 0.15
        case 53, 61, 66, 71, 80, 85: 0.35
        case 55, 57: 0.5
        case 63, 73, 81, 95: 0.65
        case 96: 0.8
        case 65, 67, 75, 82, 86, 99: 1
        default: 0
        }
    }

    /// Rain: light under 2.5 mm an hour, heavy past 7.6 (the meteorologists' bands), 1 by 10.
    static func rainIntensity(mmPerHour: Float) -> Float { min(1, log2(1 + max(0, mmPerHour)) / log2(11)) }
    /// Snow: light under half a centimetre an hour, heavy past two and a half.
    static func snowIntensity(cmPerHour: Float) -> Float { min(1, log2(1 + 4 * max(0, cmPerHour)) / log2(11)) }
}

private extension Float {
    var nonNegativeFinite: Float? { isFinite && self >= 0 ? self : nil }
}

/// The host app's interface colours, for what the scene draws as interface rather than as world: the
/// name flags (a pill in `surface` with `ink` text, inverted when chosen), the ring round what is chosen
/// (by day; after dark it keeps its warm night colours), the red of the "needs you" bubble and the
/// keyboard focus ring (the system accent colour, `NSColor.controlAccentColor`).
public struct MeadowChrome: Hashable, Sendable {
    public var surface: MeadowColor
    public var ink: MeadowColor
    public var alert: MeadowColor
    public var focus: MeadowColor
    public init(surface: MeadowColor, ink: MeadowColor, alert: MeadowColor, focus: MeadowColor = MeadowColor(hex: 0x007aff)) {
        self.surface = surface; self.ink = ink; self.alert = alert; self.focus = focus
    }
    /// The design's own neutral palette (off-white, charcoal, the warm red).
    public static let standard = MeadowChrome(surface: MeadowColor(hex: 0xfcfcfb), ink: MeadowColor(hex: 0x232327), alert: MeadowColor(hex: 0xd4433a))
}

public struct MeadowSettings: Hashable, Sendable {
    public enum Map: String, Hashable, Sendable, CaseIterable { case meadow }
    public enum TimeOfDay: Hashable, Sendable {
        case followClock
        case day
        case night
        /// A fixed hour, 0…24, for previews and tests.
        case hour(Double)
        /// The clock stopped at this moment: the light, sun and moon as they are then, for previews and tests.
        case instant(Date)
    }

    /// What of the real world the meadow shows. Each can be left out on its own; the weather's only while
    /// there is weather.
    public struct Effects: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Following the clock, dawn, day, dusk and night come with the real sun over `place` (else at
        /// fixed hours).
        public static let sunTimes = Effects(rawValue: 1 << 0)
        /// The moon waxes and wanes, rises and sets as the real one does over `place`, its lit edge toward the
        /// sun, and moonlit nights are lighter (else a steady full moon, every night).
        public static let moonPhase = Effects(rawValue: 1 << 1)
        /// Cloud greys the sky and dims the sun; fog and haze close in.
        public static let clouds = Effects(rawValue: 1 << 2)
        /// The wind's strength, direction and gusts in the grass, flowers, seeds and rain.
        public static let wind = Effects(rawValue: 1 << 3)
        /// Rain or snow falling, light to heavy.
        public static let rainAndSnow = Effects(rawValue: 1 << 4)
        /// Soft sheet lightning in a thunderstorm (never with Reduce Motion or the animation off).
        public static let lightning = Effects(rawValue: 1 << 5)
        /// The grass pales in the cold and yellows in the heat.
        public static let grassColor = Effects(rawValue: 1 << 6)
        public static let all: Effects = [.sunTimes, .moonPhase, .clouds, .wind, .rainAndSnow, .lightning, .grassColor]
    }
    public enum Picnic: String, Hashable, Sendable, CaseIterable {
        /// Nothing laid out.
        case none
        /// Just the closed hamper (the default).
        case hamper
        /// The hamper with a few things unpacked beside it.
        case spread
    }

    /// How blankets are laid out: a loose picnic for a whole window, or one column in the given order
    /// for a sidebar (scrolled with the scroll gesture; dragging still turns the view).
    public enum Arrangement: String, Hashable, Sendable, CaseIterable {
        case picnic
        case column
    }

    public var map: Map
    public var arrangement: Arrangement
    public var timeOfDay: TimeOfDay
    /// nil for a clear, mild day.
    public var weather: MeadowWeather?
    /// Where the sun and moon are reckoned for (nil: dawn, day, dusk and night at fixed hours, and the
    /// meadow's own steady full moon).
    public var place: MeadowPlace?
    public var effects: Effects
    public var picnic: Picnic
    /// How large name flags are drawn, as a multiple of the usual size.
    public var flagSize: Float
    /// The host app's theme colours for flags, rings and the "needs you" bubble.
    public var chrome: MeadowChrome

    public init(map: Map = .meadow, arrangement: Arrangement = .picnic, timeOfDay: TimeOfDay = .followClock, weather: MeadowWeather? = nil,
                place: MeadowPlace? = nil, effects: Effects = .all, picnic: Picnic = .hamper, flagSize: Float = 1, chrome: MeadowChrome = .standard) {
        self.map = map; self.arrangement = arrangement; self.timeOfDay = timeOfDay; self.weather = weather; self.place = place
        self.effects = effects; self.picnic = picnic; self.flagSize = flagSize; self.chrome = chrome
    }
}
