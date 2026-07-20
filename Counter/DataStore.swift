import Foundation
import Observation
import CounterCore

/// Owns the parsed usage data and account profile. Read-only over each agent's
/// session directory; refreshes on demand and on a 60-second cadence driven by
/// the dashboard view.
@MainActor
@Observable
final class DataStore {

    private(set) var events: [UsageEvent] = []
    private(set) var account = AccountInfo()
    private(set) var lastRefreshed: Date?
    private(set) var isLoading = false
    /// Agents whose session directory exists on this machine (drives Settings labels).
    private(set) var detectedAgents: Set<AgentSource> = []

    /// True when no enabled source has any session data.
    var hasNoData: Bool { !isLoading && events.isEmpty }

    private let home: URL
    private let claudeJson: URL

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        claudeJson: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    ) {
        self.home = home
        self.claudeJson = claudeJson
    }

    /// UserDefaults key backing each source's Settings toggle. Defaults to enabled;
    /// sources without a data directory simply parse nothing.
    static func settingsKey(for agent: AgentSource) -> String {
        "source_\(agent.rawValue)_enabled"
    }

    static func isEnabled(_ agent: AgentSource) -> Bool {
        UserDefaults.standard.object(forKey: settingsKey(for: agent)) as? Bool ?? true
    }

    var enabledAgents: Set<AgentSource> {
        Set(AgentSource.allCases.filter { Self.isEnabled($0) })
    }

    func refresh() async {
        // Two scenes drive refresh (dashboard + menu bar); drop overlapping calls
        // so a slow parse can't be re-entered before it finishes.
        guard !isLoading else { return }
        isLoading = true
        let root = home
        let accountFile = claudeJson
        let enabled = enabledAgents
        // Parsing 100MB+ of JSONL belongs off the main thread.
        let (parsed, info, detected) = await Task.detached(priority: .userInitiated) {
            (UsageCollector.parseAll(enabled: enabled, home: root),
             SessionLogParser.parseAccountInfo(claudeJson: accountFile),
             UsageCollector.detectedAgents(home: root))
        }.value
        events = parsed
        account = info
        detectedAgents = detected
        lastRefreshed = .now
        isLoading = false
    }

    // MARK: Derived slices (thin passthroughs — the maths lives in CounterCore)
    var totals: UsageAnalytics.Totals { UsageAnalytics.totals(events) }
    var modelSlices: [UsageAnalytics.ModelSlice] { UsageAnalytics.byModel(events) }
    var projectSlices: [UsageAnalytics.ProjectSlice] { UsageAnalytics.byProject(events) }
    var agentSlices: [UsageAnalytics.AgentSlice] { UsageAnalytics.byAgent(events) }
    var localUsage: UsageAnalytics.LocalUsage? { UsageAnalytics.localUsage(events) }
    /// Only Claude Code has a 5-hour block / weekly rate limit, so the reset countdown
    /// ("Claude Block Reset") must ignore Codex/Gemini/OpenCode usage even though every
    /// other stat in the app — including Session Usage / This Week's token counts —
    /// aggregates all enabled sources. Scoping lives in `UsageAnalytics.AgentScope`.
    var currentBlock: UsageAnalytics.Block? {
        UsageAnalytics.currentBlock(events, scope: .claudeOnly, now: .now)
    }
    /// Same 5-hour-block reconstruction, but over every enabled source — feeds Session
    /// Usage's new/cache-read composition, which isn't a rate-limit proxy anymore and has
    /// no reason to exclude Codex/Gemini/OpenCode.
    var currentBlockAllAgents: UsageAnalytics.Block? {
        UsageAnalytics.currentBlock(events, scope: .allEnabled, now: .now)
    }
    var cacheSavingsUSD: Double { UsageAnalytics.totalCacheSavingsUSD(events) }
    var busiestDay: UsageAnalytics.DayBucket? { UsageAnalytics.busiestDay(events) }

    // MARK: Project drill-down

    func events(forProject path: String) -> [UsageEvent] {
        events.filter { $0.projectPath == path }
    }

    func sessionSummaries(forProject path: String) -> [UsageAnalytics.SessionSummary] {
        UsageAnalytics.sessionSummaries(forProject: path, in: events)
    }

    /// Today's bucket (tokens + estimated cost), or nil if nothing today — feeds the
    /// menu-bar dropdown. Reuses `dailySeries`; no new analytics.
    var today: UsageAnalytics.DayBucket? {
        let start = Calendar.current.startOfDay(for: .now)
        return UsageAnalytics.dailySeries(events).first { $0.day == start }
    }

    func dailySeries(days: Int) -> [UsageAnalytics.DayBucket] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        return UsageAnalytics.dailySeries(events).filter { $0.day >= cutoff }
    }

    /// Every enabled source's events from the current week (Monday start) — feeds This
    /// Week's composition, same reasoning as `currentBlockAllAgents` above.
    var weeklyTokens: UsageAnalytics.WeeklyTokens {
        UsageAnalytics.weeklyTokens(events, scope: .allEnabled, now: .now)
    }
}

// MARK: - Formatting helpers shared by the views

enum Format {
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000_000...: String(format: "%.2fB", Double(count) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.1fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }

    static func usd(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func countdown(to date: Date, from now: Date = .now) -> String {
        let remaining = max(0, date.timeIntervalSince(now))
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }
}
