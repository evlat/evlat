import Foundation
import EvlatCore

/// What the shell tells a character about the world when the character's
/// behavior is asked what to do.
///
/// Read-only and typed: a character never reaches into the registry, it is
/// handed these facts, and a rule naming one that does not exist does not
/// compile. It holds only what rules read today — a fact nobody reads is a
/// promise nobody keeps. Durations are the shell's to measure: the core
/// keeps no clock.
struct MascotContext: Equatable {
    var phase: Phase
    /// How long the drawn phase has lasted (`MascotModel.phaseSince`).
    var secondsInPhase: Double
    var sessions: Sessions

    /// The live sessions behind the face, counted by where they stand
    /// (`Registry.Layer`) — from the same snapshot the face is made from, so
    /// the two cannot disagree.
    struct Sessions: Equatable {
        var waiting = 0
        var working = 0
        /// Finishes not yet seen.
        var news = 0

        init(waiting: Int = 0, working: Int = 0, news: Int = 0) {
            self.waiting = waiting
            self.working = working
            self.news = news
        }

        /// A dimmed row is nobody's to hear, as for the face: only live rows
        /// count.
        init(_ snapshot: Registry.Snapshot) {
            for signal in snapshot.ordered where signal.isLive {
                switch snapshot.layers[signal.entity] {
                case .waiting?: waiting += 1
                case .working?: working += 1
                case .news?: news += 1
                case .passive?, nil: break
                }
            }
        }

        func count(of fact: Fact) -> Int {
            switch fact {
            case .waiting: return waiting
            case .working: return working
            case .news: return news
            }
        }
    }

    /// The facts a condition may test.
    enum Fact: CaseIterable {
        case waiting, working, news
    }
}

/// When a character plays its own gestures (`MascotCharacter.motions`):
/// rules, read as data, so what a character does and when is held by tests
/// the way its clips are.
///
/// **It is asked on events, never on a tick**: the phase entered, the
/// sessions changed, a gesture or a one-shot phase's arrival ended, or a
/// moment a rule itself named came due (`Decision.wake`). Between them
/// nothing runs — an idle mascot draws nothing, and a rule that asks to be
/// woken pays for its gestures in the duty-cycle budget
/// (`MascotCharacterContractTests`). A gesture never cuts a phase change
/// short: the player waits out a one-shot arrival, and the contract keeps a
/// looping phase's rules off its entering spring. Gestures are chosen from
/// the character's own list; nothing outside the character, and no model,
/// picks one.
///
/// A gesture **replaces** the phase's pose while it plays, standard controls
/// and all. In a one-shot phase, held at its rest, that is seamless. In a
/// looping one it pulls the face from wherever the loop had it — `working`
/// aims the eyes down and aside — back to the gesture's own pose, and the
/// loop starts again from its top after it. So the shipped characters keep
/// their gestures to `waiting` and `review`; a gesture of own controls laid
/// over a running loop is not built.
///
/// A character with no rules is never asked, and draws exactly as before.
struct MascotBehavior: Equatable {
    var rules: [MascotRule] = []

    var isEmpty: Bool { rules.isEmpty }

    /// Whether any rule reads the sessions behind the face. Only then does
    /// the model pass them on (`MascotModel.hear`): a character whose rules
    /// count time alone redraws no more often than one with none.
    var readsSessions: Bool { rules.contains { !$0.when.isEmpty } }

    /// What the behavior remembers within one phase; the player starts it
    /// over on every phase change.
    struct Memory: Equatable {
        /// Seconds into the phase at which each rule, by index, last spoke.
        var spoke: [Int: Double] = [:]
    }

    struct Decision: Equatable {
        /// The gesture to play now, if any.
        var motion: String?
        /// Seconds until a rule could next speak with nothing else happening;
        /// `nil` when only an event can change the answer.
        var wake: Double?
        var memory: Memory
    }

    /// The one decision, a pure function of what it is handed: the clock is
    /// in `context`, the dice in `random` (`0 ..< 1`).
    ///
    /// Of the rules whose phase and conditions hold, a rule is due once the
    /// phase has lasted its `after`, and again every `every` after it spoke.
    /// **One rule speaks at a time: the furthest stage reached** — the
    /// largest `after`, the first written on a tie — and every other due rule
    /// is counted as having spoken with it. So stages escalate and never go
    /// back: a mascot that wakes ten minutes into a wait plays the ten-minute
    /// gesture, not the one-minute one and then the rest in a row.
    func decide(_ context: MascotContext, memory: Memory, random: () -> Double) -> Decision {
        let t = context.secondsInPhase
        let heard = rules.indices.filter {
            rules[$0].phase == context.phase && rules[$0].when.allSatisfy { $0.holds(in: context) }
        }
        let due = heard.filter { i in
            let rule = rules[i]
            guard rule.after <= t else { return false }
            guard let last = memory.spoke[i] else { return true }
            return rule.every.map { t - last >= $0 } ?? false
        }
        var memory = memory
        var motion: String?
        let speaker = due.max { a, b in
            rules[a].after != rules[b].after ? rules[a].after < rules[b].after : a > b
        }
        if let speaker {
            motion = Self.pick(rules[speaker].play, random())
            for i in due { memory.spoke[i] = t }
        }
        var wake: Double?
        for i in heard {
            let rule = rules[i]
            let next: Double?
            if let last = memory.spoke[i] {
                next = rule.every.map { last + $0 }
            } else {
                next = rule.after
            }
            if let next, next > t { wake = min(wake ?? .infinity, next - t) }
        }
        return Decision(motion: motion, wake: wake, memory: memory)
    }

    /// A weighted pick; `roll` is in `0 ..< 1`.
    static func pick(_ picks: [MascotRule.Pick], _ roll: Double) -> String? {
        let total = picks.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var left = roll * total
        for pick in picks {
            if left < pick.weight { return pick.motion }
            left -= pick.weight
        }
        return picks.last?.motion
    }
}

/// One rule: in this phase, under these conditions, after this long, play
/// one of these gestures — once per phase, or again every so often.
struct MascotRule: Equatable {
    var phase: Phase
    /// All of them hold.
    var when: [MascotCondition] = []
    /// Seconds the phase has to have lasted. Rules of one phase at rising
    /// `after`s are stages: a wait that goes on is answered more and more.
    var after: Double = 0
    /// Seconds before it may speak again; `nil` speaks once per phase.
    var every: Double?
    var play: [Pick]

    struct Pick: Equatable {
        /// A name in the character's `motions`.
        var motion: String
        var weight: Double = 1

        init(_ motion: String, weight: Double = 1) {
            self.motion = motion
            self.weight = weight
        }
    }
}

/// A count of sessions inside bounds.
struct MascotCondition: Equatable {
    var fact: MascotContext.Fact
    var atLeast = 0
    var atMost = Int.max

    func holds(in context: MascotContext) -> Bool {
        let count = context.sessions.count(of: fact)
        return atLeast <= count && count <= atMost
    }
}
