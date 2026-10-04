import SwiftUI
import AppKit
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
    /// The ground's height, centred on the ring. A row's hover slot is its
    /// ring and half the gap each side (`AppController.slot`), one pitch,
    /// 30 pt; the ground was the label and 3 pt each side, 32, so it
    /// reached 1 pt into each neighbour's slot and the selected row's and
    /// the hovered one's overlapped by 2 pt, drawn brighter. 28 stays 1 pt
    /// inside its slot — 2 pt of body between two grounds — and still holds
    /// the 26 pt label with 1 pt to spare, the pitch unchanged.
    static let groundHeight: CGFloat = 28
    /// How far the ground sits under the ring's centre: the label's ink is
    /// that much lower — the name's line keeps room above its capitals, the
    /// status line's words hang below it (approval, question, working).
    /// Measured on the drawn bar, the ground centred on the ring kept the
    /// text 3 pt from its top and 1 pt from its foot, and stood 4.5 pt from
    /// the row above against 6.5 from the row below; 1 pt down evens both.
    /// It stays inside its slot, 2 pt from the next ground.
    static let groundDrop: CGFloat = 1

    /// Between a name's end and its ring.
    static let nameGap: CGFloat = 8
    /// Between the open body's inner edge and the longest name.
    static let nameInset: CGFloat = 14
    /// How far a name travels as it comes in: from under its ring's side.
    static let nameTravel: CGFloat = 10
    /// The widest a name is drawn; a longer one is cut with "…". It also caps
    /// how far the body opens. At 170 a waiting row's status line did not
    /// fit — "waiting for approval · 00 d" and an address came to 200 pt —
    /// and the amber word, the one the row is there to say, was the part
    /// cut; a name beside a long branch kept 65 pt. Now the row says the
    /// wait in one word (`StatusLine.rowKey`, widest en 73, de 75, ru 85 pt)
    /// and the box is 210: a waiting row with `255.255.255.255` (84 pt) is
    /// 174 pt at most, a name beside a capped branch keeps 105. Every point
    /// here is the screen's edge: with the card up, body, gap and card are
    /// 597 pt.
    static let nameMaxWidth: CGFloat = 210
    /// The narrowest the open body gets, so a column of short names still
    /// reads as a panel rather than a ragged tab.
    static let minOpenWidth: CGFloat = 110
    static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The small raised number after a repeated name.
    static let numberFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    /// A row's tag — a remote row's machine, an outside job's sender — after
    /// its status line: the usage block's group heading type — small
    /// capitals by hand, spaced — so a machine reads the same wherever it is
    /// named (`UsageBlock.heading`). Text, not an icon. Beside the name it
    /// took the name's room in the same box: `ml-training…  192.1….1.217`.
    static var machineFont: NSFont { UsageBlock.headerFont }
    static var machineKerning: CGFloat { UsageBlock.headerKerning }
    /// Between the status line and its tag, and a name and its branch.
    static let machineGap: CGFloat = 5
    /// The widest a tag is drawn on the status line; a longer one is cut at
    /// its end. An address's widest, `255.255.255.255`, is under it whole;
    /// `gpu-01.eu-central.internal.example.com` uncapped left the status
    /// "w…" and ran past the box on the right edge. The card names it whole.
    static let tagMaxWidth: CGFloat = 90
    /// The branch after a repeated name (`SessionRow.branch`): a size under
    /// the name, in the status line's grey. Measured in this face: at 10 pt
    /// a waiting row of `shop-api ⑂ feat/checkout-v2` came to 146 pt and
    /// was cut by the then 140 pt box; at 9 pt it is 139.
    static let branchFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    /// The widest a branch is drawn; a longer one is cut in the middle,
    /// where `feature/PROJ-1234-…` names differ least. The whole name is on
    /// the card. It leaves the name at least 64 pt of the 170 pt box.
    static let branchMaxWidth: CGFloat = 90
    /// The branch mark's box and its gap to the name.
    static let branchIconWidth: CGFloat = 8
    static let branchIconGap: CGFloat = 2
    /// How much of a dimmed row's ring is left: enough to read its phase and
    /// its mark, faint enough to sit behind every live ring.
    static let dimOpacity: Double = 0.4
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

    /// The same, for rows: a repeated name is measured with its number and
    /// its branch, and the status line under it at its widest
    /// (`statusWidth`) with the row's tag after it.
    static func namesWidth(_ rows: [SessionRow], in lang: String = L10n.language) -> CGFloat {
        let widest = rows.map { row -> CGFloat in
            var status = statusWidth(phase: row.phase, waitKind: row.waitKind,
                                     dim: row.dim?.reason, progress: row.progress != nil, in: lang)
            if let tag = row.tag { status += machineGap + min(machineWidth(tag), tagMaxWidth) }
            var name = (row.label as NSString).size(withAttributes: [.font: nameFont]).width
            if row.duplicate > 0 {
                name += numberGap
                    + ("\(row.duplicate)" as NSString).size(withAttributes: [.font: numberFont]).width
            }
            if let branch = row.branch { name += machineGap + branchWidth(branch) }
            return max(name, status)
        }.max() ?? 0
        return min(ceil(widest), nameMaxWidth)
    }

    /// The widest a row's status line can get in its phase, whatever the
    /// minutes say — the body is fitted to this, so it does not move as time
    /// passes. It changes with the phase, which rewrites the rows anyway.
    /// A dimmed row is fitted to its reason's forms instead: that is what
    /// its line says; a row with a progress to its percent's too.
    static func statusWidth(phase: Phase, waitKind: Signal.Activity.WaitKind?,
                            dim: Signal.Machine.Reason? = nil, progress: Bool = false,
                            in lang: String = L10n.language) -> CGFloat {
        let forms = dim.map { StatusLine.widestForms(dim: $0, in: lang) }
            ?? StatusLine.widestForms(phase: phase, waitKind: waitKind, progress: progress, in: lang)
        let widest = forms
            .map { ($0 as NSString).size(withAttributes: [.font: statusFont]).width }
            .max() ?? 0
        return ceil(widest)
    }

    static let numberGap: CGFloat = 2

    /// A branch as drawn: its mark and its name, the name capped at
    /// `branchMaxWidth` — the body is fitted to this, so a long branch does
    /// not open it past what a long name already could.
    static func branchWidth(_ branch: String) -> CGFloat {
        branchIconWidth + branchIconGap + min(branchTextWidth(branch), branchMaxWidth)
    }

    static func branchTextWidth(_ branch: String) -> CGFloat {
        ceil((branch as NSString).size(withAttributes: [.font: branchFont]).width)
    }

    /// The machine's name as drawn: `UsageBlock.heading`'s capitals, measured
    /// with its spacing.
    static func machineWidth(_ machine: String) -> CGFloat {
        ceil((UsageBlock.heading(machine) as NSString)
            .size(withAttributes: [.font: machineFont, .kern: machineKerning]).width)
    }

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
                SessionIndicator(phase: row.phase, source: row.source, mark: row.traits.mark,
                                 progress: row.progress,
                                 // Only a beating row sees the counter move. A
                                 // still row's trigger never changes on the
                                 // beat, so it plays nothing and draws nothing.
                                 beat: row.beats ? model.beat : 0,
                                 isLive: row.isLive, passive: row.passive,
                                 outcome: row.outcome)
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
                   height: Self.groundHeight)
            .offset(x: -mirror * Self.groundInset, y: Self.groundDrop)
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
    /// make, so the eye lands on what is doing something. A dimmed row is
    /// grey too, and its status line says why instead of its phase — never
    /// amber: an old block asks nothing of the user yet.
    ///
    /// A row's tag — its machine, or an outside job's sender — follows its
    /// status line, in the usage block's heading type: the name keeps the
    /// first line to itself.
    ///
    /// A repeated name in the same tool carries a small raised number after
    /// it — only then, so a unique name stays bare.
    ///
    /// The block is top-aligned in a fixed height, so the name sits in the
    /// same place whether the status line is in the tree or not.
    private func label(_ row: SessionRow) -> some View {
        VStack(alignment: docked, spacing: 1) {
            name(row.label, duplicate: row.duplicate, branch: row.branch,
                 color: row.phase == .idle || row.passive || !row.isLive
                 ? BarPalette.textSecondary : BarPalette.textPrimary)
            if showsNames {
                // Once a minute, and only while open. The date comes from the
                // timeline, not `Date()`, so the text is a function of it.
                TimelineView(.everyMinute) { context in
                    HStack(alignment: .firstTextBaseline, spacing: Self.machineGap) {
                        Text(verbatim: StatusLine.text(phase: row.phase, waitKind: row.waitKind,
                                                       enteredAt: row.enteredAt, dim: row.dim,
                                                       progress: row.progress, now: context.date))
                            .font(Font(Self.statusFont))
                            // Waiting is the one that asks for the user: amber,
                            // the ring's colour. The rest is grey.
                            .foregroundStyle(row.phase == .waiting && row.isLive
                                             ? SessionIndicator.amber : BarPalette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let tag = row.tag {
                            // Laid out first: the status gives way before it,
                            // since the machine is what tells two `api`s
                            // apart and the status is on the ring too. A tag
                            // past `tagMaxWidth` is cut, at its end: a host's
                            // own name is its first label, and an address cut
                            // in the middle names nothing.
                            Text(verbatim: UsageBlock.heading(tag))
                                .font(Font(Self.machineFont))
                                .kerning(Self.machineKerning)
                                .foregroundStyle(UsageBlock.headerColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: min(Self.machineWidth(tag), Self.tagMaxWidth))
                                .layoutPriority(1)
                        }
                    }
                    .frame(width: Self.nameMaxWidth, alignment: isLeft ? .leading : .trailing)
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

    private func name(_ label: String, duplicate: Int, branch: String?,
                      color: Color) -> some View {
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
            if let branch {
                // Laid out first: the branch is what tells two `shop-api`s
                // apart, so the name gives way first. Its frame is its own width up to the cap,
                // so a short branch takes no more room than it needs.
                HStack(alignment: .firstTextBaseline, spacing: Self.branchIconGap) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 7, weight: .medium))
                        .frame(width: Self.branchIconWidth)
                    Text(verbatim: branch)
                        .font(Font(Self.branchFont))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: min(Self.branchTextWidth(branch), Self.branchMaxWidth))
                }
                    .foregroundStyle(BarPalette.textSecondary)
                    .layoutPriority(1)
                    .padding(.leading, Self.machineGap - Self.numberGap)
            }
        }
            .frame(width: Self.nameMaxWidth, alignment: isLeft ? .leading : .trailing)
    }
}

/// The line under the open list: "20 sessions · 2 waiting · 3 working".
/// Waiting comes first, in amber: it is the count that asks for the user,
/// and the list's own order. Each part counts its phase on live rows alone —
/// a dimmed row's phase is the last thing a silent machine said, not
/// something known now. A part with nothing to count is gone; with no
/// session there is no line.
///
/// **The keys are literals here**, listed in `keys`, so a test reaches all of
/// them. The parts are joined two at a time with `lineKey`, which every
/// table writes as "{sessions} · {working}".
enum SummaryLine {
    static let lineKey = "summary.line"
    static let sessionsOneKey = "summary.sessions.one"
    static let sessionsKey = "summary.sessions"
    static let waitingKey = "summary.waiting"
    static let workingKey = "summary.working"
    static var keys: [String] { [lineKey, sessionsOneKey, sessionsKey, waitingKey, workingKey] }

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    struct Parts: Equatable {
        let sessions: String
        let waiting: String?
        let working: String?
    }

    static func parts(rows: [SessionRow], in lang: String) -> Parts? {
        guard !rows.isEmpty else { return nil }
        let sessions = rows.count == 1
            ? L10n.t(sessionsOneKey, in: lang)
            : L10n.t(sessionsKey, ["count": String(rows.count)], in: lang)
        func count(_ phase: Phase, _ key: String) -> String? {
            let n = rows.filter { $0.phase == phase && $0.isLive }.count
            return n == 0 ? nil : L10n.t(key, ["count": String(n)], in: lang)
        }
        return Parts(sessions: sessions, waiting: count(.waiting, waitingKey),
                     working: count(.working, workingKey))
    }

    static func text(rows: [SessionRow], in lang: String = L10n.language) -> String? {
        guard let parts = parts(rows: rows, in: lang) else { return nil }
        return [parts.waiting, parts.working].compactMap { $0 }.reduce(parts.sessions) {
            L10n.t(lineKey, ["sessions": $0, "working": $1], in: lang)
        }
    }

    /// The line as drawn: grey, the counts bolder — waiting amber, the ring's
    /// colour, working white, the same split the names make.
    static func attributed(rows: [SessionRow], in lang: String = L10n.language) -> AttributedString? {
        guard let parts = parts(rows: rows, in: lang), let line = text(rows: rows, in: lang) else {
            return nil
        }
        var out = AttributedString(line)
        out.font = Font(font)
        out.foregroundColor = BarPalette.textSecondary
        // From the end: a count's words never come before the sessions' part.
        if let working = parts.working, let range = out.range(of: working, options: .backwards) {
            out[range].font = Font(boldFont)
            out[range].foregroundColor = BarPalette.textPrimary
        }
        if let waiting = parts.waiting {
            let end = parts.working.flatMap { out.range(of: $0, options: .backwards)?.lowerBound } ?? out.endIndex
            if let range = out[out.startIndex..<end].range(of: waiting, options: .backwards) {
                out[range].font = Font(boldFont)
                out[range].foregroundColor = SessionIndicator.amber
            }
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

    /// The row's word, which is shorter than the card's: a waiting row says
    /// what it waits for in one word ("approval", "question") — the amber
    /// ring already says it waits, and the card's title keeps the whole
    /// sentence (`statusKey`). A wait of no known kind is its own key too:
    /// German's "wartet auf dich" and an address came to 219 pt. The full words with an address did not fit
    /// the row (`SessionColumn.nameMaxWidth`).
    static func rowKey(phase: Phase, waitKind: Signal.Activity.WaitKind?) -> String {
        switch (phase, waitKind) {
        case (.waiting, .approval): return "row.waiting.approval"
        case (.waiting, .answer): return "row.waiting.answer"
        case (.waiting, nil): return "row.waiting"
        default: return statusKey(phase: phase, waitKind: waitKind)
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

    /// A dimmed row's word: why it cannot be heard, in place of its phase.
    static func dimKey(_ reason: Signal.Machine.Reason) -> String {
        switch reason {
        case .disconnected: return "row.unreachable"
        case .quiet: return "row.silent"
        }
    }

    /// A dimmed row says why and for how long — "no connection · 5 min",
    /// "quiet · 40 min" — counted from when it was lost, which is always
    /// known.
    ///
    /// A row with a progress says how far in place of how long — "working ·
    /// ~40%" — with `~`: the number is the sender's claim, not Evlat's
    /// reading (`UsageBlockModel.isApproximate`, `.manual`).
    static func text(phase: Phase, waitKind: Signal.Activity.WaitKind?,
                     enteredAt: Date?, dim: Signal.Machine.Dim? = nil, progress: Int? = nil, now: Date,
                     in lang: String = L10n.language) -> String {
        if let dim {
            return L10n.t(lineKey, ["status": L10n.t(dimKey(dim.reason), in: lang),
                                    "time": duration(now.timeIntervalSince(dim.since), in: lang)],
                          in: lang)
        }
        let status = L10n.t(rowKey(phase: phase, waitKind: waitKind), in: lang)
        if let progress {
            return L10n.t(lineKey, ["status": status, "time": percent(progress, in: lang)], in: lang)
        }
        // Not seen entering the phase: how long is not known.
        guard let enteredAt else { return status }
        let time = duration(now.timeIntervalSince(enteredAt), in: lang)
        return L10n.t(lineKey, ["status": status, "time": time], in: lang)
    }

    /// Every form the line can take in this phase, with the widest counts —
    /// what the open body is fitted to.
    static func widestForms(phase: Phase, waitKind: Signal.Activity.WaitKind?,
                            progress: Bool = false, in lang: String) -> [String] {
        let status = L10n.t(rowKey(phase: phase, waitKind: waitKind), in: lang)
        let percentForm = L10n.t(lineKey, ["status": status, "time": percent(100, in: lang)], in: lang)
        return forms(of: status, in: lang) + (progress ? [percentForm] : [])
    }

    /// An outside job's progress as the line and the card say it: "~40%",
    /// "~%40" — always approximate, the sender's number (`.manual`).
    static func percent(_ value: Int, in lang: String) -> String {
        UsageText.percent(value, approximate: UsageBlockModel.isApproximate(.manual), in: lang)
    }

    /// The same, for a dimmed row's reason.
    static func widestForms(dim reason: Signal.Machine.Reason, in lang: String) -> [String] {
        forms(of: L10n.t(dimKey(reason), in: lang), in: lang)
    }

    private static func forms(of status: String, in lang: String) -> [String] {
        let times = [L10n.t(justNowKey, in: lang)]
            + Unit.allCases.map { L10n.t($0.key, ["count": $0.widestCount], in: lang) }
        return [status] + times.map { L10n.t(lineKey, ["status": status, "time": $0], in: lang) }
    }
}

/// The usage block's text: "5h", "25%", "↻ 1h 12m", "2h ago". Pure, like
/// `StatusLine`, so the minute tick only hands it a date.
///
/// **Compact units**, not the status line's "14 min": the block is a table,
/// and "1 h 12 min" would not fit its column. Every time here rounds down,
/// so a countdown never promises more than is left.
///
/// **The keys are literals**, listed in `keys`, so a test reaches all of them.
enum UsageText {
    static let pairKey = "usage.pair"
    static let percentKey = "usage.percent"
    static let resetsKey = "usage.resets"
    static let agoKey = "usage.ago"
    static var keys: [String] {
        [pairKey, percentKey, resetsKey, agoKey] + StatusLine.Unit.allCases.map(\.compactKey)
    }

    /// A span in its largest unit and, if not zero, the next one down:
    /// "4d 16h", "1h 12m", "38m", "2h". Under a minute is "0m" — a window is
    /// no longer drawn once it resets, so that is the last minute of one.
    static func compact(_ seconds: TimeInterval, in lang: String) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        func part(_ unit: StatusLine.Unit, _ count: Int) -> String {
            L10n.t(unit.compactKey, ["count": String(count)], in: lang)
        }
        let (major, minor): (StatusLine.Unit, StatusLine.Unit?) =
            s >= StatusLine.Unit.days.seconds ? (.days, .hours)
            : s >= StatusLine.Unit.hours.seconds ? (.hours, .minutes) : (.minutes, nil)
        let count = Int(s / major.seconds)
        guard let minor else { return part(major, count) }
        let rest = Int((s - Double(count) * major.seconds) / minor.seconds)
        guard rest > 0 else { return part(major, count) }
        return L10n.t(pairKey, ["first": part(major, count), "second": part(minor, rest)], in: lang)
    }

    /// The window's name, from its length: 300 → "5h", 10080 → "7d",
    /// 90 → "1h 30m". A window nobody planned for still gets one.
    static func windowLabel(minutes: Int, in lang: String = L10n.language) -> String {
        compact(TimeInterval(minutes) * 60, in: lang)
    }

    /// "↻ 1h 12m": time left until the window starts over.
    static func resets(in seconds: TimeInterval, in lang: String = L10n.language) -> String {
        L10n.t(resetsKey, ["time": compact(seconds, in: lang)], in: lang)
    }

    /// "2h ago": how old a stale reading is. One unit — an age, not a
    /// countdown to plan by.
    static func ago(_ seconds: TimeInterval, in lang: String = L10n.language) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        let unit: StatusLine.Unit = s < StatusLine.Unit.hours.seconds ? .minutes
            : s < StatusLine.Unit.days.seconds ? .hours : .days
        let time = L10n.t(unit.compactKey, ["count": String(Int(s / unit.seconds))], in: lang)
        return L10n.t(agoKey, ["time": time], in: lang)
    }

    /// "25%" — "%25" in Turkish; "~25%" when the number is Evlat's reading
    /// (`UsageBlockModel.isApproximate`). Past 100 it says so.
    static func percent(_ value: Int, approximate: Bool, in lang: String = L10n.language) -> String {
        (approximate ? "~" : "") + L10n.t(percentKey, ["value": String(value)], in: lang)
    }

    /// Every form the right-hand column can take, with the widest counts —
    /// what the column is fitted to, so it does not move as time passes.
    static func widestTails(in lang: String) -> [String] {
        let wide = "00"
        func part(_ unit: StatusLine.Unit) -> String { L10n.t(unit.compactKey, ["count": wide], in: lang) }
        let spans = [part(.minutes), part(.hours), part(.days),
                     L10n.t(pairKey, ["first": part(.hours), "second": part(.minutes)], in: lang),
                     L10n.t(pairKey, ["first": part(.days), "second": part(.hours)], in: lang)]
        return spans.map { L10n.t(resetsKey, ["time": $0], in: lang) }
            + spans.prefix(3).map { L10n.t(agoKey, ["time": $0], in: lang) }
    }

    /// The widest percent: three digits, approximate.
    static func widestPercent(in lang: String) -> String {
        percent(100, approximate: true, in: lang)
    }
}

extension StatusLine.Unit {
    /// The unit's compact form, for the usage block: "12m", "5h", "7d".
    var compactKey: String {
        switch self {
        case .minutes: return "usage.unit.minutes"
        case .hours: return "usage.unit.hours"
        case .days: return "usage.unit.days"
        }
    }
}

/// One session's ring. The phase picks the look (`AGENTS.md` → Architecture:
/// the indicator's language); the beat plays the gesture.
///
/// **A dimmed row's ring** (`isLive == false`) keeps its phase's look at
/// `SessionColumn.dimOpacity` and plays no gesture: not on the beat — it has
/// none — and not on the change into or out of dimness either, which moves
/// the trigger's beat to 0.
///
/// **A passive row's ring** (`passive`, `Registry.Layer.passive`) is the other
/// look: a grey ring — idle's — with its mark in grey; a row with no mark
/// (an outside job) shows instead a small dot of the outcome's colour. It changes the colour,
/// never the opacity, so it cannot be mistaken for a dimmed row; a row that
/// is both is grey and faint. It plays no gesture: it has been heard.
///
/// **Beats, not loops.** A spinning arc under `TimelineView` or
/// `repeatForever` is the measured ~7% floor, and a working session runs
/// for hours. So `waiting` sends one wave out of its ring per beat, still in
/// between, and `review` flares once on arrival and fades. `working` turns
/// without a stop, but not in SwiftUI: its arc is a layer Core Animation
/// turns (`SpinningArc`).
struct SessionIndicator: View {
    let phase: Phase
    var source: AgentID? = nil
    /// What sits inside the ring, from the row's kind (`RowTraits`): the
    /// tool's mark for a session, the mascot's small face for Evlat's own
    /// chat — still, the ring's beat is the one gesture — nothing for an
    /// outside job, whose ring speaks its phase alone.
    var mark: RowTraits.Mark = .tool
    /// An outside job's whole percent: a still arc filling the inside from
    /// twelve o'clock, clockwise (`ProgressFill`). With one, `working` does
    /// not turn — the fill is its movement.
    var progress: Int? = nil
    let beat: Int
    var isLive = true
    var passive = false
    /// A passive row's finish (`SessionRow.outcome`), drawn as the dot.
    var outcome: Phase? = nil

    private var size: CGFloat { AppController.indicatorSize }

    /// The phase whose gesture plays; `nil` plays none.
    private var gesture: Phase? { isLive && !passive ? phase : nil }
    /// The turn is `working`'s "how far is not known": a ring whose progress
    /// is known never turns, nor does one nobody can hear.
    private var turns: Bool { gesture == .working && progress == nil }

    var body: some View {
        ring
            .frame(width: size, height: size)
            .animation(MascotPose.transition, value: phase)
            .animation(MascotPose.transition, value: passive)
            // Hung **above** the phase-dependent drawing, never inside a
            // branch: `keyframeAnimator` fires on a *change* of its trigger and
            // never on first appearance, so a host rebuilt by a phase change
            // would miss exactly the arrival it exists for (`AGENTS.md` →
            // Pitfalls). The trigger carries the phase so arriving at
            // `review` flares, and the beat so a beating row gestures.
            .keyframeAnimator(initialValue: IndicatorGesture(),
                              trigger: IndicatorTrigger(phase: phase, beat: beat)) { view, g in
                view
                    // Behind the ring and outside it: the ring and its mark
                    // stay where they are while the wave leaves them.
                    .background { wave(g.wave) }
                    .overlay { inside }
                    .scaleEffect(g.pulse)
                    .shadow(color: glowColor.opacity(g.glow), radius: size * 0.35)
            } keyframes: { _ in
                KeyframeTrack(\.pulse) {
                    for key in IndicatorGesture.pulse(for: gesture) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
                KeyframeTrack(\.glow) {
                    for key in IndicatorGesture.glow(for: gesture) {
                        CubicKeyframe(key.value, duration: key.duration)
                    }
                }
                KeyframeTrack(\.wave) {
                    for key in IndicatorGesture.wave(for: gesture) {
                        // Linear: the ring travels at one speed; the fade
                        // below is what eases it out.
                        LinearKeyframe(key.value, duration: key.duration)
                    }
                }
            }
            // Outside the animator, so the dimmed look is one layer's opacity
            // and not a second copy of every colour.
            .opacity(isLive ? 1 : SessionColumn.dimOpacity)
            .animation(MascotPose.transition, value: isLive)
    }

    private var line: CGFloat { 1.6 }

    /// How far the wave grows past the ring, as a share of its size. 1.5 is
    /// 5 pt each side: the half gap the list and the closed column leave
    /// around a ring before they cut (`AppController.indicatorSpacing`), so
    /// the first row's wave is never clipped at the top.
    static let waveReach: CGFloat = 1.5

    /// `waiting`'s wave at `progress` (0…1): a ring of its colour leaving the
    /// ring, growing and thinning as it fades. Nothing at rest.
    @ViewBuilder private func wave(_ progress: Double) -> some View {
        if progress > 0 {
            let t = CGFloat(progress)
            Circle()
                .stroke(Self.amber, lineWidth: line * (1 - t * 0.5))
                .scaleEffect(1 + (Self.waveReach - 1) * t)
                .opacity(0.85 * (1 - t))
        }
    }

    /// The tool's mark, in the phase's colour: the ring and the mark say the
    /// same state, the mark alone says where the session runs. An outside
    /// job has no mark; its progress, if it gave one, fills the inside.
    @ViewBuilder private var inside: some View {
        if passive, let outcome, !drawsMark {
            // Only where no mark is drawn: a dot and a glyph do not both fit
            // in a 20 pt ring, and the tool's mark stays — which tool ran is
            // still worth reading on a passive row; the grey says the rest.
            Circle()
                .fill(Self.color(outcome).opacity(0.85))
                .frame(width: size * Self.outcomeDot, height: size * Self.outcomeDot)
        } else {
            mark(markColor)
        }
    }

    /// Whether `mark(_:)` draws anything: the tool's glyph, the chat's face
    /// or a job's progress.
    private var drawsMark: Bool {
        switch mark {
        case .face: return true
        case .tool: return source != nil
        case .none: return progress != nil
        }
    }

    /// The outcome dot's diameter, as a share of the ring's (`aktif-pasif.html`:
    /// r 2 in a r 8 ring).
    static let outcomeDot: CGFloat = 0.25

    @ViewBuilder private func mark(_ markColor: Color) -> some View {
        switch mark {
        case .face:
            MascotFaceMark(eye: markColor == BarPalette.textPrimary ? .black : markColor)
                .frame(width: size * 0.5, height: size * 0.5)
        case .tool:
            if let source {
                SourceGlyph(source: source)
                    .fill(markColor, style: FillStyle(eoFill: true))
                    .frame(width: size * 0.56, height: size * 0.56)
            }
        case .none:
            if let progress {
                ProgressFill(fraction: Double(progress) / 100, color: markColor)
                    .frame(width: size * 0.5, height: size * 0.5)
            }
        }
    }

    private var markColor: Color { passive ? BarPalette.textSecondary : Self.color(phase) }

    /// The phase's colour, for the mark and the outcome dot.
    static func color(_ phase: Phase) -> Color {
        switch phase {
        case .idle: return BarPalette.textSecondary
        case .working: return BarPalette.textPrimary
        case .waiting: return amber
        case .review: return green
        case .failed: return red
        }
    }

    @ViewBuilder private var ring: some View {
        if passive {
            Circle().stroke(Self.passiveGrey, lineWidth: line)
        } else {
            phaseRing
        }
    }

    /// Idle's grey: a passive ring is one with nothing left to say.
    static let passiveGrey = Color.white.opacity(0.28)

    @ViewBuilder private var phaseRing: some View {
        // Exhaustive on purpose: a new `Phase` must not compile until it has
        // a look here — and `Phase.priority` and the mascot's expression
        // table need it too.
        switch phase {
        case .idle:
            Circle().stroke(Self.passiveGrey, lineWidth: line)
        case .working:
            if progress != nil {
                // Known progress: no turning arc — a still one would read as
                // 30% — only the track, brighter, around the fill.
                Circle().stroke(Color.white.opacity(0.4), lineWidth: line)
            } else {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: line)
                    if turns {
                        // Turned by Core Animation, without a stop: a turn a
                        // beat left the arc still two seconds in three, which
                        // read as stuck.
                        SpinningArc(lineWidth: line)
                    } else {
                        // A dimmed row's: the last thing a silent machine said.
                        Circle()
                            .trim(from: 0, to: SpinningArc.length)
                            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    }
                }
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
        if passive { return .clear }
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

/// An outside job's progress inside its ring: a faint disc and, over it, a
/// wedge from twelve o'clock clockwise in the phase's colour — the ring's
/// language filled rather than turned. Still: it changes only when the whole
/// percent does (`SessionRow.progress`), and nothing animates it.
struct ProgressFill: View {
    var fraction: Double
    var color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16))
            ProgressWedge(fraction: fraction).fill(color)
        }
    }
}

/// The filled part: nothing at 0, the whole disc at 1.
struct ProgressWedge: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let f = min(1, max(0, fraction))
        let side = min(rect.width, rect.height)
        let disc = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        guard f > 0 else { return Path() }
        guard f < 1 else { return Path(ellipseIn: disc) }
        let center = CGPoint(x: disc.midX, y: disc.midY)
        var path = Path()
        path.move(to: center)
        // In SwiftUI's flipped space `clockwise: false` runs clockwise on screen.
        path.addArc(center: center, radius: side / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * f), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// `working`'s arc, turned without a stop by Core Animation. SwiftUI's own
/// continuous animations cost ~7% CPU here whatever the technique
/// (`AGENTS.md` → Rendering and CPU); a layer animation is handed to the
/// render server once and plays there, so Evlat itself is not woken per
/// frame. In the tree only while its ring turns: a still arc is SwiftUI's.
struct SpinningArc: NSViewRepresentable {
    var lineWidth: CGFloat

    /// The arc's share of the ring, as the still one draws it.
    static let length: CGFloat = 0.3
    /// Seconds per turn: calm enough to sit in the corner of the eye.
    static let period: CFTimeInterval = 1.2
    static let animationKey = "turn"

    func makeNSView(context: Context) -> SpinningArcView { SpinningArcView(lineWidth: lineWidth) }
    func updateNSView(_ view: SpinningArcView, context: Context) {}
}

final class SpinningArcView: NSView {
    private let arc = CAShapeLayer()
    private let lineWidth: CGFloat

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        arc.fillColor = nil
        arc.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        arc.lineWidth = lineWidth
        arc.lineCap = .round
        arc.strokeEnd = SpinningArc.length
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The ring takes no clicks; the column's hit-testing is geometry.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let inset = lineWidth / 2
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        arc.contentsScale = window.backingScaleFactor
        // Added once per stay in a window; a layer that left one may have
        // lost it.
        guard arc.animation(forKey: SpinningArc.animationKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        // Clockwise on screen, as the beat's turn was.
        turn.toValue = (layer?.contentsAreFlipped() ?? false) ? 2 * Double.pi : -2 * Double.pi
        turn.duration = SpinningArc.period
        turn.repeatCount = .infinity
        // A 20 pt arc reads as smooth at 30; every frame is the render
        // server's work, so it is not asked for more.
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: SpinningArc.animationKey)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        arc.contentsScale = window?.backingScaleFactor ?? arc.contentsScale
    }
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
    /// Scale of the ring.
    var pulse: Double = 1
    /// Opacity of the halo.
    var glow: Double = 0
    /// How far the wave has travelled out of the ring, 0…1; 0 draws none.
    var wave: Double = 0

    struct Key: Equatable {
        var value: Double
        /// Seconds to reach it.
        var duration: Double
    }

    /// `review`: one swell and back. `waiting` no longer swells: its mark
    /// stays still and readable while a wave leaves the ring (`wave`).
    static func pulse(for phase: Phase?) -> [Key] {
        switch phase {
        case .review: return [Key(value: 1.25, duration: 0.15), Key(value: 1, duration: 0.5)]
        case .idle, .working, .waiting, .failed, nil: return []
        }
    }

    /// `review` flares and fades — the "green, then dies away" of the
    /// indicator language, played once.
    static func glow(for phase: Phase?) -> [Key] {
        switch phase {
        case .review: return [Key(value: 1, duration: 0.15), Key(value: 0, duration: 1.6)]
        case .idle, .working, .waiting, .failed, nil: return []
        }
    }

    /// `waiting`: one wave out of the ring, then back to none at once — the
    /// last key is the rest state, drawn as nothing.
    static func wave(for phase: Phase?) -> [Key] {
        guard phase == .waiting else { return [] }
        return [Key(value: 1, duration: 1.1), Key(value: 0, duration: 0)]
    }

    /// How long the gesture keeps producing frames: the longest track.
    static func duration(for phase: Phase) -> Double {
        [pulse(for: phase), glow(for: phase), wave(for: phase)]
            .map { $0.reduce(0) { $0 + $1.duration } }
            .max() ?? 0
    }
}

/// The mascot's face, small (reference screen 5): a light rounded square,
/// two upright eyes. Drawn once and still; the ring around it does the
/// talking.
struct MascotFaceMark: View {
    /// The eyes' colour: dark on the working ring, the phase's colour on
    /// the others, so the face says the ring's state too.
    var eye: Color = .black

    var body: some View {
        GeometryReader { box in
            let side = min(box.size.width, box.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                HStack(spacing: side * 0.22) {
                    Capsule().frame(width: side * 0.13, height: side * 0.34)
                    Capsule().frame(width: side * 0.13, height: side * 0.34)
                }
                .foregroundStyle(eye == .black ? Color.black.opacity(0.9) : eye)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
