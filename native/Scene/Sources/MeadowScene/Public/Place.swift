import Foundation

/// Somewhere on Earth, for the sun and the moon over the meadow: degrees north and east.
public struct MeadowPlace: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = min(90, max(-90, latitude))
        self.longitude = min(180, max(-180, longitude))
    }

    /// One day's sunrise and sunset.
    public enum SunDay: Equatable, Sendable {
        case risesAndSets(rise: Date, set: Date)
        /// Above the horizon all day (the midnight sun).
        case alwaysUp
        /// Below it all day (the polar night).
        case alwaysDown
    }

    /// Sunrise and sunset here on the calendar day that contains `date` in `zone`, worked out on this Mac.
    public func sunDay(containing date: Date, in zone: TimeZone) -> SunDay {
        Sun.day(containing: date, latitude: latitude, longitude: longitude, timeZone: zone)
    }

    /// A guess at where you are from the Mac's time zone alone, for sunrise and sunset when no better place
    /// is known. Never asks anyone anything. A zone in the table below is put at its main city; any other at
    /// the longitude its standard offset implies, and a latitude typical of its region.
    public static func estimate(for zone: TimeZone, at date: Date = Date()) -> MeadowPlace {
        let name = zone.identifier
        if let city = zoneCities[name] { return MeadowPlace(latitude: city.0, longitude: city.1) }
        let standard = Double(zone.secondsFromGMT(for: date)) - zone.daylightSavingTimeOffset(for: date)
        let region = name.split(separator: "/").first.map(String.init) ?? ""
        let latitude: Double = switch region {
        case "Europe": 50
        case "Asia": 32
        case "Africa": 5
        case "Australia": -30
        case "Antarctica": -75
        case "Pacific": -12
        case "Indian": -12
        case "Atlantic": 35
        case "America" where name.contains("Argentina"): -34
        case "America": 35
        default: 40
        }
        return MeadowPlace(latitude: latitude, longitude: standard / 3600 * 15)
    }

    /// Time zones by the main city they are named for (or, for zones named after a region, the city most
    /// people in it live near), in degrees north and east, rounded. Public facts about well-known cities,
    /// covering the zones most Macs are set to.
    static let zoneCities: [String: (Double, Double)] = [
        // Europe
        "Europe/London": (51.51, -0.13), "Europe/Dublin": (53.35, -6.26), "Europe/Lisbon": (38.72, -9.14),
        "Europe/Madrid": (40.42, -3.70), "Europe/Paris": (48.86, 2.35), "Europe/Brussels": (50.85, 4.35),
        "Europe/Amsterdam": (52.37, 4.90), "Europe/Luxembourg": (49.61, 6.13), "Europe/Berlin": (52.52, 13.40),
        "Europe/Zurich": (47.38, 8.54), "Europe/Vienna": (48.21, 16.37), "Europe/Rome": (41.90, 12.50),
        "Europe/Copenhagen": (55.68, 12.57), "Europe/Oslo": (59.91, 10.75), "Europe/Stockholm": (59.33, 18.07),
        "Europe/Helsinki": (60.17, 24.94), "Europe/Tallinn": (59.44, 24.75), "Europe/Riga": (56.95, 24.11),
        "Europe/Vilnius": (54.69, 25.28), "Europe/Warsaw": (52.23, 21.01), "Europe/Prague": (50.08, 14.44),
        "Europe/Budapest": (47.50, 19.04), "Europe/Bratislava": (48.15, 17.11), "Europe/Ljubljana": (46.06, 14.51),
        "Europe/Zagreb": (45.81, 15.98), "Europe/Belgrade": (44.79, 20.45), "Europe/Sarajevo": (43.86, 18.41),
        "Europe/Skopje": (42.00, 21.43), "Europe/Sofia": (42.70, 23.32), "Europe/Bucharest": (44.43, 26.10),
        "Europe/Athens": (37.98, 23.73), "Europe/Istanbul": (41.01, 28.98), "Europe/Kiev": (50.45, 30.52),
        "Europe/Kyiv": (50.45, 30.52), "Europe/Minsk": (53.90, 27.56), "Europe/Chisinau": (47.01, 28.86),
        "Europe/Moscow": (55.76, 37.62), "Europe/Samara": (53.20, 50.15), "Europe/Malta": (35.90, 14.51),
        "Europe/Monaco": (43.74, 7.42), "Europe/Andorra": (42.51, 1.52), "Europe/Tirane": (41.33, 19.82),
        "Atlantic/Reykjavik": (64.15, -21.94), "Atlantic/Canary": (28.12, -15.43), "Atlantic/Azores": (37.74, -25.68),
        "Atlantic/Madeira": (32.65, -16.91),
        // Africa
        "Africa/Cairo": (30.04, 31.24), "Africa/Casablanca": (33.57, -7.59), "Africa/Algiers": (36.75, 3.06),
        "Africa/Tunis": (36.81, 10.18), "Africa/Lagos": (6.52, 3.38), "Africa/Accra": (5.60, -0.19),
        "Africa/Abidjan": (5.36, -4.01), "Africa/Dakar": (14.72, -17.47), "Africa/Nairobi": (-1.29, 36.82),
        "Africa/Addis_Ababa": (9.03, 38.74), "Africa/Kampala": (0.35, 32.58), "Africa/Dar_es_Salaam": (-6.79, 39.21),
        "Africa/Kinshasa": (-4.44, 15.27), "Africa/Luanda": (-8.84, 13.23), "Africa/Johannesburg": (-26.20, 28.05),
        "Africa/Maputo": (-25.97, 32.57), "Africa/Harare": (-17.83, 31.05), "Africa/Lusaka": (-15.39, 28.32),
        "Africa/Khartoum": (15.50, 32.56), "Africa/Windhoek": (-22.56, 17.08),
        // Middle East and Asia
        "Asia/Jerusalem": (31.77, 35.22), "Asia/Tel_Aviv": (32.09, 34.78), "Asia/Beirut": (33.89, 35.50),
        "Asia/Amman": (31.95, 35.93), "Asia/Damascus": (33.51, 36.28), "Asia/Baghdad": (33.31, 44.36),
        "Asia/Riyadh": (24.71, 46.68), "Asia/Kuwait": (29.38, 47.99), "Asia/Qatar": (25.29, 51.53),
        "Asia/Bahrain": (26.23, 50.59), "Asia/Dubai": (25.20, 55.27), "Asia/Muscat": (23.59, 58.41),
        "Asia/Tehran": (35.69, 51.39), "Asia/Baku": (40.41, 49.87), "Asia/Tbilisi": (41.72, 44.79),
        "Asia/Yerevan": (40.18, 44.51), "Asia/Kabul": (34.56, 69.21), "Asia/Karachi": (24.86, 67.01),
        "Asia/Tashkent": (41.30, 69.24), "Asia/Almaty": (43.24, 76.89), "Asia/Bishkek": (42.87, 74.59),
        "Asia/Kolkata": (22.57, 88.36), "Asia/Calcutta": (22.57, 88.36), "Asia/Colombo": (6.93, 79.86),
        "Asia/Kathmandu": (27.72, 85.32), "Asia/Katmandu": (27.72, 85.32), "Asia/Dhaka": (23.81, 90.41),
        "Asia/Thimphu": (27.47, 89.64), "Asia/Yangon": (16.84, 96.17), "Asia/Rangoon": (16.84, 96.17),
        "Asia/Bangkok": (13.76, 100.50), "Asia/Ho_Chi_Minh": (10.82, 106.63), "Asia/Saigon": (10.82, 106.63),
        "Asia/Phnom_Penh": (11.56, 104.93), "Asia/Vientiane": (17.97, 102.63), "Asia/Kuala_Lumpur": (3.14, 101.69),
        "Asia/Singapore": (1.35, 103.82), "Asia/Jakarta": (-6.21, 106.85), "Asia/Makassar": (-5.15, 119.43),
        "Asia/Jayapura": (-2.53, 140.72), "Asia/Manila": (14.60, 120.98), "Asia/Hong_Kong": (22.32, 114.17),
        "Asia/Macau": (22.20, 113.54), "Asia/Taipei": (25.03, 121.57), "Asia/Shanghai": (31.23, 121.47),
        "Asia/Chongqing": (29.56, 106.55), "Asia/Urumqi": (43.83, 87.62), "Asia/Ulaanbaatar": (47.89, 106.91),
        "Asia/Seoul": (37.57, 126.98), "Asia/Pyongyang": (39.04, 125.76), "Asia/Tokyo": (35.68, 139.69),
        "Asia/Yekaterinburg": (56.84, 60.61), "Asia/Novosibirsk": (55.01, 82.93), "Asia/Krasnoyarsk": (56.01, 92.85),
        "Asia/Irkutsk": (52.29, 104.28), "Asia/Vladivostok": (43.12, 131.89), "Asia/Kamchatka": (53.04, 158.65),
        // Oceania
        "Australia/Perth": (-31.95, 115.86), "Australia/Darwin": (-12.46, 130.84), "Australia/Adelaide": (-34.93, 138.60),
        "Australia/Brisbane": (-27.47, 153.03), "Australia/Sydney": (-33.87, 151.21), "Australia/Melbourne": (-37.81, 144.96),
        "Australia/Hobart": (-42.88, 147.33), "Australia/Canberra": (-35.28, 149.13), "Pacific/Auckland": (-36.85, 174.76),
        "Pacific/Fiji": (-18.14, 178.44), "Pacific/Guam": (13.44, 144.79), "Pacific/Port_Moresby": (-9.44, 147.18),
        "Pacific/Noumea": (-22.28, 166.46), "Pacific/Tahiti": (-17.54, -149.57), "Pacific/Honolulu": (21.31, -157.86),
        "Pacific/Tongatapu": (-21.14, -175.20), "Pacific/Apia": (-13.83, -171.76),
        // The Americas
        "America/St_Johns": (47.56, -52.71), "America/Halifax": (44.65, -63.58), "America/Toronto": (43.65, -79.38),
        "America/Montreal": (45.50, -73.57), "America/Winnipeg": (49.90, -97.14), "America/Regina": (50.45, -104.62),
        "America/Edmonton": (53.55, -113.49), "America/Vancouver": (49.28, -123.12), "America/Anchorage": (61.22, -149.90),
        "America/New_York": (40.71, -74.01), "America/Detroit": (42.33, -83.05), "America/Indiana/Indianapolis": (39.77, -86.16),
        "America/Chicago": (41.88, -87.63), "America/Denver": (39.74, -104.99), "America/Boise": (43.62, -116.20),
        "America/Phoenix": (33.45, -112.07), "America/Los_Angeles": (34.05, -118.24), "America/Puerto_Rico": (18.47, -66.11),
        "America/Mexico_City": (19.43, -99.13), "America/Monterrey": (25.69, -100.32), "America/Tijuana": (32.51, -117.04),
        "America/Cancun": (21.16, -86.85), "America/Guatemala": (14.63, -90.51), "America/El_Salvador": (13.69, -89.22),
        "America/Tegucigalpa": (14.07, -87.19), "America/Managua": (12.11, -86.24), "America/Costa_Rica": (9.93, -84.08),
        "America/Panama": (8.98, -79.52), "America/Havana": (23.11, -82.37), "America/Jamaica": (18.02, -76.80),
        "America/Santo_Domingo": (18.49, -69.93), "America/Bogota": (4.71, -74.07), "America/Caracas": (10.48, -66.90),
        "America/Lima": (-12.05, -77.04), "America/Guayaquil": (-2.19, -79.89), "America/La_Paz": (-16.50, -68.15),
        "America/Santiago": (-33.45, -70.67), "America/Argentina/Buenos_Aires": (-34.60, -58.38), "America/Buenos_Aires": (-34.60, -58.38),
        "America/Montevideo": (-34.90, -56.16), "America/Asuncion": (-25.26, -57.58), "America/Sao_Paulo": (-23.55, -46.63),
        "America/Manaus": (-3.12, -60.02), "America/Fortaleza": (-3.73, -38.53), "America/Recife": (-8.05, -34.88),
    ]
}
