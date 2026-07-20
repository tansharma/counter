import SwiftUI
import CounterCore

struct DashboardView: View {
    let store: DataStore
    @AppStorage("displayNameOverride") private var displayNameOverride = ""
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
                        ActivityCard(store: store)
                        HStack(alignment: .top, spacing: 16) {
                            ModelBreakdownCard(slices: store.modelSlices)
                            ProjectTimeCard(slices: store.projectSlices)
                        }
                        if store.agentSlices.count > 1 {
                            AgentBreakdownCard(slices: store.agentSlices)
                        }
                        if let local = store.localUsage {
                            LocalUsageCard(usage: local)
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
                Text("lifetime tokens (new) · est. \(Format.usd(store.totals.estimatedCostUSD)) equiv.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .help("""
                        Input + output + cache-creation tokens, across all time and all \
                        enabled sources. Cache-read tokens (context re-sent from cache on \
                        every turn) are tracked separately in Vitals below, and in the \
                        Session Usage / This Week gauges, not counted here.
                        """)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Gauges

    private var gaugeRow: some View {
        Card {
            HStack(spacing: 24) {
                blockUsageGauge
                blockResetGauge
                weeklyGauge
                Spacer(minLength: 0)
                blockCaption
            }
            .help("""
                Session Usage and This Week sum every enabled source — Codex, Gemini CLI, \
                and OpenCode all count here. Each ring shows new tokens vs. cache-read \
                (context re-sent from cache on every turn); a long session can rack up a \
                huge cache-read share while staying tiny in genuinely new tokens. Claude \
                Block Reset is the one gauge that's still Claude Code only, since only \
                Anthropic's plans have this kind of rate-limit window to count down.
                """)
        }
    }

    private var blockUsageGauge: some View {
        let block = store.currentBlockAllAgents
        let newTokens = block?.newTokens ?? 0
        let cacheReadTokens = (block?.totalTokens ?? 0) - newTokens
        return SpeedometerView(
            title: "Session Usage",
            value: 1,
            centerLabel: Format.tokens(newTokens),
            subLabel: "",
            accent: Theme.positive,
            innerValue: block?.newShare ?? 0,
            innerAccent: Theme.accent,
            showsLegend: true,
            innerLegendValue: Format.tokens(newTokens),
            outerLegendValue: Format.tokens(cacheReadTokens)
        )
    }

    /// No needle, so progress reads as a two-phase fill instead: the first 3.5h fill in
    /// `Theme.accent` (elapsed, growing left-to-right) up to the 70% mark, then the
    /// final 1.5h fill in `Theme.positive` (imminent reset) from there onward — reusing
    /// the same two-segment mechanic as the composition gauges, just with a fixed
    /// threshold instead of a data-driven share.
    private var blockResetGauge: some View {
        let end = store.currentBlock?.end
        let remaining = end.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let blockLength: Double = 5 * 3600
        return SpeedometerView(
            title: "Claude Block Reset",
            value: 1 - (remaining / blockLength),
            centerLabel: end.map { Format.countdown(to: $0, from: now) } ?? "—",
            subLabel: end == nil ? "no active block" : "h:mm remaining",
            accent: Theme.positive,
            innerValue: 1 - (1.5 * 3600 / blockLength),
            innerAccent: Theme.accent
        )
    }

    private var weeklyGauge: some View {
        let weekly = store.weeklyTokens
        let cacheReadTokens = weekly.totalTokens - weekly.newTokens
        return SpeedometerView(
            title: "This week",
            value: 1,
            centerLabel: Format.tokens(weekly.newTokens),
            subLabel: "",
            accent: Theme.positive,
            innerValue: weekly.newShare,
            innerAccent: Theme.accent,
            showsLegend: true,
            innerLegendValue: Format.tokens(weekly.newTokens),
            outerLegendValue: Format.tokens(cacheReadTokens)
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
