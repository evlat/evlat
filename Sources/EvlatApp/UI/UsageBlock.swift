import SwiftUI
import EvlatCore

/// The usage block under the open list: a heading per group, a line per
/// window — `5h ━━━━ 25%  ↻ 1h 12m`.
///
/// **It draws what the model holds and branches on nothing else.** No
/// provider, group or window is named here: a new source is a new group
/// drawn by this same code (R8).
///
/// It is in the tree **only while the bar is open** (`BarBody`), and so is
/// its minute tick: the same rule as the status line, since behind an
/// opacity the tick would run on the closed bar too. Nothing on the closed
/// bar observes `UsageBlockModel`.
///
/// Every row shares one set of column widths, measured from the widest forms
/// the columns can take (`columns`), so the meters start and end at the same
/// x in every group and nothing moves as the minutes pass. The digits are of
/// one width (`lineFont`).
struct UsageBlock: View {
    @ObservedObject var model: UsageBlockModel
    var edge: BarPanel.Edge = .right
    /// The open body's width, which the block spans.
    var width: CGFloat

    /// The line's type: the status line's size, one weight up, digits of one
    /// width.
    static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    /// The group's heading: small capitals by hand, spaced.
    static let headerFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    static let headerKerning: CGFloat = 0.8
    static let columnGap: CGFloat = 6
    /// The meter stretches; this is the least it gets.
    static let meterMinWidth: CGFloat = 24
    static let meterHeight: CGFloat = 3

    /// The bar's greys, one step apart: the heading quieter than the
    /// window's name, the percent brighter — it is what is read.
    static let headerColor = BarPalette.textSecondary.opacity(0.72)
    static let labelColor = BarPalette.textSecondary
    static let percentColor = Color.white.opacity(0.74)
    static let tailColor = BarPalette.textSecondary
    static let track = Color.white.opacity(0.15)
    static let fill = Color.white.opacity(0.55)
    /// A stale reading: its number and its age sink toward the body.
    static let staleText = Color.white.opacity(0.30)
    static let staleFill = Color.white.opacity(0.23)
    /// The body's own hairline tone (`BarBody.shapeLayer`).
    static let hairline = Color.white.opacity(0.10)

    struct Columns: Equatable {
        var label: CGFloat
        var percent: CGFloat
        var tail: CGFloat
    }

    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: lineFont]).width)
    }

    private static func headerWidth(_ group: String) -> CGFloat {
        ceil((heading(group) as NSString)
            .size(withAttributes: [.font: headerFont, .kern: headerKerning]).width)
    }

    /// The heading's text. `uppercased()` without a locale on purpose: under
    /// Turkish rules "Gemini" would become "GEMİNİ", and a group is a proper
    /// name, not text of ours.
    static func heading(_ group: String) -> String { group.uppercased() }

    /// The label column is as wide as the widest window name drawn; the
    /// percent and the right-hand column as wide as their widest forms, so
    /// they hold whatever the numbers say.
    static func columns(lines: [UsageLine], in lang: String = L10n.language) -> Columns {
        let labels = lines.compactMap { line -> String? in
            guard case .window(let window) = line else { return nil }
            return UsageText.windowLabel(minutes: window.windowMinutes, in: lang)
        }
        return Columns(label: labels.map(textWidth).max() ?? 0,
                       percent: textWidth(UsageText.widestPercent(in: lang)),
                       tail: UsageText.widestTails(in: lang).map(textWidth).max() ?? 0)
    }

    /// The narrowest open body that holds these lines: the rings' inset on
    /// the docked side, the names' on the other, and the columns with the
    /// meter at its least between. Zero with no line.
    static func minWidth(lines: [UsageLine], in lang: String = L10n.language) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        let c = columns(lines: lines, in: lang)
        let row = c.label + meterMinWidth + c.percent + c.tail + 3 * columnGap
        let headers = lines.compactMap { line -> CGFloat? in
            guard case .header(let group) = line else { return nil }
            return headerWidth(group)
        }
        return max(row, headers.max() ?? 0) + SessionColumn.ringLead + SessionColumn.nameInset
    }

    private var isLeft: Bool { edge.isLeft }

    var body: some View {
        if !model.lines.isEmpty {
            let columns = Self.columns(lines: model.lines)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(Self.hairline)
                    .frame(height: 1)
                    .padding(.bottom, AppController.usageInset - 1)
                // Once a minute, and only while open. The date comes from the
                // timeline, not `Date()`, so every line is a function of it.
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.lines) { line in
                            switch line {
                            case .header(let group): header(group)
                            case .window(let window): row(window, columns: columns, now: context.date)
                            }
                        }
                    }
                }
            }
            // The rings' inset on the docked side, the names' on the other —
            // the summary's and the names' own edges.
            .padding(.leading, isLeft ? SessionColumn.ringLead : SessionColumn.nameInset)
            .padding(.trailing, isLeft ? SessionColumn.nameInset : SessionColumn.ringLead)
            .frame(width: width, alignment: .leading)
            .allowsHitTesting(false)
        }
    }

    /// Sat on the line's foot, so it is nearer its own windows than the group
    /// above.
    private func header(_ group: String) -> some View {
        Text(verbatim: Self.heading(group))
            .font(Font(Self.headerFont))
            .kerning(Self.headerKerning)
            .foregroundStyle(Self.headerColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .padding(.bottom, 1)
            .frame(height: AppController.usageLineHeight, alignment: .bottom)
    }

    private func row(_ window: UsageWindow, columns: Columns, now: Date) -> some View {
        let freshness = UsageBlockModel.freshness(observedAt: window.observedAt,
                                                  resetsAt: window.resetsAt, now: now)
        // A window past its reset is dropped by the model within a poll; until
        // then it is drawn as the old number it is.
        let fresh = freshness == .fresh
        let hot = UsageBlockModel.isHot(window, freshness: freshness)
        let tail = fresh
            ? UsageText.resets(in: window.resetsAt.timeIntervalSince(now))
            : UsageText.ago(now.timeIntervalSince(window.observedAt))
        return HStack(spacing: Self.columnGap) {
            Text(verbatim: UsageText.windowLabel(minutes: window.windowMinutes))
                .foregroundStyle(Self.labelColor)
                .frame(width: columns.label, alignment: .leading)
            Meter(fraction: Double(window.percent) / 100,
                  fill: hot ? SessionIndicator.amber : fresh ? Self.fill : Self.staleFill)
            Text(verbatim: UsageText.percent(window.percent,
                                             approximate: UsageBlockModel.isApproximate(window.fidelity)))
                .foregroundStyle(hot ? SessionIndicator.amber : fresh ? Self.percentColor : Self.staleText)
                .frame(width: columns.percent, alignment: .trailing)
            Text(verbatim: tail)
                .foregroundStyle(fresh ? Self.tailColor : Self.staleText)
                .frame(width: columns.tail, alignment: .trailing)
        }
        .font(Font(Self.lineFont))
        .lineLimit(1)
        .frame(height: AppController.usageLineHeight)
    }

    /// A 3 pt line with round ends: the track, and the used part over it —
    /// never past full, and never shorter than its own round ends while
    /// anything is used.
    private struct Meter: View {
        let fraction: Double
        let fill: Color

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageBlock.track)
                    if fraction > 0 {
                        Capsule()
                            .fill(fill)
                            .frame(width: max(UsageBlock.meterHeight,
                                              proxy.size.width * CGFloat(min(1, fraction))))
                    }
                }
            }
            .frame(minWidth: UsageBlock.meterMinWidth)
            .frame(height: UsageBlock.meterHeight)
        }
    }
}
