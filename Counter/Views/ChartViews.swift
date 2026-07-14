import SwiftUI
import Charts
import CounterCore

// MARK: - Usage over time

/// The daily-tokens bar chart body, shared by the dashboard card and the
/// project drill-down.
struct TokensBarChart: View {
    let series: [UsageAnalytics.DayBucket]

    var body: some View {
        if series.isEmpty {
            Text("No usage in this range.")
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            Chart(series) { bucket in
                BarMark(
                    x: .value("Day", bucket.day, unit: .day),
                    y: .value("Tokens", bucket.totalTokens)
                )
                .foregroundStyle(Theme.accent.gradient)
                .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { axisValue in
                    AxisGridLine().foregroundStyle(Theme.surfaceRaised)
                    AxisValueLabel {
                        if let tokens = axisValue.as(Int.self) {
                            Text(Format.tokens(tokens))
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }
}

struct UsageOverTimeCard: View {
    let store: DataStore
    @State private var rangeDays = 30

    var body: some View {
        Card(title: "Usage over time") {
            Picker("Range", selection: $rangeDays) {
                Text("7d").tag(7)
                Text("30d").tag(30)
                Text("90d").tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            TokensBarChart(series: store.dailySeries(days: rangeDays))
        }
    }
}

// MARK: - Breakdown rows shared by the model and agent cards

/// One labelled share bar: dot, name, tokens, cost, and a capsule proportional
/// to the slice's share of the grand total.
struct BreakdownRow: View {
    let color: Color
    let label: String
    let totalTokens: Int
    let estimatedCostUSD: Double
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(Format.tokens(totalTokens))
                    .font(Theme.numberFont(13))
                    .foregroundStyle(Theme.textPrimary)
                Text(Format.usd(estimatedCostUSD))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 64, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceRaised)
                    Capsule().fill(color.gradient)
                        .frame(width: max(proxy.size.width * share, 4))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Model breakdown

struct ModelBreakdownCard: View {
    let slices: [UsageAnalytics.ModelSlice]

    private var grandTotal: Int { max(slices.reduce(0) { $0 + $1.totalTokens }, 1) }

    var body: some View {
        Card(title: "By model") {
            if slices.isEmpty {
                Text("No model usage yet.")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    BreakdownRow(
                        color: Theme.series[index % Theme.series.count],
                        label: prettyModelName(slice.model)
                            + (Pricing.isLocalModel(slice.model) ? " · local" : ""),
                        totalTokens: slice.totalTokens,
                        estimatedCostUSD: slice.estimatedCostUSD,
                        share: Double(slice.totalTokens) / Double(grandTotal)
                    )
                }
            }
        }
    }
}

/// Human-friendly model label shared by the breakdown card and drill-down rows.
func prettyModelName(_ id: String) -> String {
    id.replacingOccurrences(of: "claude-", with: "")
        .split(separator: "-")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

// MARK: - Agent breakdown

struct AgentBreakdownCard: View {
    let slices: [UsageAnalytics.AgentSlice]

    private var grandTotal: Int { max(slices.reduce(0) { $0 + $1.totalTokens }, 1) }

    var body: some View {
        Card(title: "By agent") {
            if slices.isEmpty {
                Text("No agent usage yet.")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    BreakdownRow(
                        color: agentColor(slice.agent),
                        label: "\(slice.agent.displayName) · \(slice.sessions) sessions",
                        totalTokens: slice.totalTokens,
                        estimatedCostUSD: slice.estimatedCostUSD,
                        share: Double(slice.totalTokens) / Double(grandTotal)
                    )
                }
            }
        }
    }
}

/// Stable per-agent tint used by the breakdown card and session-history badges —
/// keyed off `AgentSource.chartColorIndex` (CounterCore) so it stays stable even if
/// a new agent is inserted before existing ones in `allCases`.
func agentColor(_ agent: AgentSource) -> Color {
    Theme.series[agent.chartColorIndex % Theme.series.count]
}

// MARK: - Shared card chrome

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                    .kerning(1.2)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
