import Foundation

/// Which agents' events an aggregate should include. Independent of, and never to be
/// conflated with, `UsageEvent.totalTokens` vs `.newTokens` (whether cache-read tokens
/// count) — those two axes combine freely, and which gauge uses which combination is a
/// deliberate product decision (see call sites of `currentBlock`/`weeklyTokens`).
public enum AgentScope: Sendable {
    /// Only Claude Code events. Anthropic's 5-hour rate-limit window is a Claude-only
    /// concept, so only a gauge proxying that real limit should use this.
    case claudeOnly
    /// Every event regardless of agent — the default for aggregates not tied to a
    /// specific agent's rate limit.
    case allEnabled

    fileprivate func apply(_ events: [UsageEvent]) -> [UsageEvent] {
        switch self {
        case .claudeOnly: events.filter { $0.agent == .claude }
        case .allEnabled: events
        }
    }
}

/// Pure aggregation over parsed usage events. Everything here is deterministic and
/// takes `now`/`calendar` as parameters so tests can pin them.
public enum UsageAnalytics {

    // MARK: Aggregates

    public struct Totals: Equatable, Sendable {
        public let events: Int
        public let sessions: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheCreationTokens: Int
        public let cacheReadTokens: Int
        public let estimatedCostUSD: Double
        /// New tokens only (excludes cache reads) — see `UsageEvent.newTokens`.
        public var totalTokens: Int {
            inputTokens + outputTokens + cacheCreationTokens
        }
    }

    public static func totals(_ events: [UsageEvent]) -> Totals {
        Totals(
            events: events.count,
            sessions: Set(events.map(\.sessionId)).count,
            inputTokens: events.reduce(0) { $0 + $1.inputTokens },
            outputTokens: events.reduce(0) { $0 + $1.outputTokens },
            cacheCreationTokens: events.reduce(0) { $0 + $1.cacheCreationTokens },
            cacheReadTokens: events.reduce(0) { $0 + $1.cacheReadTokens },
            estimatedCostUSD: events.reduce(0) { $0 + Pricing.estimatedCostUSD(for: $1) }
        )
    }

    public struct ModelSlice: Equatable, Identifiable, Sendable {
        public var id: String { model }
        public let model: String
        public let totalTokens: Int
        public let outputTokens: Int
        public let estimatedCostUSD: Double
    }

    /// Per-model breakdown, largest total first.
    public static func byModel(_ events: [UsageEvent]) -> [ModelSlice] {
        Dictionary(grouping: events, by: \.model)
            .map { model, group in
                ModelSlice(
                    model: model,
                    totalTokens: group.reduce(0) { $0 + $1.newTokens },
                    outputTokens: group.reduce(0) { $0 + $1.outputTokens },
                    estimatedCostUSD: group.reduce(0) { $0 + Pricing.estimatedCostUSD(for: $1) }
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    public struct AgentSlice: Equatable, Identifiable, Sendable {
        public var id: String { agent.rawValue }
        public let agent: AgentSource
        public let totalTokens: Int
        public let outputTokens: Int
        public let sessions: Int
        public let estimatedCostUSD: Double
    }

    /// Per-agent breakdown, largest total first.
    public static func byAgent(_ events: [UsageEvent]) -> [AgentSlice] {
        Dictionary(grouping: events, by: \.agent)
            .map { agent, group in
                AgentSlice(
                    agent: agent,
                    totalTokens: group.reduce(0) { $0 + $1.newTokens },
                    outputTokens: group.reduce(0) { $0 + $1.outputTokens },
                    sessions: Set(group.map(\.sessionId)).count,
                    estimatedCostUSD: group.reduce(0) { $0 + Pricing.estimatedCostUSD(for: $1) }
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: Local vs cloud

    public struct LocalUsage: Equatable, Sendable {
        public let localTokens: Int
        public let localOutputTokens: Int
        public let localEvents: Int
        public let localSessions: Int
        /// Local tokens as a share of all tokens (0...1).
        public let localShare: Double
        /// What the local tokens would have cost on a budget cloud model.
        public let cloudEquivalentUSD: Double
        /// Distinct local model ids, largest token share first.
        public let models: [String]
    }

    /// Aggregates locally served model usage (Ollama-style ids), or nil when none.
    public static func localUsage(_ events: [UsageEvent]) -> LocalUsage? {
        let local = events.filter { Pricing.isLocalModel($0.model) }
        guard !local.isEmpty else { return nil }
        let allTokens = events.reduce(0) { $0 + $1.newTokens }
        let localTokens = local.reduce(0) { $0 + $1.newTokens }
        let tokensByModel = Dictionary(grouping: local, by: \.model)
            .mapValues { $0.reduce(0) { $0 + $1.newTokens } }
        return LocalUsage(
            localTokens: localTokens,
            localOutputTokens: local.reduce(0) { $0 + $1.outputTokens },
            localEvents: local.count,
            localSessions: Set(local.map(\.sessionId)).count,
            localShare: allTokens > 0 ? Double(localTokens) / Double(allTokens) : 0,
            cloudEquivalentUSD: local.reduce(0) { $0 + Pricing.cloudEquivalentUSD(for: $1) },
            models: tokensByModel.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map(\.key)
        )
    }

    public struct DayBucket: Equatable, Identifiable, Sendable {
        public var id: Date { day }
        public let day: Date
        public let totalTokens: Int
        public let estimatedCostUSD: Double
    }

    /// Tokens per calendar day, ascending.
    public static func dailySeries(_ events: [UsageEvent], calendar: Calendar = .current) -> [DayBucket] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.timestamp) }
            .map { day, group in
                DayBucket(
                    day: day,
                    totalTokens: group.reduce(0) { $0 + $1.newTokens },
                    estimatedCostUSD: group.reduce(0) { $0 + Pricing.estimatedCostUSD(for: $1) }
                )
            }
            .sorted { $0.day < $1.day }
    }

    // MARK: Projects

    public struct ProjectSlice: Equatable, Hashable, Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let name: String
        public let totalTokens: Int
        public let activeSeconds: TimeInterval
        public let sessions: Int

        /// True when `path` is a Gemini unresolved-hash placeholder rather than a
        /// real project directory — see `GeminiSessionParser.unresolvedHash(from:)`.
        public var isUnresolvedGeminiProject: Bool {
            GeminiSessionParser.unresolvedHash(from: path) != nil
        }
    }

    /// Per-project totals plus "active time": the sum of gaps between consecutive
    /// events in the same project, with each gap capped (idle periods don't count).
    public static func byProject(
        _ events: [UsageEvent],
        gapCap: TimeInterval = 300
    ) -> [ProjectSlice] {
        Dictionary(grouping: events, by: \.projectPath)
            .map { path, group in
                let sorted = group.sorted { $0.timestamp < $1.timestamp }
                var active: TimeInterval = 0
                for (previous, next) in zip(sorted, sorted.dropFirst()) {
                    active += min(next.timestamp.timeIntervalSince(previous.timestamp), gapCap)
                }
                return ProjectSlice(
                    path: path,
                    name: sorted.first?.projectName ?? "unknown",
                    totalTokens: group.reduce(0) { $0 + $1.newTokens },
                    activeSeconds: active,
                    sessions: Set(group.map(\.sessionId)).count
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    public struct SessionSummary: Equatable, Identifiable, Sendable {
        public var id: String { sessionId }
        public let sessionId: String
        public let agent: AgentSource
        public let start: Date
        public let end: Date
        /// Gap-capped active time, same rule as `byProject`.
        public let activeSeconds: TimeInterval
        public let totalTokens: Int
        public let estimatedCostUSD: Double
        /// Distinct models, largest token share first.
        public let models: [String]
        public let eventCount: Int
    }

    /// One row per session in the given project, newest first — the project
    /// drill-down's history list.
    public static func sessionSummaries(
        forProject path: String,
        in events: [UsageEvent],
        gapCap: TimeInterval = 300
    ) -> [SessionSummary] {
        Dictionary(grouping: events.filter { $0.projectPath == path }, by: \.sessionId)
            .compactMap { sessionId, group -> SessionSummary? in
                let sorted = group.sorted { $0.timestamp < $1.timestamp }
                guard let first = sorted.first, let last = sorted.last else { return nil }
                var active: TimeInterval = 0
                for (previous, next) in zip(sorted, sorted.dropFirst()) {
                    active += min(next.timestamp.timeIntervalSince(previous.timestamp), gapCap)
                }
                let tokensByModel = Dictionary(grouping: sorted, by: \.model)
                    .mapValues { $0.reduce(0) { $0 + $1.newTokens } }
                return SessionSummary(
                    sessionId: sessionId,
                    agent: first.agent,
                    start: first.timestamp,
                    end: last.timestamp,
                    activeSeconds: active,
                    totalTokens: sorted.reduce(0) { $0 + $1.newTokens },
                    estimatedCostUSD: sorted.reduce(0) { $0 + Pricing.estimatedCostUSD(for: $1) },
                    models: tokensByModel.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                        .map(\.key),
                    eventCount: sorted.count
                )
            }
            .sorted { $0.start > $1.start }
    }

    // MARK: 5-hour blocks

    public struct Block: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let totalTokens: Int
        /// Same window, excluding cache-read — see `UsageEvent.newTokens`. A cache-heavy
        /// block (whole conversation re-sent as context each turn) can make `totalTokens`
        /// look enormous next to this; both are correct, just different questions.
        public let newTokens: Int
        public let outputTokens: Int

        /// New tokens as a share of all tokens in this block (0...1). 0 when
        /// `totalTokens` is 0.
        public var newShare: Double {
            totalTokens > 0 ? Double(newTokens) / Double(totalTokens) : 0
        }
    }

    /// Reconstructs 5-hour usage blocks the way the community tools do: a block opens at
    /// the first event's timestamp floored to the hour and spans 5 hours; the next event
    /// after that opens a new block. Approximate by design.
    public static func blocks(
        _ events: [UsageEvent],
        blockLength: TimeInterval = 5 * 3600,
        calendar: Calendar = .current
    ) -> [Block] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var result: [Block] = []
        var current: (start: Date, members: [UsageEvent])?

        for event in sorted {
            if let open = current, event.timestamp < open.start.addingTimeInterval(blockLength) {
                current = (open.start, open.members + [event])
            } else {
                if let open = current { result.append(finish(open, blockLength: blockLength)) }
                let floored = floorToHour(event.timestamp, calendar: calendar)
                current = (floored, [event])
            }
        }
        if let open = current { result.append(finish(open, blockLength: blockLength)) }
        return result
    }

    /// The block containing `now`, if the latest block is still open, computed over the
    /// given `scope` of agents.
    public static func currentBlock(
        _ events: [UsageEvent],
        scope: AgentScope,
        now: Date,
        blockLength: TimeInterval = 5 * 3600,
        calendar: Calendar = .current
    ) -> Block? {
        let scoped = scope.apply(events)
        guard let last = blocks(scoped, blockLength: blockLength, calendar: calendar).last,
              last.start <= now, now < last.end
        else { return nil }
        return last
    }

    public struct WeeklyTokens: Equatable, Sendable {
        /// Raw sum including cache-read — see `UsageEvent.totalTokens`.
        public let totalTokens: Int
        /// Same window, excluding cache-read — see `UsageEvent.newTokens`.
        public let newTokens: Int

        /// New tokens as a share of all tokens this week (0...1). 0 when
        /// `totalTokens` is 0.
        public var newShare: Double {
            totalTokens > 0 ? Double(newTokens) / Double(totalTokens) : 0
        }
    }

    /// Tokens from the current week (Monday start) in the given `scope`, both raw and
    /// cache-excluded — feeds This Week's composition gauge.
    public static func weeklyTokens(
        _ events: [UsageEvent],
        scope: AgentScope,
        now: Date,
        calendar: Calendar = .current
    ) -> WeeklyTokens {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        guard let weekStart = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return WeeklyTokens(totalTokens: 0, newTokens: 0)
        }
        let scoped = scope.apply(events).filter { $0.timestamp >= weekStart }
        return WeeklyTokens(
            totalTokens: scoped.reduce(0) { $0 + $1.totalTokens },
            newTokens: scoped.reduce(0) { $0 + $1.newTokens }
        )
    }

    private static func finish(
        _ open: (start: Date, members: [UsageEvent]), blockLength: TimeInterval
    ) -> Block {
        Block(
            start: open.start,
            end: open.start.addingTimeInterval(blockLength),
            totalTokens: open.members.reduce(0) { $0 + $1.totalTokens },
            newTokens: open.members.reduce(0) { $0 + $1.newTokens },
            outputTokens: open.members.reduce(0) { $0 + $1.outputTokens }
        )
    }

    private static func floorToHour(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    // MARK: Fun facts

    /// Consecutive calendar days with usage, ending at the most recent event's day.
    public static func currentStreakDays(_ events: [UsageEvent], calendar: Calendar = .current) -> Int {
        let days = Set(events.map { calendar.startOfDay(for: $0.timestamp) }).sorted(by: >)
        guard var cursor = days.first else { return 0 }
        var streak = 1
        for day in days.dropFirst() {
            guard let expected = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            if day == expected {
                streak += 1
                cursor = day
            } else {
                break
            }
        }
        return streak
    }

    /// Share of all prompt-side tokens that were served from cache (0...1).
    public static func cacheEfficiency(_ events: [UsageEvent]) -> Double {
        let promptSide = events.reduce(0) {
            $0 + $1.inputTokens + $1.cacheCreationTokens + $1.cacheReadTokens
        }
        guard promptSide > 0 else { return 0 }
        let reads = events.reduce(0) { $0 + $1.cacheReadTokens }
        return Double(reads) / Double(promptSide)
    }

    /// Total estimated USD saved by prompt caching.
    public static func totalCacheSavingsUSD(_ events: [UsageEvent]) -> Double {
        events.reduce(0) { $0 + Pricing.cacheSavingsUSD(for: $1) }
    }

    public static func busiestDay(_ events: [UsageEvent], calendar: Calendar = .current) -> DayBucket? {
        dailySeries(events, calendar: calendar).max { $0.totalTokens < $1.totalTokens }
    }
}
