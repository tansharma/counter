import SwiftUI
import CounterCore

// MARK: - Per-project time & tokens

struct ProjectTimeCard: View {
    let slices: [UsageAnalytics.ProjectSlice]

    var body: some View {
        Card(title: "Time & tokens by project") {
            if slices.isEmpty {
                Text("No projects found.")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        header("Project")
                        header("Active time")
                        header("Sessions")
                        header("Tokens")
                    }
                    ForEach(slices.prefix(8)) { slice in
                        GridRow {
                            Text(slice.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(Format.duration(slice.activeSeconds))
                                .font(Theme.numberFont(13))
                                .foregroundStyle(Theme.positive)
                            Text("\(slice.sessions)")
                                .font(Theme.numberFont(13))
                                .foregroundStyle(Theme.textSecondary)
                            Text(Format.tokens(slice.totalTokens))
                                .font(Theme.numberFont(13))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Fun facts strip

struct FunFactsCard: View {
    let store: DataStore

    var body: some View {
        Card(title: "Vitals") {
            HStack(spacing: 0) {
                fact(
                    icon: "bolt.horizontal.circle.fill",
                    value: String(format: "%.0f%%", store.cacheEfficiency * 100),
                    label: "cache hit rate",
                    color: Theme.positive
                )
                divider
                fact(
                    icon: "banknote.fill",
                    value: Format.usd(store.cacheSavingsUSD),
                    label: "saved by caching",
                    color: Theme.positive
                )
                divider
                fact(
                    icon: "flame.fill",
                    value: "\(store.streakDays)d",
                    label: "current streak",
                    color: Theme.accent
                )
                divider
                fact(
                    icon: "square.stack.3d.up.fill",
                    value: "\(store.totals.sessions)",
                    label: "total sessions",
                    color: Theme.warning
                )
                divider
                fact(
                    icon: "gauge.high",
                    value: store.busiestDay.map { Format.tokens($0.totalTokens) } ?? "—",
                    label: busiestDayLabel,
                    color: Theme.accent
                )
            }
        }
    }

    private var busiestDayLabel: String {
        guard let day = store.busiestDay?.day else { return "busiest day" }
        return "best: " + day.formatted(.dateTime.day().month(.abbreviated))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.surfaceRaised)
            .frame(width: 1, height: 40)
            .padding(.horizontal, 14)
    }

    private func fact(icon: String, value: String, label: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(Theme.numberFont(17))
                    .foregroundStyle(Theme.textPrimary)
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
