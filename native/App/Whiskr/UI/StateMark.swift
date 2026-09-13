import SwiftUI
import WhiskrKit

/// The marks of docs/DESIGN.md, the same everywhere outside the meadow: a 14 pt vermillion
/// circle with a white "!" for a request, with "×" for an error, an 8 pt blue dot for finished (a "✓"
/// with Differentiate Without Color), and nothing at all for the calm states.
struct StateMark: View {
    let status: AgentStatus
    var failed = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    static let vermillion = Color(red: 0xD5 / 255, green: 0x5E / 255, blue: 0x00 / 255)
    static let blue = Color(red: 0x00 / 255, green: 0x72 / 255, blue: 0xB2 / 255)

    var body: some View {
        Group {
            switch status {
            case .blocked:
                Text(failed ? "×" : "!")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Self.vermillion))
            case .done:
                if withoutColor {
                    Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(Self.blue)
                } else {
                    Circle().fill(Self.blue).frame(width: 8, height: 8)
                }
            case .working, .idle, .unknown:
                EmptyView()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(failed && status == .blocked ? String(localized: "Error") : status.label)
    }
}

extension AgentStatus {
    /// The state in the app's own words (§1).
    var label: String {
        switch self {
        case .blocked: String(localized: "Request", comment: "State: Claude asks for something")
        case .done: String(localized: "Finished", comment: "State: Claude finished a turn you have not seen")
        case .working: String(localized: "Working", comment: "State")
        case .idle: String(localized: "Idle", comment: "State")
        case .unknown: String(localized: "Starting", comment: "State: Claude has started and not reported yet")
        }
    }
}
