import SwiftUI
import Spool
import CounterCore

/// Replaces the old plain bar chart with Spool's activity trio: a 365-day contribution
/// heatmap, a streak strip (current + longest + recent-activity dots), and a zoomable
/// sparkline. The 7/30/90 picker only feeds the sparkline — the heatmap's span is
/// fixed (that's the point of a contribution graph) and the streak strip is inherently
/// "recent."
struct ActivityCard: View {
    let store: DataStore
    @State private var rangeDays = 30

    /// One bucket per event, not pre-aggregated — Spool sums same-day buckets itself.
    private var buckets: [DateBucket] {
        store.events.map { DateBucket(date: $0.timestamp, value: Double($0.newTokens)) }
    }

    var body: some View {
        Card(title: "Activity") {
            ContributionHeatmap(
                buckets: buckets,
                theme: Theme.spoolTheme,
                valueText: { Format.tokens(Int($0)) }
            )
            StreakStrip(buckets: buckets, theme: Theme.spoolTheme)
            Picker("Range", selection: $rangeDays) {
                Text("7d").tag(7)
                Text("30d").tag(30)
                Text("90d").tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            SparklineRow(
                title: "Tokens / day",
                buckets: buckets,
                days: rangeDays,
                theme: Theme.spoolTheme,
                valueText: { Format.tokens(Int($0)) }
            )
        }
    }
}
