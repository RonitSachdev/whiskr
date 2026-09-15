import AVFoundation
import WhiskrKit

/// The sounds you add in Settings › Alerts: checked (it decodes, it is heard, it is short:
/// `CustomSounds.check`), then copied into the app's Sounds folder (`AlertCenter.soundsFolder`), so the
/// alert keeps its sound when the original moves; removed from there when you remove it.
enum CustomSoundFiles {
    /// How loud a file gets at its peak and how long it lasts, read through Core Audio; nil when it does
    /// not decode. Only the first `CustomSounds.longest` seconds and a little are read.
    static func inspect(_ url: URL) -> (peak: Float, duration: TimeInterval)? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        guard duration > 0 else { return nil }
        // Too long is said without reading it all.
        guard duration <= CustomSounds.longest else { return (1, duration) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            peak = max(peak, CustomSounds.peak(UnsafeBufferPointer(start: channels[channel], count: frames)))
        }
        return (peak, duration)
    }

    /// Checks `url` and keeps a copy; returns the name it is kept under.
    static func add(_ url: URL) -> Result<String, CustomSounds.Problem> {
        guard let (peak, duration) = inspect(url) else { return .failure(.unreadable) }
        if let problem = CustomSounds.check(peak: peak, duration: duration) { return .failure(problem) }
        let folder = AlertCenter.soundsFolder
        let name = CustomSounds.fileName(for: url.lastPathComponent, taken: Set(AlertCenter.customSounds))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        } catch {
            return .failure(.unreadable)
        }
        return .success(name)
    }

    /// Removes a kept sound; the alerts that played it go back to their default sound.
    static func remove(_ name: String) {
        guard AlertSoundChoice.isPlainName(name) else { return }
        AlertCenter.shared.forgetPlayer(.custom(name))
        try? FileManager.default.removeItem(at: AlertCenter.soundsFolder.appendingPathComponent(name))
        Preferences.shared.alerts.forget(custom: name)
    }

    /// Why a file was not taken, for Settings to say.
    static func message(_ problem: CustomSounds.Problem, file: String) -> String {
        switch problem {
        case .unreadable:
            String(localized: "“\(file)” can’t be used: it isn’t a sound file Whiskr can play.", comment: "Settings › Alerts: a chosen sound file does not decode")
        case .tooLong:
            String(localized: "“\(file)” can’t be used: an alert sound can be \(Int(CustomSounds.longest)) seconds long at most.", comment: "Settings › Alerts: a chosen sound file is too long")
        case .silent:
            String(localized: "“\(file)” can’t be used: it is silent.", comment: "Settings › Alerts: a chosen sound file has nothing to hear")
        }
    }
}
