import Foundation

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
        public var totalTokens: Int {
            inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
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
                    totalTokens: group.reduce(0) { $0 + $1.totalTokens },
                    outputTokens: group.reduce(0) { $0 + $1.outputTokens },
                    estimatedCostUSD: group.reduce(0) { $0 + Pricing.estimatedCostUSD(for: $1) }
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }
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
                    totalTokens: group.reduce(0) { $0 + $1.totalTokens },
                    estimatedCostUSD: group.reduce(0) { $0 + Pricing.estimatedCostUSD(for: $1) }
                )
            }
            .sorted { $0.day < $1.day }
    }

    // MARK: Projects

    public struct ProjectSlice: Equatable, Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let name: String
        public let totalTokens: Int
        public let activeSeconds: TimeInterval
        public let sessions: Int
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
                    totalTokens: group.reduce(0) { $0 + $1.totalTokens },
                    activeSeconds: active,
                    sessions: Set(group.map(\.sessionId)).count
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: 5-hour blocks

    public struct Block: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let totalTokens: Int
        public let outputTokens: Int
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

    /// The block containing `now`, if the latest block is still open.
    public static func currentBlock(
        _ events: [UsageEvent],
        now: Date,
        blockLength: TimeInterval = 5 * 3600,
        calendar: Calendar = .current
    ) -> Block? {
        guard let last = blocks(events, blockLength: blockLength, calendar: calendar).last,
              last.start <= now, now < last.end
        else { return nil }
        return last
    }

    private static func finish(
        _ open: (start: Date, members: [UsageEvent]), blockLength: TimeInterval
    ) -> Block {
        Block(
            start: open.start,
            end: open.start.addingTimeInterval(blockLength),
            totalTokens: open.members.reduce(0) { $0 + $1.totalTokens },
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
