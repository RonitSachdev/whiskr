import AppKit
import SwiftUI

/// The rules for a note the app puts up on its own (docs/DESIGN.md, "Notes"): it never asks first and
/// never blocks; it stays only while it needs an answer; otherwise it goes about ten seconds after it was
/// first seen, its time counting only while the window is in use and the pointer is not on it, so it is
/// never taken away while being read. Its close button puts it away sooner.
enum NoteTiming {
    /// How long a note that needs no answer stays in sight.
    static let seconds: TimeInterval = 10
}

/// Counts a note's time on screen as `NoteTiming` says: only while the window is key and the pointer is
/// elsewhere. Calls `expired` once.
struct NoteClock: ViewModifier {
    let seconds: TimeInterval
    let expired: () -> Void
    @State private var shown: TimeInterval = 0
    @State private var hovering = false
    @Environment(\.controlActiveState) private var active

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .task(id: hovering || !active.inUse) {
                // Paused while hovered or while the window is not the one in use; counted again after.
                guard !hovering, active.inUse else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    shown += 0.25
                    if shown >= seconds { return expired() }
                }
            }
    }
}

extension View {
    /// Goes after `seconds` in sight (`NoteClock`).
    func noteClock(seconds: TimeInterval = NoteTiming.seconds, expired: @escaping () -> Void) -> some View {
        modifier(NoteClock(seconds: seconds, expired: expired))
    }
}

/// A quiet bar across the top of a page: an icon, one or two lines, at most one action, and a close
/// button. In the surface colour with a line under it; nothing floats over the work.
struct NoticeBar: View {
    let symbol: String
    let message: String
    var action: (title: String, run: () -> Void)?
    let close: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Look.Space.m) {
            Image(systemName: symbol)
                .font(Look.smallIcon)
                .foregroundStyle(Color.ink2)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 20, height: 20)
            }
            .buttonStyle(ChromeButtonStyle(radius: Look.Radius.small))
            .help(String(localized: "Close", comment: "A note's close button"))
            .accessibilityLabel(String(localized: "Close", comment: "A note's close button"))
        }
        .padding(.horizontal, Look.Space.l)
        .padding(.vertical, Look.Space.m)
        .background(Color.surface)
        .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
