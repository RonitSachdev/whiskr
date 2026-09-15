import Foundation

/// The app's own three alert sounds (docs/DESIGN.md): soft wooden notes, made here from sine waves rather
/// than recorded, so they belong to nobody else. A request is two rising notes (about 350 ms), an error
/// two low falling ones, a finished turn one short wood-block "tok" (about 150 ms).
public enum AlertSound: String, Sendable, CaseIterable {
    case request, error, finished

    public static let sampleRate = 44_100

    /// The sound as mono samples in -1…1 at `sampleRate`.
    public var samples: [Float] {
        switch self {
        case .request: Self.render([(0, 659.25, 0.16), (0.13, 987.77, 0.22)], length: 0.36)       // E5, then B5
        case .error: Self.render([(0, 392.00, 0.18), (0.14, 293.66, 0.24)], length: 0.40)         // G4, then D4
        case .finished: Self.render([(0, 1046.5, 0.11)], length: 0.15, knock: true)               // C6, a knock
        }
    }

    /// The sound as a WAV file (16-bit PCM), for `NSSound(data:)`.
    public var wav: Data { Self.wav(samples) }

    /// Notes struck like a marimba bar: a sine with its fourth partial (a wooden bar's bright overtone)
    /// dying faster, a 4 ms attack so nothing clicks, and an exponential fall; `knock` adds a very short
    /// low thump under the first note, a wood block's body.
    static func render(_ notes: [(start: Double, frequency: Double, decay: Double)], length: Double, knock: Bool = false) -> [Float] {
        let rate = Double(sampleRate)
        var out = [Float](repeating: 0, count: Int(length * rate))
        for (index, note) in notes.enumerated() {
            let first = Int(note.start * rate)
            for i in first..<out.count {
                let t = Double(i - first) / rate
                let attack = min(1, t / 0.004)
                let body = sin(2 * .pi * note.frequency * t) * exp(-t / (note.decay / 4.6))
                let overtone = 0.28 * sin(2 * .pi * note.frequency * 3.93 * t) * exp(-t / (note.decay / 12))
                var sample = attack * (body + overtone)
                if knock && index == 0 { sample += 0.5 * attack * sin(2 * .pi * note.frequency / 4 * t) * exp(-t / 0.012) }
                out[i] += Float(sample * 0.42)
            }
        }
        // The last 10 ms fade to silence, so the end never clicks either.
        let fade = Int(0.01 * rate)
        for i in 0..<min(fade, out.count) { out[out.count - 1 - i] *= Float(i) / Float(fade) }
        return out
    }

    /// Mono samples in -1…1 at `sampleRate` as a WAV file (16-bit PCM).
    public static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for sample in samples { put(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }
}

/// When an alert's sound may play (§6.4): at most one every two seconds, the most important waiting one
/// winning; never while you are typing (it waits for a one-second pause, at most five seconds); never
/// twice for the same request; nothing while alerts are paused. Which sound an event plays is looked up
/// when it plays (`AlertPreferences`).
public struct AlertQueue: Sendable {
    public static let spacing: TimeInterval = 2
    public static let typingPause: TimeInterval = 1
    public static let longestWait: TimeInterval = 5

    private var waiting: (event: AlertEvent, since: Date)?
    private var lastPlayed: Date = .distantPast
    private var announced: Set<String> = []

    public init() {}

    /// Something happened that has a sound. `key` names the very request or turn, so it is never
    /// sounded twice.
    public mutating func offer(_ event: AlertEvent, key: String, now: Date) {
        guard announced.insert(key).inserted else { return }
        if announced.count > 500 { announced = [key] }
        if let waiting, waiting.event.importance >= event.importance { return }
        waiting = (event, waiting?.since ?? now)
    }

    /// The event whose sound plays now, if any (and it is then taken); `lastKey` is when a key was last
    /// pressed in any pane.
    public mutating func take(now: Date, lastKey: Date?, paused: Bool) -> AlertEvent? {
        guard let waiting else { return nil }
        if paused {
            self.waiting = nil
            return nil
        }
        guard now.timeIntervalSince(lastPlayed) >= Self.spacing else { return nil }
        let typing = lastKey.map { now.timeIntervalSince($0) < Self.typingPause } ?? false
        if typing && now.timeIntervalSince(waiting.since) < Self.longestWait { return nil }
        self.waiting = nil
        lastPlayed = now
        return waiting.event
    }

    /// Whether something is waiting to play (so the caller looks again shortly).
    public var isWaiting: Bool { waiting != nil }
}

/// Pause Alerts (§6.6): until a time, or not.
public enum AlertPause {
    /// "Until Tomorrow": eight in the morning of the next day.
    public static func untilTomorrow(from now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    public static func isPaused(until: Date?, now: Date) -> Bool {
        until.map { now < $0 } ?? false
    }
}
