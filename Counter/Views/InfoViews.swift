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
                        Text("")
                    }
                    ForEach(slices.prefix(8)) { slice in
                        GridRow {
                            NavigationLink(value: slice) {
                                Text(slice.name)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.accent)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help("Show all history for \(slice.name)")
                            Text(Format.duration(slice.activeSeconds))
                                .font(Theme.numberFont(13))
                                .foregroundStyle(Theme.positive)
                            Text("\(slice.sessions)")
                                .font(Theme.numberFont(13))
                                .foregroundStyle(Theme.textSecondary)
                            Text(Format.tokens(slice.totalTokens))
                                .font(Theme.numberFont(13))
                                .foregroundStyle(Theme.textPrimary)
                            NavigationLink(value: slice) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
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

// MARK: - Local model usage

/// Shown when any usage came from locally served models (Ollama-style ids):
/// how much work ran locally and what it would have cost on a budget cloud model.
struct LocalUsageCard: View {
    let usage: UsageAnalytics.LocalUsage

    var body: some View {
        Card(title: "Local models") {
            HStack(spacing: 0) {
                stat(value: Format.tokens(usage.localTokens), label: "local tokens",
                     color: Theme.positive)
                divider
                stat(value: String(format: "%.0f%%", usage.localShare * 100),
                     label: "of all usage", color: Theme.accent)
                divider
                stat(value: "\(usage.localSessions)", label: "local sessions",
                     color: Theme.warning)
                divider
                stat(value: Format.usd(usage.cloudEquivalentUSD),
                     label: "est. cloud value avoided", color: Theme.positive)
            }
            Text("Models: \(usage.models.joined(separator: ", ")) — $0.00 per token. "
                 + "Cloud value priced at a haiku-class reference rate; an estimate.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.surfaceRaised)
            .frame(width: 1, height: 40)
            .padding(.horizontal, 14)
    }

    private func stat(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Theme.numberFont(17))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Fun facts strip

struct FunFactsCard: View {
    let store: DataStore

    var body: some View {
        Card(title: "Vitals") {
            HStack(spacing: 0) {
                fact(
                    icon: "arrow.triangle.2.circlepath",
                    value: Format.tokens(store.totals.cacheReadTokens),
                    label: "cache reads (reused)",
                    color: Theme.positive
                )
                .help("""
                    Context re-sent from cache on every turn, not new tokens — excluded from \
                    the lifetime total above and billed at a fraction of input price.
                    """)
                divider
                fact(
                    icon: "banknote.fill",
                    value: Format.usd(store.cacheSavingsUSD),
                    label: "saved by caching",
                    color: Theme.positive
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
