import Foundation
import SwiftTerm
import WhiskrKit

/// Answering a request without going to its terminal (docs/DESIGN.md): from the answer card or a
/// notification's Allow and Deny. Keys go into the pane exactly as you would type them, and only while
/// the very request shown is still the one waiting, unchanged, with the terminal's prompt unchanged too.
///
/// Verified against a real Claude Code 2.1.305 in a pseudo-terminal (2026-11-13): its permission dialog
/// reads "Do you want to proceed? ❯ 1. Yes  2. No · Esc to cancel"; typing "1" alone runs the command at
/// once, and Esc refuses it (the turn stops and Claude asks what to do instead). Those two are offered.
/// Questions, plans and forms are answered in the terminal: their keys were not verified.
struct OpenRequest: Equatable {
    let paneID: UUID
    let sessionID: String
    let ask: Ask
    let plan: AnswerPlan
    /// The bottom of the terminal's screen when the request was looked at.
    let screen: String

    /// Allow and Deny, when the request is a permission; nothing for anything else.
    var answers: [AnswerPlan.Option] {
        guard ask.kind == .permission else { return [] }
        return plan.options.filter { ($0.role == .allow || $0.role == .deny) && $0.keys != nil && $0.positionVerified }
    }
}

extension Workbench {
    /// The request a pane's Claude is waiting on now, if any.
    func openRequest(pane id: UUID) -> OpenRequest? {
        guard let pane = panes[id], let session = session(of: pane), session.status == .blocked, !session.failed,
              let ask = monitor.detail(sessionID: session.id)?.asks.last else { return nil }
        return OpenRequest(paneID: id, sessionID: session.id, ask: ask, plan: AnswerPlan(ask: ask), screen: screenTail(of: pane))
    }

    /// Whether `request` is still exactly what is waiting: the same ask, unchanged, the Claude still
    /// asking, and (when `checkScreen`) the same prompt on the terminal's screen.
    func isCurrent(_ request: OpenRequest, checkScreen: Bool) -> Bool {
        guard let pane = panes[request.paneID], let session = session(of: pane), session.id == request.sessionID,
              session.status == .blocked, let asks = monitor.detail(sessionID: session.id)?.asks,
              request.plan.isCurrent(in: asks) else { return false }
        return !checkScreen || screenTail(of: pane) == request.screen
    }

    /// Types the answer into the pane, if the request is still current; returns whether it did.
    @discardableResult
    func answer(_ request: OpenRequest, with option: AnswerPlan.Option, checkScreen: Bool = true) -> Bool {
        guard let keys = option.keys, request.answers.contains(option), isCurrent(request, checkScreen: checkScreen),
              let pane = panes[request.paneID] else { return false }
        pane.type(keys)
        notifier.withdraw(pane: request.paneID)
        return true
    }

    /// The last dozen lines of a pane's screen, as text: what a prompt shows.
    func screenTail(of pane: Pane) -> String {
        let rows = pane.surface.terminalDimensions.rows
        guard rows > 0 else { return "" }
        return pane.surface.visibleRowsText(max(0, rows - 12)..<rows).joined(separator: "\n")
    }
}
