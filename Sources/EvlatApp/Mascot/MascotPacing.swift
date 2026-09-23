import SwiftUI
import EvlatCore

/// The measurement instrument's switch.
///
/// `plan.md` → Yaklaşım 6 wants three legs, and the first one — *what the clip
/// costs while it is actually running* — cannot be read off a burst: a 90 s
/// window over a bursting clip measures `in-clip cost × duty cycle`, and
/// stretching the window buys any number you like. `continuous` removes the
/// waiting: every step holds only as long as its own motion, so the clip runs
/// end to end and the reading is the cost of the motion itself.
///
/// It is a measuring tool, not a mode anyone should run the app in — the
/// mascot never stops moving under it, which is precisely the ~7% floor `001`
/// measured and `003` exists to stay off. `003/phase-2` wrote it and `phase-3`
/// and `phase-4` measure with it, together with `EVLAT_PHASE`
/// (`AppController.forcedPhase`).
///
/// **Why the environment and not a menu item.** It is not a choice a user
/// makes, and a menu entry would be user-visible text with no catalogue to live
/// in — the catalogue arrives with the first job that needs user text.
/// `EVLAT_SESSIONS` and `EVLAT_PORT` already have this shape:
/// no `UserDefaults` key, no stored state, no effect when unset. Resolution is
/// a pure function over a dictionary so it is testable — the shape
/// `HookListener.resolvePort` uses.
enum MascotPacing: String, CaseIterable {
    /// The clip as written: bursts with quiet in between.
    case normal
    /// Waits removed, for the in-clip leg of the measurement.
    case continuous

    static let environmentKey = "EVLAT_MASCOT_PACING"

    static let selected = resolve()

    static func resolve(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MascotPacing {
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return .normal
        }
        // An unreadable value falls back rather than refusing: a mascot that
        // will not start is a worse answer than one running normally.
        return MascotPacing(rawValue: raw) ?? .normal
    }
}
