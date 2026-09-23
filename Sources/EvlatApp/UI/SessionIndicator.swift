import SwiftUI
import EvlatCore

/// The column under the mascot. Closed: one ring per slot, and the overflow
/// count. Open: every session, each ring's name on its inner side (left of it
/// on the right edge, right of it on the left), in a visible area of at most
/// seven and a half rows, and the summary line under it.
///
/// It observes `SessionRowsModel` and nothing else — the mascot's gaze moves
/// with the cursor, and a column that observed the mascot would be rebuilt at
/// that rate for nothing. Whether names show is handed in by `BarBody`.
///
/// **Opening moves no ring that was drawn.** A name is an overlay on its ring,
/// not a sibling in a row: it takes no room, so the ring's place is the same
/// open or closed. The name comes in from the ring's side, a few points toward
/// it, and fades. The fourth slot is the one exception: the count gives way to
/// the fourth ring, and the rows below it are uncovered by the area growing
/// with the body.
///
/// Under each name, the status line ("working · 14 min"). It is in the tree
/// **only while the bar is open**, and so is the minute tick that redraws it:
/// behind an opacity, like the name, the tick would run on the closed bar too.
struct SessionColumn: View {
    @ObservedObject var model: SessionRowsModel
    /// How far the open list is scrolled (`AppController.scrolled`).
    @ObservedObject var scroll = ListScroll()
    /// The docked edge. The left is the right's mirror: every alignment and
    /// every sign of `x` below is read off `isLeft`; the order inside a name
    /// (the name, then its raised number) is not.
    var edge: BarPanel.Edge = .right
    var showsNames = false
    /// The session whose card is up: its row gets a faint ground.
    var selected: String? = nil
    /// The row under the cursor: a fainter ground at once, before its card.
    var hovered: String? = nil
    /// The open body's width, which the ground spans.
    var openWidth: CGFloat = SessionColumn.minOpenWidth

    /// The selected row's ground: inside the open body by this much.
    static let groundInset: CGFloat = 5

    /// Between a name's end and its ring.
    static let nameGap: CGFloat = 8
    /// Between the open body's inner edge and the longest name.
    static let nameInset: CGFloat = 14
    /// How far a name travels as it comes in: from under its ring's side.
    static let nameTravel: CGFloat = 10
    /// The widest a name is drawn; a longer one is cut with "…". It also caps
    /// how far the body opens.
    static let nameMaxWidth: CGFloat = 140
    /// The narrowest the open body gets, so a column of short names still
    /// reads as a panel rather than a ragged tab.
    static let minOpenWidth: CGFloat = 110
    static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The small raised number after a repeated name.
    static let numberFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    /// The status line. Digits of one width, so "11 min" and "18 min" take
    /// the same room and the measured widest form holds.
    static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    /// The name and the status line together, centred on the ring. Taller than
    /// the ring by less than the gap between two rings, so neighbouring blocks
    /// never touch and the ring's own frame stays 20 pt.
    static let labelHeight: CGFloat = 26
    /// The ring's leading edge inside the bar's width (it is centred there).
    static var ringLead: CGFloat { (AppController.barWidth - AppController.indicatorSize) / 2 }

    /// How far an edge of an overflowing list fades into the body.
    static let fadeHeight: CGFloat = 24

    /// How strongly each edge fades at this offset: the top once anything is
    /// scrolled past it, the bottom while anything is left below — each
    /// growing over its first `fadeHeight` points (less on a short list, so
    /// it is whole at the other end), so neither pops in as the finger starts
    /// or reaches an end. Derived, never stored.
    static func fades(offset: CGFloat, maxOffset: CGFloat) -> (top: Double, bottom: Double) {
        guard maxOffset > 0 else { return (0, 0) }
        let span = min(fadeHeight, maxOffset)
        func ramp(_ distance: CGFloat) -> Double { Double(min(1, max(0, distance / span))) }
        return (ramp(offset), ramp(maxOffset - offset))
    }

    /// The open body's width for these rows: the names', or the summary
    /// line's if that is wider, within the window's room.
    static func openWidth(rows: [SessionRow], in lang: String = L10n.language) -> CGFloat {
        let names = openWidth(namesWidth: namesWidth(rows, in: lang))
        guard let text = SummaryLine.text(rows: rows, in: lang) else { return names }
        // Measured in the bolder of the two weights, so it holds either way.
        let summary = ceil((text as NSString).size(withAttributes: [.font: SummaryLine.boldFont]).width)
            + ringLead + nameInset
        return min(max(names, summary), AppController.expandedBarWidth)
    }

    /// The width the names need, as drawn: the longest one, capped at
    /// `nameMaxWidth`.
    static func namesWidth(_ labels: [String]) -> CGFloat {
        namesWidth(labels.map { SessionRow(entity: $0, label: $0, phase: .idle) })
    }

    /// The same, for rows: a repeated name is measured with its number, and
    /// the status line under it at its widest (`statusWidth`).
    static func namesWidth(_ rows: [SessionRow], in lang: String = L10n.language) -> CGFloat {
        let widest = rows.map { row -> CGFloat in
            let status = statusWidth(phase: row.phase, waitKind: row.waitKind, in: lang)
            let name = (row.label as NSString).size(withAttributes: [.font: nameFont]).width
            guard row.duplicate > 0 else { return max(name, status) }
            let number = ("\(row.duplicate)" as NSString).size(withAttributes: [.font: numberFont]).width
            return max(name + numberGap + number, status)
        }.max() ?? 0
        return min(ceil(widest), nameMaxWidth)
    }

    /// The widest a row's status line can get in its phase, whatever the
    /// minutes say — the body is fitted to this, so it does not move as time
    /// passes. It changes with the phase, which rewrites the rows anyway.
    static func statusWidth(phase: Phase, waitKind: Signal.Activity.WaitKind?,
                            in lang: String = L10n.language) -> CGFloat {
        let widest = StatusLine.widestForms(phase: phase, waitKind: waitKind, in: lang)
            .map { ($0 as NSString).size(withAttributes: [.font: statusFont]).width }
            .max() ?? 0
        return ceil(widest)
    }

    static let numberGap: CGFloat = 2

    /// The open body's width for names this wide: the part of the bar right
    /// of the ring's leading edge, the gap, the names and the inset.
    static func openWidth(namesWidth: CGFloat) -> CGFloat {
        let width = AppController.barWidth - ringLead + nameGap + namesWidth + nameInset
        return max(minOpenWidth, width)
    }

    private var isLeft: Bool { edge.isLeft }
    /// The docked side.
    private var docked: HorizontalAlignment { isLeft ? .leading : .trailing }
    /// The sign an `x` written for the right edge takes: 1 there, −1 on the
    /// left.
    private var mirror: CGFloat { isLeft ? -1 : 1 }

    /// The visible area's height: the open list's, or the closed slots'.
    private var clipHeight: CGFloat {
        showsNames ? AppController.listHeight(rows: model.rows.count)
            : CGFloat(model.slotsInUse) * AppController.rowPitch
    }

    /// The open list's offset; the closed column never scrolls.
    private var offset: CGFloat { showsNames ? scroll.offset : 0 }

    private var fadeStrength: (top: Double, bottom: Double) {
        guard showsNames else { return (0, 0) }
        return Self.fades(offset: offset, maxOffset: AppController.maxScrollOffset(rows: model.rows.count))
    }

    /// The column in a container as wide as the open body, cut at the visible
    /// area. Cut here, not on the column's own frame: that is the ring's
    /// width and would cut the names and the ground. The cut grows on the
    /// body's own curve, so while opening no ring or name is drawn past the
    /// body. The summary hangs from the cut's bottom edge and travels with it.
    var body: some View {
        rowsColumn
            // Opening and closing change which rows are in the tree; they
            // arrive and leave uncovered by the cut, not on a transition of
            // their own. The names keep their own animation, set further in.
            .transaction(value: showsNames) { $0.animation = nil }
            .padding(.top, AppController.indicatorSpacing / 2)
            // Scrolling moves the rows inside the cut, directly: the offset
            // is written with no animation and the ones below are keyed on
            // other values, so the list follows the finger.
            .offset(y: -offset)
            .frame(width: openWidth, height: clipHeight, alignment: Alignment(horizontal: docked, vertical: .top))
            .clipped()
            .overlay(alignment: .top) { fade(.top, strength: fadeStrength.top) }
            .overlay(alignment: .bottom) { fade(.bottom, strength: fadeStrength.bottom) }
            .overlay(alignment: Alignment(horizontal: docked, vertical: .bottom)) { summary }
            .animation(BarMotion.body, value: showsNames)
            .animation(BarMotion.length, value: model.rows.count)
    }

    /// The body's own black, from clear toward the edge: over an opaque body
    /// this is the same as fading the rows out, without rendering the whole
    /// list offscreen for a mask. Clear of the body's hairline on the inner
    /// edge.
    @ViewBuilder private func fade(_ edge: VerticalEdge, strength: Double) -> some View {
        if strength > 0 {
            LinearGradient(colors: [BarPalette.body.opacity(0), BarPalette.body],
                           startPoint: edge == .top ? .bottom : .top,
                           endPoint: edge == .top ? .top : .bottom)
                .frame(height: Self.fadeHeight)
                .padding(isLeft ? .trailing : .leading, 1)
                .opacity(strength)
                .allowsHitTesting(false)
        }
    }

    /// "20 sessions · 3 working" under the list, on the rings' side.
    /// With the names: it comes and goes with them.
    @ViewBuilder private var summary: some View {
        if let text = SummaryLine.attributed(rows: model.rows) {
            Text(text)
                .lineLimit(1)
                .fixedSize()
                .frame(height: AppController.summaryHeight)
                .padding(isLeft ? .leading : .trailing, Self.ringLead)
                .offset(y: AppController.summaryGap + AppController.summaryHeight)
                .opacity(showsNames ? 1 : 0)
                .animation(showsNames ? BarMotion.namesIn : BarMotion.namesOut, value: showsNames)
                .allowsHitTesting(false)
        }
    }

    private var rowsColumn: some View {
        VStack(alignment: docked, spacing: AppController.indicatorSpacing) {
            // Identity is the session, so a reorder travels on the spring
            // rather than snapping rings into each other's places.
            ForEach(showsNames ? model.rows : model.closedRows) { row in
                // Centred in the collapsed bar's width, the same column the
                // mascot sits in.
                SessionIndicator(phase: row.phase, source: row.source,
                                 // Only a beating row sees the counter move. A
                                 // still row's trigger never changes on the
                                 // beat, so it plays nothing and draws nothing.
                                 beat: row.beats ? model.beat : 0)
                    .frame(width: AppController.barWidth)
                    .background(alignment: Alignment(horizontal: docked, vertical: .center)) {
                        ground(selected: showsNames && row.entity == selected,
                               hovered: showsNames && row.entity == hovered)
                    }
                    // The name's box starts at the ring's far side and is
                    // pushed across it by the offset in `label`.
                    .overlay(alignment: isLeft ? .trailing : .leading) { label(row) }
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: isLeft ? .leading : .trailing)))
            }
            if !showsNames, model.overflow > 0 {
                // A number, not a word, so it needs no catalogue entry. The
                // closed bar's alone: the open list draws every row instead.
                Text("+\(model.overflow)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BarPalette.textSecondary)
                    // Wider than a ring: in a ring-sized frame a two-digit
                    // count truncated to "…" (seen on the live bar).
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: AppController.indicatorSize)
                    .frame(width: AppController.barWidth)
                    .transition(.opacity)
            }
        }
        .animation(MascotPose.transition, value: model.rows)
        .animation(MascotPose.transition, value: model.overflow)
    }

    /// Behind the selected row, as wide as the open body less an inset: the
    /// row the card speaks for. Half as strong under the cursor alone, so a
    /// row shows it answers to pointing before its card comes.
    private func ground(selected: Bool, hovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.09))
            .frame(width: max(0, openWidth - 2 * Self.groundInset),
                   height: Self.labelHeight + 6)
            .offset(x: -mirror * Self.groundInset)
            .opacity(selected ? 1 : hovered ? 0.5 : 0)
            .animation(BarMotion.namesOut, value: selected)
            .animation(BarMotion.namesOut, value: hovered)
            .allowsHitTesting(false)
    }

    /// The name, aligned against its ring. Its own animation, keyed on
    /// `showsNames` alone: it comes in just after the body starts to open and
    /// goes out before the body starts to close, so no name is ever drawn
    /// past the body's edge.
    ///
    /// Idle sessions are grey and the rest white: the same split the rings
    /// make, so the eye lands on what is doing something.
    ///
    /// A repeated name in the same tool carries a small raised number after
    /// it — only then, so a unique name stays bare.
    ///
    /// The block is top-aligned in a fixed height, so the name sits in the
    /// same place whether the status line is in the tree or not.
    private func label(_ row: SessionRow) -> some View {
        VStack(alignment: docked, spacing: 1) {
            name(row.label, duplicate: row.duplicate, color: row.phase == .idle
                 ? BarPalette.textSecondary : BarPalette.textPrimary)
            if showsNames {
                // Once a minute, and only while open. The date comes from the
                // timeline, not `Date()`, so the text is a function of it.
                TimelineView(.everyMinute) { context in
                    Text(verbatim: StatusLine.text(phase: row.phase, waitKind: row.waitKind,
                                                   enteredAt: row.enteredAt, now: context.date))
                        .font(Font(Self.statusFont))
                        // Waiting is the one that asks for the user: amber,
                        // the ring's colour. The rest is grey.
                        .foregroundStyle(row.phase == .waiting
                                         ? SessionIndicator.amber : BarPalette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity)
            }
        }
            .frame(width: Self.nameMaxWidth, height: Self.labelHeight,
                   alignment: Alignment(horizontal: docked, vertical: .top))
            // Written for the right edge — the box's trailing side `nameGap`
            // short of the ring, arriving from `nameTravel` nearer it — and
            // mirrored whole on the left.
            .offset(x: mirror * (Self.ringLead - Self.nameGap - Self.nameMaxWidth
                                 + (showsNames ? 0 : Self.nameTravel)))
            .opacity(showsNames ? 1 : 0)
            .animation(showsNames ? BarMotion.namesIn : BarMotion.namesOut, value: showsNames)
            .allowsHitTesting(false)
    }

    private func name(_ label: String, duplicate: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.numberGap) {
            // The name is data, not text of ours: it is what the user called
            // the session, so it bypasses the string lookup (`verbatim`) and
            // needs no catalogue entry.
            Text(verbatim: label)
                .font(Font(Self.nameFont))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
            if duplicate > 0 {
                Text(verbatim: "\(duplicate)")
                    .font(Font(Self.numberFont))
                    .foregroundStyle(BarPalette.textSecondary)
                    .baselineOffset(4)
                    .fixedSize()
            }
        }
            .frame(width: Self.nameMaxWidth, alignment: isLeft ? .leading : .trailing)
    }
}

/// The line under the open list: "20 sessions · 3 working". Working is the
/// `working` phase alone — a waiting row asks for the user and says so on its
/// own line. With nothing working the second part is gone; with no session
/// there is no line.
///
/// **The keys are literals here**, listed in `keys`, so a test reaches all of
/// them.
enum SummaryLine {
    static let lineKey = "summary.line"
    static let sessionsOneKey = "summary.sessions.one"
    static let sessionsKey = "summary.sessions"
    static let workingKey = "summary.working"
    static var keys: [String] { [lineKey, sessionsOneKey, sessionsKey, workingKey] }

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    static func parts(rows: [SessionRow], in lang: String) -> (sessions: String, working: String?)? {
        guard !rows.isEmpty else { return nil }
        let sessions = rows.count == 1
            ? L10n.t(sessionsOneKey, in: lang)
            : L10n.t(sessionsKey, ["count": String(rows.count)], in: lang)
        let working = rows.filter { $0.phase == .working }.count
        return (sessions, working == 0 ? nil : L10n.t(workingKey, ["count": String(working)], in: lang))
    }

    static func text(rows: [SessionRow], in lang: String = L10n.language) -> String? {
        guard let parts = parts(rows: rows, in: lang) else { return nil }
        guard let working = parts.working else { return parts.sessions }
        return L10n.t(lineKey, ["sessions": parts.sessions, "working": working], in: lang)
    }

    /// The line as drawn: grey, the working part white and bolder — the
    /// same split the names make.
    static func attributed(rows: [SessionRow], in lang: String = L10n.language) -> AttributedString? {
        guard let parts = parts(rows: rows, in: lang), let line = text(rows: rows, in: lang) else {
            return nil
        }
        var out = AttributedString(line)
        out.font = Font(font)
        out.foregroundColor = BarPalette.textSecondary
        if let working = parts.working, let range = out.range(of: working, options: .backwards) {
            out[range].font = Font(boldFont)
            out[range].foregroundColor = BarPalette.textPrimary
        }
        return out
    }
}

/// The status line's text: "working · 14 min". Pure — the phase, what a
/// block waits for, when the phase was entered and the time now — so the
/// minute tick only has to hand it a date, and the boundaries are tested
/// without a clock.
///
/// **The keys are literals in the tables below**, one per case, so a test that
/// walks the cases reaches every key the line can ask for.
enum StatusLine {
    static let lineKey = "status.line"
    static let justNowKey = "time.justNow"

    enum Unit: CaseIterable {
        case minutes, hours, days

        var key: String {
            switch self {
            case .minutes: return "time.minutes"
            case .hours: return "time.hours"
            case .days: return "time.days"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .minutes: return 60
            case .hours: return 3600
            case .days: return 86_400
            }
        }

        /// The count the widest form is measured with. Digits are of one
        /// width in `statusFont`, so only the number of them matters: minutes
        /// and hours stop at two, days get three.
        var widestCount: String {
            switch self {
            case .minutes, .hours: return "00"
            case .days: return "000"
            }
        }
    }

    static func statusKey(phase: Phase, waitKind: Signal.Activity.WaitKind?) -> String {
        switch phase {
        case .idle: return "status.idle"
        case .working: return "status.working"
        case .review: return "status.review"
        case .failed: return "status.failed"
        case .waiting:
            switch waitKind {
            case .approval: return "status.waiting.approval"
            case .answer: return "status.waiting.answer"
            // A file row waits with no hook having said on what.
            case nil: return "status.waiting"
            }
        }
    }

    /// Under a minute is "just now"; then whole minutes, hours, days — always
    /// rounded down, so the line never runs ahead of the time.
    static func duration(_ seconds: TimeInterval, in lang: String) -> String {
        let s = max(0, seconds)   // a clock behind the stamp reads as now
        guard s >= Unit.minutes.seconds else { return L10n.t(justNowKey, in: lang) }
        let unit: Unit = s < Unit.hours.seconds ? .minutes : s < Unit.days.seconds ? .hours : .days
        return L10n.t(unit.key, ["count": String(Int(s / unit.seconds))], in: lang)
    }

    static func text(phase: Phase, waitKind: Signal.Activity.WaitKind?,
                     enteredAt: Date?, now: Date, in lang: String = L10n.language) -> String {
        let status = L10n.t(statusKey(phase: phase, waitKind: waitKind), in: lang)
        // Not seen entering the phase: how long is not known.
        guard let enteredAt else { return status }
        let time = duration(now.timeIntervalSince(enteredAt), in: lang)
        return L10n.t(lineKey, ["status": status, "time": time], in: lang)
    }

    /// Every form the line can take in this phase, with the widest counts —
    /// what the open body is fitted to.
    static func widestForms(phase: Phase, waitKind: Signal.Activity.WaitKind?,
                            in lang: String) -> [String] {
        let status = L10n.t(statusKey(phase: phase, waitKind: waitKind), in: lang)
        let times = [L10n.t(justNowKey, in: lang)]
            + Unit.allCases.map { L10n.t($0.key, ["count": $0.widestCount], in: lang) }
        return [status] + times.map { L10n.t(lineKey, ["status": status, "time": $0], in: lang) }
    }
}

/// One session's ring. The phase picks the look (ROADMAP → the indicator's
/// language); the beat plays the gesture.
///
/// **Beats, not loops.** A spinning arc under `TimelineView` or
/// `repeatForever` is the ~7% floor `001` measured, and a working session runs
/// for hours. So `working` turns once per beat and `waiting` pulses once per
/// beat, still in between; `review` flares once on arrival and fades.
struct SessionIndicator: View {
    let phase: Phase
    var source: AgentSource? = nil
    let beat: Int

    private var size: CGFloat { AppController.indicatorSize }

    var body: some View {
        ring
            .frame(width: size, height: size)
            .animation(MascotPose.transition, value: phase)
            // Hung **above** the phase-dependent drawing, never inside a
            // branch: `keyframeAnimator` fires on a *change* of its trigger and
            // never on first appearance, so a host rebuilt by a phase change
            // would miss exactly the arrival it exists for (`AGENTS.md` →
            // Tuzaklar). The trigger carries the phase so arriving at
            // `review` flares, and the beat so a beating row gestures.
            .keyframeAnimator(initialValue: IndicatorGesture(),
                              trigger: IndicatorTrigger(phase: phase, beat: beat)) { view, g in
                view
                    // The turn is the ring's alone: the mark inside stays
                    // upright, which is what keeps it readable while it works.
                    .rotationEffect(.degrees(g.spin))
                    .overlay { mark }
                    .scaleEffect(g.pulse)
                    .shadow(color: glowColor.opacity(g.glow), radius: size * 0.35)
            } keyframes: { _ in
                KeyframeTrack(\.spin) {
                    for key in IndicatorGesture.spin(for: phase) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
                KeyframeTrack(\.pulse) {
                    for key in IndicatorGesture.pulse(for: phase) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
                KeyframeTrack(\.glow) {
                    for key in IndicatorGesture.glow(for: phase) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
            }
    }

    private var line: CGFloat { 1.6 }

    /// The tool's mark, in the phase's colour: the ring and the mark say the
    /// same state, the mark alone says where the session runs.
    @ViewBuilder private var mark: some View {
        if let source {
            SourceGlyph(source: source)
                .fill(markColor, style: FillStyle(eoFill: true))
                .frame(width: size * 0.56, height: size * 0.56)
        }
    }

    private var markColor: Color {
        switch phase {
        case .idle: return BarPalette.textSecondary
        case .working: return BarPalette.textPrimary
        case .waiting: return Self.amber
        case .review: return Self.green
        case .failed: return Self.red
        }
    }

    @ViewBuilder private var ring: some View {
        // Exhaustive on purpose: a new `Phase` must not compile until it has
        // a look here (`proje.md` → Yayın etkisi, the three places).
        switch phase {
        case .idle:
            Circle().stroke(Color.white.opacity(0.28), lineWidth: line)
        case .working:
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: line)
                // The thin arc. The beat turns the whole ring; the track is
                // round, so only the arc is seen to move.
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
        case .waiting:
            Circle()
                .stroke(Self.amber, lineWidth: line)
                // Faint: the amber mark sits on it and has to stay readable.
                .background(Circle().fill(Self.amber.opacity(0.18)))
        case .review:
            Circle().stroke(Self.green.opacity(0.8), lineWidth: line)
        case .failed:
            Circle()
                .stroke(Self.red, lineWidth: line)
                .background(Circle().fill(Self.red.opacity(0.18)))
        }
    }

    private var glowColor: Color {
        switch phase {
        case .waiting: return Self.amber
        case .review: return Self.green
        case .idle, .working, .failed: return .clear
        }
    }

    static let amber = Color(red: 1.0, green: 0.72, blue: 0.18)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let red = Color(red: 0.95, green: 0.30, blue: 0.28)
}

/// What fires a gesture: arriving at a phase, or a beat while in one.
struct IndicatorTrigger: Equatable {
    var phase: Phase
    var beat: Int
}

/// The animated values of one gesture, and the table of gestures per phase —
/// the same shape as `MascotShake`, so what each phase does is a claim the
/// tests can read rather than a branch inside a view.
///
/// **Every track ends where it started.** Whether the animator keeps the last
/// keyframe or falls back to the initial value, the ring is left in its rest
/// state, and the next gesture starts from rest.
struct IndicatorGesture {
    /// Degrees the ring is turned.
    var spin: Double = 0
    /// Scale of the ring.
    var pulse: Double = 1
    /// Opacity of the halo.
    var glow: Double = 0

    struct Key: Equatable {
        var value: Double
        /// Seconds to reach it.
        var duration: Double
    }

    /// `working`: one full turn, then snap back to 0 — which is the same angle.
    static func spin(for phase: Phase) -> [Key] {
        guard phase == .working else { return [] }
        return [Key(value: 360, duration: 0.9), Key(value: 0, duration: 0)]
    }

    /// `waiting`: one swell and back — the amber pulse.
    static func pulse(for phase: Phase) -> [Key] {
        switch phase {
        case .waiting: return [Key(value: 1.3, duration: 0.2), Key(value: 1, duration: 0.45)]
        case .review: return [Key(value: 1.25, duration: 0.15), Key(value: 1, duration: 0.5)]
        case .idle, .working, .failed: return []
        }
    }

    /// `waiting` glows with its pulse; `review` flares and fades — the
    /// "green, then dies away" of the indicator language, played once.
    static func glow(for phase: Phase) -> [Key] {
        switch phase {
        case .waiting: return [Key(value: 0.9, duration: 0.2), Key(value: 0, duration: 0.45)]
        case .review: return [Key(value: 1, duration: 0.15), Key(value: 0, duration: 1.6)]
        case .idle, .working, .failed: return []
        }
    }

    /// How long the gesture keeps producing frames: the longest track.
    static func duration(for phase: Phase) -> Double {
        [spin(for: phase), pulse(for: phase), glow(for: phase)]
            .map { $0.reduce(0) { $0 + $1.duration } }
            .max() ?? 0
    }
}
