import SwiftUI
import CounterCore

struct DashboardView: View {
    let store: DataStore
    @AppStorage("displayNameOverride") private var displayNameOverride = ""
    @AppStorage("blockBudgetMTok") private var blockBudgetMTok = 25.0
    @AppStorage("weeklyBudgetMTok") private var weeklyBudgetMTok = 300.0
    @State private var now = Date.now

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.hasNoData {
                    emptyState
                } else {
                    VStack(spacing: 16) {
                        header
                        gaugeRow
                        UsageOverTimeCard(store: store)
                        HStack(alignment: .top, spacing: 16) {
                            ModelBreakdownCard(slices: store.modelSlices)
                            ProjectTimeCard(slices: store.projectSlices)
                        }
                        if store.agentSlices.count > 1 {
                            AgentBreakdownCard(slices: store.agentSlices)
                        }
                        FunFactsCard(store: store)
                    }
                    .padding(20)
                }
            }
            .background(Theme.background)
            .navigationDestination(for: UsageAnalytics.ProjectSlice.self) { slice in
                ProjectDetailView(store: store, project: slice)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let refreshed = store.lastRefreshed {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
        .task {
            await store.refresh()
            // Keep the dashboard live: tick the clock and re-scan every 60s.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = .now
                await store.refresh()
            }
        }
        .navigationTitle("Counter")
    }

    // MARK: Header

    private var displayName: String {
        if !displayNameOverride.isEmpty { return displayNameOverride }
        return store.account.displayName ?? NSFullUserName()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(Theme.displayFont(30))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    if let tier = store.account.rateLimitTier {
                        Text(tier.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.accent.opacity(0.16), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                    if let email = store.account.email {
                        Text(email)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.tokens(store.totals.totalTokens))
                    .font(Theme.displayFont(30))
                    .foregroundStyle(Theme.accent)
                Text("lifetime tokens · est. \(Format.usd(store.totals.estimatedCostUSD)) equivalent")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Gauges

    private var gaugeRow: some View {
        Card(title: "Current 5-hour block") {
            HStack(spacing: 24) {
                blockUsageGauge
                blockResetGauge
                weeklyGauge
                Spacer(minLength: 0)
                blockCaption
            }
        }
    }

    private var blockTokens: Int { store.currentBlock?.totalTokens ?? 0 }
    private var blockBudget: Double { blockBudgetMTok * 1_000_000 }

    private var blockUsageGauge: some View {
        SpeedometerView(
            title: "Block usage",
            value: Double(blockTokens) / max(blockBudget, 1),
            centerLabel: Format.tokens(blockTokens),
            subLabel: "of \(Int(blockBudgetMTok))M budget"
        )
    }

    private var blockResetGauge: some View {
        let end = store.currentBlock?.end
        let remaining = end.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        return SpeedometerView(
            title: "Block resets in",
            value: 1 - (remaining / (5 * 3600)),
            centerLabel: end.map { Format.countdown(to: $0, from: now) } ?? "—",
            subLabel: end == nil ? "no active block" : "h:mm remaining",
            accent: Theme.positive
        )
    }

    private var weeklyGauge: some View {
        SpeedometerView(
            title: "This week",
            value: Double(store.tokensThisWeek) / max(weeklyBudgetMTok * 1_000_000, 1),
            centerLabel: Format.tokens(store.tokensThisWeek),
            subLabel: "of \(Int(weeklyBudgetMTok))M budget",
            accent: Theme.warning
        )
    }

    private var blockCaption: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let block = store.currentBlock {
                Text("Block opened \(block.start.formatted(date: .omitted, time: .shortened))")
                Text("Ends \(block.end.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("No usage in the current window —")
                Text("your next message opens a fresh block.")
            }
            Text("Budgets are estimates; tune them in Settings (⌘,).")
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary)
            Text("No agent sessions found")
                .font(Theme.displayFont(20))
                .foregroundStyle(Theme.textPrimary)
            Text("Counter reads Claude Code, Codex, Gemini CLI, and OpenCode session logs. Run a session, check enabled sources in Settings (⌘,), then refresh.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Button("Refresh") { Task { await store.refresh() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 500)
    }
}
