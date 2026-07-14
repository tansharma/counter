import SwiftUI
import CounterCore

/// Drill-down for one project: totals, usage over time, model/agent breakdowns,
/// and the full session history — everything filtered to the project's events.
struct ProjectDetailView: View {
    let store: DataStore
    let project: UsageAnalytics.ProjectSlice
    @State private var rangeDays = 30

    private var events: [UsageEvent] { store.events(forProject: project.path) }

    var body: some View {
        let events = self.events
        ScrollView {
            VStack(spacing: 16) {
                header(events)
                usageOverTime(events)
                HStack(alignment: .top, spacing: 16) {
                    ModelBreakdownCard(slices: UsageAnalytics.byModel(events))
                    AgentBreakdownCard(slices: UsageAnalytics.byAgent(events))
                }
                sessionHistory
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle(project.name)
    }

    // MARK: Header

    private func header(_ events: [UsageEvent]) -> some View {
        let totals = UsageAnalytics.totals(events)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(Theme.displayFont(26))
                    .foregroundStyle(Theme.textPrimary)
                Text(
                    project.isUnresolvedGeminiProject
                        ? "Gemini didn't record a project folder for this session — usage is grouped by hash until it does."
                        : project.path
                )
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
            HStack(spacing: 0) {
                stat(value: Format.tokens(totals.totalTokens), label: "total tokens")
                divider
                stat(value: Format.usd(totals.estimatedCostUSD), label: "est. cost equivalent")
                divider
                stat(value: "\(totals.sessions)", label: "sessions")
                divider
                stat(value: Format.duration(project.activeSeconds), label: "active time")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.surfaceRaised)
            .frame(width: 1, height: 36)
            .padding(.horizontal, 14)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Theme.numberFont(17))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Usage over time

    private func usageOverTime(_ events: [UsageEvent]) -> some View {
        Card(title: "Usage over time") {
            Picker("Range", selection: $rangeDays) {
                Text("7d").tag(7)
                Text("30d").tag(30)
                Text("90d").tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            let cutoff = Calendar.current.date(
                byAdding: .day, value: -rangeDays, to: .now) ?? .distantPast
            TokensBarChart(
                series: UsageAnalytics.dailySeries(events).filter { $0.day >= cutoff })
        }
    }

    // MARK: Session history

    private var sessionHistory: some View {
        let summaries = store.sessionSummaries(forProject: project.path)
        return Card(title: "Session history") {
            if summaries.isEmpty {
                Text("No sessions recorded for this project.")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        header("Agent")
                        header("Started")
                        header("Active")
                        header("Models")
                        header("Tokens")
                        header("Est. cost")
                    }
                    ForEach(summaries.prefix(50)) { summary in
                        GridRow {
                            Text(summary.agent.displayName)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    agentColor(summary.agent).opacity(0.16), in: Capsule())
                                .foregroundStyle(agentColor(summary.agent))
                            Text(summary.start.formatted(
                                date: .abbreviated, time: .shortened))
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Format.duration(summary.activeSeconds))
                                .font(Theme.numberFont(12))
                                .foregroundStyle(Theme.positive)
                            Text(summary.models.map(prettyModelName).joined(separator: ", "))
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                            Text(Format.tokens(summary.totalTokens))
                                .font(Theme.numberFont(12))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Format.usd(summary.estimatedCostUSD))
                                .font(Theme.numberFont(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                if summaries.count > 50 {
                    Text("Showing the 50 most recent of \(summaries.count) sessions.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
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
