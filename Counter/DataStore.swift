import Foundation
import Observation
import CounterCore

/// Owns the parsed usage data and account profile. Read-only over ~/.claude;
/// refreshes on demand and on a 60-second cadence driven by the dashboard view.
@MainActor
@Observable
final class DataStore {

    private(set) var events: [UsageEvent] = []
    private(set) var account = AccountInfo()
    private(set) var lastRefreshed: Date?
    private(set) var isLoading = false

    /// True when the ~/.claude/projects folder is missing or empty.
    var hasNoData: Bool { !isLoading && events.isEmpty }

    private let projectsRoot: URL
    private let claudeJson: URL

    init(
        projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        claudeJson: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    ) {
        self.projectsRoot = projectsRoot
        self.claudeJson = claudeJson
    }

    func refresh() async {
        isLoading = true
        let root = projectsRoot
        let accountFile = claudeJson
        // Parsing 100MB+ of JSONL belongs off the main thread.
        let (parsed, info) = await Task.detached(priority: .userInitiated) {
            (SessionLogParser.parseAll(projectsRoot: root),
             SessionLogParser.parseAccountInfo(claudeJson: accountFile))
        }.value
        events = parsed
        account = info
        lastRefreshed = .now
        isLoading = false
    }

    // MARK: Derived slices (thin passthroughs — the maths lives in CounterCore)
    var totals: UsageAnalytics.Totals { UsageAnalytics.totals(events) }
    var modelSlices: [UsageAnalytics.ModelSlice] { UsageAnalytics.byModel(events) }
    var projectSlices: [UsageAnalytics.ProjectSlice] { UsageAnalytics.byProject(events) }
    var currentBlock: UsageAnalytics.Block? { UsageAnalytics.currentBlock(events, now: .now) }
    var streakDays: Int { UsageAnalytics.currentStreakDays(events) }
    var cacheEfficiency: Double { UsageAnalytics.cacheEfficiency(events) }
    var cacheSavingsUSD: Double { UsageAnalytics.totalCacheSavingsUSD(events) }
    var busiestDay: UsageAnalytics.DayBucket? { UsageAnalytics.busiestDay(events) }

    func dailySeries(days: Int) -> [UsageAnalytics.DayBucket] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        return UsageAnalytics.dailySeries(events).filter { $0.day >= cutoff }
    }

    /// Tokens used in the current UK week (Monday start) — feeds the weekly gauge.
    var tokensThisWeek: Int {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else { return 0 }
        return events.filter { $0.timestamp >= weekStart }.reduce(0) { $0 + $1.totalTokens }
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
