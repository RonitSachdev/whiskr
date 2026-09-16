import Foundation
import simd

// The real sky over a place: where the sun is, when it rises and sets, and how much of the moon is lit.
// Worked out here from the published formulas, with no network: the sun by NOAA's solar calculator
// (Jean Meeus, "Astronomical Algorithms", in the form of NOAA's spreadsheet), the moon by the Astronomical
// Almanac's low-precision series. Good to about a minute for the sun and a few hours for the moon's phase,
// far finer than the meadow can show.

enum Sun {
    /// Where the sun stands at an instant, as the sky's colours need it.
    struct Position: Equatable {
        /// Degrees above the horizon (negative below), without refraction.
        var elevation: Double
        /// The hour angle, degrees: 0 at solar noon, negative in the morning, positive after noon, ±180 at
        /// solar midnight.
        var hourAngle: Double
    }

    /// The sun's declination (degrees) and the equation of time (minutes) at an instant.
    private static func orbit(_ date: Date) -> (declination: Double, equationOfTime: Double, longitude: Double) {
        let t = (julianDay(date) - 2_451_545) / 36_525
        let meanLongitude = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let anomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let m = radians(anomaly)
        let centre = sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * m) * (0.019993 - 0.000101 * t) + sin(3 * m) * 0.000289
        let node = radians(125.04 - 1934.136 * t)
        let apparent = meanLongitude + centre - 0.00569 - 0.00478 * sin(node)
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = radians(meanObliquity + 0.00256 * cos(node))
        let declination = degrees(asin(sin(obliquity) * sin(radians(apparent))))
        let y = pow(tan(obliquity / 2), 2)
        let l0 = radians(meanLongitude)
        let equation = y * sin(2 * l0) - 2 * eccentricity * sin(m) + 4 * eccentricity * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0) - 1.25 * eccentricity * eccentricity * sin(2 * m)
        return (declination, 4 * degrees(equation), apparent)
    }

    /// The sun's apparent ecliptic longitude at an instant, degrees (for the moon's phase).
    static func longitude(_ date: Date) -> Double { orbit(date).longitude }

    static func position(at date: Date, latitude: Double, longitude: Double) -> Position {
        let (declination, equation, _) = orbit(date)
        // True solar time, in minutes past solar midnight.
        let solar = euclidean(utcMinutes(date) + equation + 4 * longitude, 1440)
        let hourAngle = solar / 4 - 180
        let lat = radians(latitude), dec = radians(declination)
        let cosZenith = sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(radians(hourAngle))
        return Position(elevation: 90 - degrees(acos(min(1, max(-1, cosZenith)))), hourAngle: hourAngle)
    }

    /// Sunrise and sunset on the calendar day that contains `date` in `timeZone`: the moments the sun's
    /// upper edge meets the horizon, with the usual allowance for refraction (−0.833°).
    static func day(containing date: Date, latitude: Double, longitude: Double, timeZone: TimeZone) -> MeadowPlace.SunDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let utcMidnight = Date(timeIntervalSince1970: (noon.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
        // Each moment is found again with the sun as it is at the last estimate, three times over: solar noon
        // (kept within half a day of the clock's noon, so it is this calendar day's), less or plus the hour
        // angle at which the sun's edge meets the horizon. A sunset just past midnight counts as the day's.
        func moment(_ side: Double) -> Date? {
            var estimate = noon
            for _ in 0..<3 {
                let (declination, equation, _) = orbit(estimate)
                let lat = radians(latitude), dec = radians(declination)
                let cosHour = (cos(radians(90.833)) - sin(lat) * sin(dec)) / (cos(lat) * cos(dec))
                guard abs(cosHour) <= 1 else { return nil }
                var transit = utcMidnight.addingTimeInterval((720 - 4 * longitude - equation) * 60)
                while transit.timeIntervalSince(noon) > 43_200 { transit.addTimeInterval(-86_400) }
                while transit.timeIntervalSince(noon) < -43_200 { transit.addTimeInterval(86_400) }
                estimate = transit.addingTimeInterval(side * 4 * degrees(acos(cosHour)) * 60)
            }
            return estimate
        }
        if let rise = moment(-1), let set = moment(1) { return .risesAndSets(rise: rise, set: set) }
        let (declination, _, _) = orbit(noon)
        // No crossing: up all day when the sun at its highest and lowest stays on the same side as at noon.
        return latitude * declination > 0 ? .alwaysUp : .alwaysDown
    }
}

enum Moon {
    /// How the moon looks from Earth at an instant.
    struct Phase: Equatable {
        /// The angle at the moon between the sun and Earth, radians: 0 full, π new.
        var angle: Double
        /// Getting fuller (new to full) rather than thinner.
        var waxing: Bool
        /// The share of the disc that is lit, 0…1.
        var lit: Double { (1 + cos(angle)) / 2 }
        /// A full moon, for when the real phase is not wanted.
        static let full = Phase(angle: 0, waxing: true)
    }

    /// The moon's ecliptic longitude and latitude, degrees.
    private static func ecliptic(_ date: Date) -> (longitude: Double, latitude: Double) {
        let d = julianDay(date) - 2_451_545
        let meanLongitude = 218.316 + 13.176396 * d
        let anomaly = radians(134.963 + 13.064993 * d)
        let argument = radians(93.272 + 13.229350 * d)
        return (meanLongitude + 6.289 * sin(anomaly), 5.128 * sin(argument))
    }

    static func phase(at date: Date) -> Phase {
        let (longitude, latitude) = ecliptic(date)
        // The elongation, the moon's angle from the sun seen from Earth; the phase angle is very nearly its
        // supplement (the sun is ~390 times further off than the moon).
        let apart = euclidean(longitude - Sun.longitude(date), 360)
        let elongation = acos(cos(radians(latitude)) * cos(radians(apart)))
        return Phase(angle: .pi - elongation, waxing: apart < 180)
    }

    /// Where the moon is in the sky over a place.
    struct Sky: Equatable {
        /// Degrees above the horizon (geocentric, so up to a degree off near the horizon).
        var altitude: Double
        /// Which way its lit edge faces on the sky, as seen looking at it: how far toward the zenith (`up`)
        /// and how far to the right (`right`), unit length. The sun's direction, carried along the sky.
        var limbUp: Double, limbRight: Double
    }

    static func sky(at date: Date, latitude: Double, longitude: Double) -> Sky {
        let (lon, lat) = ecliptic(date)
        let obliquity = radians(23.4393 - 0.0000004 * (julianDay(date) - 2_451_545))
        func equatorial(_ lon: Double, _ lat: Double) -> (ra: Double, dec: Double) {
            let l = radians(lon), b = radians(lat)
            let dec = asin(sin(b) * cos(obliquity) + cos(b) * sin(obliquity) * sin(l))
            let ra = atan2(sin(l) * cos(obliquity) - tan(b) * sin(obliquity), cos(l))
            return (ra, dec)
        }
        let moon = equatorial(lon, lat), sun = equatorial(Sun.longitude(date), 0)
        let moonVector = local(moon.ra, moon.dec, date, latitude, longitude), sunVector = local(sun.ra, sun.dec, date, latitude, longitude)
        // Looking at the moon with the zenith's way up: the sun's direction projected across its face.
        let zenith = SIMD3<Double>(0, 0, 1)
        let up = simd_normalize(zenith - simd_dot(zenith, moonVector) * moonVector)
        let right = simd_cross(moonVector, up)
        let across = sunVector - simd_dot(sunVector, moonVector) * moonVector
        let a = simd_dot(across, up), b = simd_dot(across, right), length = max(hypot(a, b), 1e-9)
        return Sky(altitude: degrees(asin(min(1, max(-1, moonVector.z)))), limbUp: a / length, limbRight: b / length)
    }

    /// A direction in the sky as east, north and up, from right ascension and declination (radians).
    private static func local(_ ra: Double, _ dec: Double, _ date: Date, _ latitude: Double, _ longitude: Double) -> SIMD3<Double> {
        let d = julianDay(date) - 2_451_545
        let sidereal = radians(280.46061837 + 360.98564736629 * d + longitude)
        let hour = sidereal - ra, lat = radians(latitude)
        return SIMD3(-cos(dec) * sin(hour), cos(lat) * sin(dec) - sin(lat) * cos(dec) * cos(hour), sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hour))
    }
}

/// Sheet lightning in a thunderstorm: a soft brightening of the sky now and then, never a strobe. Whether a
/// flash falls in each stretch of `every` seconds, where in it, and whether a second pulse follows, comes from
/// a hash of the stretch's number, so it needs no state and is the same on every frame drawn for a moment.
/// Pulses last a quarter of a second and come at most two to a second, with at least ten seconds between
/// flashes: well inside WCAG 2.3.1's three flashes a second.
enum Lightning {
    static let every: Double = 20
    static let pulse: Double = 0.25
    /// When a second pulse follows the first, after this long.
    static let echo: Double = 0.55

    /// How bright the flash is at `time` seconds of the meadow's own time, 0…1.
    static func flash(at time: Double) -> Float {
        guard time.isFinite, time >= 0 else { return 0 }
        let stretch = (time / every).rounded(.down)
        let k = Int(stretch)
        // Two in three stretches have a flash; it falls in the first 10 s, so the next is at least 10 s away.
        guard hash(k, 1) < 0.67 else { return 0 }
        let at = stretch * every + hash(k, 2) * 10
        let strength = Float(0.6 + 0.4 * hash(k, 3))
        var level = shape(time - at) * strength
        if hash(k, 4) < 0.5 { level = max(level, shape(time - at - echo) * strength * 0.7) }
        return level
    }

    /// One pulse: up in 60 ms, then easing away.
    private static func shape(_ t: Double) -> Float {
        guard t >= 0, t < pulse else { return 0 }
        let rise = 0.06
        let x = t < rise ? t / rise : 1 - (t - rise) / (pulse - rise)
        return Float(x * x * (3 - 2 * x))
    }

    private static func hash(_ k: Int, _ salt: UInt64) -> Double {
        var x = UInt64(bitPattern: Int64(k)) &* 0x9E37_79B9_7F4A_7C15 ^ salt &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }
}

private func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }
private func utcMinutes(_ date: Date) -> Double { euclidean(date.timeIntervalSince1970 / 60, 1440) }
private func radians(_ d: Double) -> Double { d * .pi / 180 }
private func degrees(_ r: Double) -> Double { r * 180 / .pi }
private func euclidean(_ n: Double, _ m: Double) -> Double { (n.truncatingRemainder(dividingBy: m) + m).truncatingRemainder(dividingBy: m) }
