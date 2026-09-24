import Foundation
import EvlatCore

/// One rate-limit window as the open bar draws it: what is drawn, and
/// nothing else.
///
/// The observation is **cut to the minute**. Claude's status line stamps
/// every message it relays; carried to the second, that stamp would make two
/// identical windows compare unequal and let every relay through the
/// deadband in `UsageBlockModel.update` (`proje.md` → Tuzaklar, the
/// `@Published` trap). The percent is the drawn one for the same reason: a
/// tenth of a percent moves nothing on screen.
struct UsageWindow: Equatable, Identifiable {
    let entity: String
    /// The group it is drawn under (`Signal.Usage.group`).
    let group: String
    let windowMinutes: Int
    /// Used, in whole percent, as the source said it: past 100 too.
    let percent: Int
    let resetsAt: Date
    let fidelity: Signal.Fidelity
    /// When the numbers were seen, cut to the minute.
    let observedAt: Date

    var id: String { entity }
}

/// A line of the block: a group's heading, or one of its windows. Both take
/// one `AppController.usageLineHeight`, so the block's length is its line
/// count and nothing else.
enum UsageLine: Equatable, Identifiable {
    case header(String)
    case window(UsageWindow)

    var id: String {
        switch self {
        case .header(let group): return "group:\(group)"
        case .window(let window): return window.entity
        }
    }
}

/// How a window is drawn at a given time. Pure, so the minute tick only
/// hands it a date and the boundaries are tested without a clock.
enum UsageFreshness: Equatable {
    /// Seen within the hour: drawn as it is, amber past the threshold.
    case fresh
    /// Seen longer ago: still drawn until it resets, dimmed, and it says
    /// how old it is instead of when it resets. An old number rings no alarm.
    case stale
    /// Reset: the number no longer means anything. Not a line
    /// (`UsageBlockModel.lines(from:now:)` drops it).
    case expired
}

/// The usage block's own model, apart from `SessionRowsModel`: the two move
/// at different rates, and each view observes the model it draws. Only the
/// open bar's block observes it; nothing on the closed bar does.
@MainActor
final class UsageBlockModel: ObservableObject {
    /// The most lines the block draws: today's two sources and one remote
    /// machine's Claude (`010`), each a heading and two windows. The envelope
    /// is sized for this once (`AppController.envelopeSize`); a second
    /// machine falls off whole, like any group past the cap.
    nonisolated static let maxLines = 9
    /// An observation older than this is stale.
    nonisolated static let staleAfter: TimeInterval = 60 * 60
    /// A fresh window at or past this is drawn amber.
    nonisolated static let hotPercent = 80

    @Published private(set) var lines: [UsageLine] = []

    /// Writes what is drawn, and only when it changed. `now` is handed in —
    /// `refresh()` passes the clock, a test its own date.
    func update(from usage: [Signal], now: Date) {
        let next = Self.lines(from: usage, now: now)
        if lines != next { lines = next }
    }

    /// The lines for these signals at `now`, in the snapshot's order (group,
    /// then window length). A reset window is dropped **first** and the cap
    /// applied after, so the lines laid out are the lines drawn and a reset
    /// window never pushes a live group out. A group that no longer fits is
    /// dropped whole, and every group after it: which one falls off does not
    /// depend on what the others hold.
    ///
    /// A signal with no window, or no usable number, cannot be drawn and is
    /// left out; `--list` still prints it.
    nonisolated static func lines(from usage: [Signal], now: Date) -> [UsageLine] {
        var groups: [(name: String, windows: [UsageWindow])] = []
        for signal in usage {
            guard let window = window(signal),
                  freshness(observedAt: window.observedAt, resetsAt: window.resetsAt, now: now) != .expired
            else { continue }
            if groups.last?.name == window.group {
                groups[groups.count - 1].windows.append(window)
            } else {
                groups.append((window.group, [window]))
            }
        }
        var lines: [UsageLine] = []
        for group in groups {
            guard lines.count + 1 + group.windows.count <= maxLines else { break }
            lines.append(.header(group.name))
            lines += group.windows.map(UsageLine.window)
        }
        return lines
    }

    nonisolated static func window(_ signal: Signal) -> UsageWindow? {
        guard let usage = signal.usage, let progress = signal.progress else { return nil }
        // `Int(_:)` traps on NaN and infinity; such a number is not drawn.
        let scaled = (progress * 100).rounded()
        guard scaled.isFinite, abs(scaled) < Double(Int32.max) else { return nil }
        let minute = (signal.updatedAt.timeIntervalSince1970 / 60).rounded(.down) * 60
        return UsageWindow(entity: signal.entity, group: usage.group,
                           windowMinutes: usage.windowMinutes, percent: Int(scaled),
                           resetsAt: usage.resetsAt, fidelity: signal.fidelity,
                           observedAt: Date(timeIntervalSince1970: minute))
    }

    /// Reset at `resetsAt` itself; stale past the hour, fresh up to it.
    nonisolated static func freshness(observedAt: Date, resetsAt: Date, now: Date) -> UsageFreshness {
        if now >= resetsAt { return .expired }
        return now.timeIntervalSince(observedAt) > staleAfter ? .stale : .fresh
    }

    /// Amber only on a fresh number: a stale one may long have moved.
    nonisolated static func isHot(_ window: UsageWindow, freshness: UsageFreshness) -> Bool {
        freshness == .fresh && window.percent >= hotPercent
    }

    /// Whether the number is Evlat's reading rather than the vendor's own:
    /// drawn with a leading `~` (ROADMAP → Fidelity).
    nonisolated static func isApproximate(_ fidelity: Signal.Fidelity) -> Bool {
        switch fidelity {
        case .official: return false
        case .derived, .manual: return true
        }
    }
}
