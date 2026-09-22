import SwiftUI
import EvlatCore

/// The knobs `003/phase-2` puts side by side, all read from the environment.
///
/// **Why the environment and not a menu item.** The catalogue
/// (`Resources/{en,tr}.lproj`) lands in `004` and does not exist yet, so a menu
/// entry would be user-visible text with nowhere to live — the "new text goes
/// into both tables" rule cannot be honoured today. These are also not choices
/// a user makes twice: they exist so three candidates can be looked at once and
/// one of them can be kept. `EVLAT_SESSIONS` and `EVLAT_PORT` already have this
/// shape: no `UserDefaults` key, no stored state, no effect when unset.
///
/// Every one of them resolves through a pure function over a dictionary so the
/// resolution itself is testable — the shape `HookListener.resolvePort` uses.

/// The three `working` candidates. **Nothing here picks one**: `phase-2` is a
/// user gate (`plan.md` → R8), and the agent's job ends at putting them side by
/// side with their costs measured.
///
/// They separate on **what they do**, not on parameter values:
///
/// | candidate | axis | gaze | body |
/// |---|---|---|---|
/// | `breath` | a body rhythm | keeps most of the cursor | breathes, twice a cycle |
/// | `glance` | gives up the gaze | lets the cursor go, eyes dart | still |
/// | `busy` | both, at lower amplitude | half-released, aimed down | small bob |
///
/// `gazeMix` is part of the axis, not a separate setting: a candidate whose
/// idea is "it stopped looking at you" is not the same clip with a different
/// number, it is a different answer to what `working` means.
enum MascotWorking: String, CaseIterable {
    /// **A — it breathes.** The face stays with you (`gazeMix` 0.45, the value
    /// `phase-1` left provisional) and the body carries the signal: two shallow
    /// breaths per cycle, stretching up and narrowing slightly, then quiet.
    /// Distinguishable from `idle` by **rate**: `idle` breathes once in 18.8 s,
    /// this breathes twice in 11.7 s.
    case breath
    /// **B — it looks away.** The body does not move at all; the eyes leave the
    /// cursor (`gazeMix` 0.15) and flick between spots below the face, holding
    /// each for an uneven while. Distinguishable from `idle` **without looking
    /// at the mascot at all**: move the pointer and it no longer follows.
    case glance
    /// **C — heads-down.** Both axes at lower amplitude: the gaze is half
    /// released (`gazeMix` 0.30) and settles downward onto the work, with a
    /// small bob in the body and the occasional dart sideways.
    case busy

    static let environmentKey = "EVLAT_MASCOT_WORKING"

    /// The candidate in force. Unset resolves to `breath` because it is the one
    /// closest to what `phase-1` already shipped — its `gazeMix` is the same
    /// 0.45 — so an unset variable moves the gaze no further than it already
    /// was. **A default is not a recommendation**; the choice is the user's.
    static let selected = resolve()

    static func resolve(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MascotWorking {
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return .breath
        }
        // An unreadable value falls back rather than refusing: this is a
        // looking-at instrument, and a mascot that will not start is worse than
        // one showing the default.
        return MascotWorking(rawValue: raw) ?? .breath
    }

    /// How much of the cursor this candidate's `working` face takes.
    /// `MascotPose.resting(for:working:)` reads it; it is constant for the whole
    /// phase, never animated (Karar 4: the mix is a phase property, `wander` is
    /// out of scope).
    var gazeMix: Double {
        switch self {
        case .breath: return 0.45
        case .glance: return 0.15
        case .busy: return 0.30
        }
    }
}

/// Karar 2, side by side: the phase-change curve is either a spring or an
/// exponential ease-out, and which one a cube reads better with is not knowable
/// on paper.
///
/// The swap is one line and it lands on **step 0 of every clip**, which is the
/// step a phase change travels through (`MascotClip.clip(for:)`), so both
/// variants can be watched on the same candidate.
///
/// The `failed` shudder is deliberately left out of this: it is a transient
/// fired by arriving somewhere, not a transition between two poses, and its
/// four keyframes were tuned as a damped spring in `001`.
enum MascotCurve: String, CaseIterable {
    /// `001`'s choice: interruptible, velocity-preserving, "never snaps" for
    /// free. Reads organic.
    case spring
    /// `easeOutQuint` as a timing curve — the shape measured off reference
    /// video. Reads decisive, mechanical.
    case ease

    static let environmentKey = "EVLAT_MASCOT_CURVE"

    /// Unset is `spring`: the curve decision is the user's and until it is made
    /// the shipped behaviour stays exactly `001`'s.
    static let selected = resolve()

    static func resolve(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MascotCurve {
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return .spring
        }
        return MascotCurve(rawValue: raw) ?? .spring
    }

    var animation: Animation {
        switch self {
        case .spring: return .spring(response: 0.38, dampingFraction: 0.72)
        // cubic-bezier(0.22, 1, 0.36, 1): the standard `easeOutQuint`. The
        // duration is the spring's response plus its overshoot, so the two
        // variants take about the same wall-clock time to land and the
        // comparison is about shape rather than speed.
        case .ease: return .timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
        }
    }
}

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
/// measured and `003` exists to stay off.
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
        return MascotPacing(rawValue: raw) ?? .normal
    }
}
