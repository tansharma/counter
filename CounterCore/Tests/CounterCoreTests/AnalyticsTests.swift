import XCTest
@testable import CounterCore

final class AnalyticsTests: XCTestCase {

    private var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func event(
        at iso: String,
        model: String = "claude-sonnet-5",
        input: Int = 100,
        output: Int = 50,
        cacheCreate: Int = 0,
        cacheRead: Int = 0,
        project: String = "/dev/alpha",
        session: String = "s1",
        agent: AgentSource = .claude
    ) -> UsageEvent {
        UsageEvent(
            timestamp: date(iso),
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            projectPath: project,
            sessionId: session,
            agent: agent
        )
    }

    // MARK: Totals & breakdowns

    func testTotalsHandComputed() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 100, output: 50, cacheCreate: 10, cacheRead: 40, session: "s1"),
            event(at: "2026-07-01T11:00:00Z", input: 200, output: 25, session: "s2"),
        ]
        let totals = UsageAnalytics.totals(events)
        XCTAssertEqual(totals.events, 2)
        XCTAssertEqual(totals.sessions, 2)
        XCTAssertEqual(totals.inputTokens, 300)
        XCTAssertEqual(totals.outputTokens, 75)
        XCTAssertEqual(totals.cacheCreationTokens, 10)
        XCTAssertEqual(totals.cacheReadTokens, 40)
        // totalTokens excludes cache reads (300 input + 75 output + 10 cache-creation);
        // cache reads are still available raw via totals.cacheReadTokens above.
        XCTAssertEqual(totals.totalTokens, 385)
    }

    /// Cache reads recur on every turn of a conversation and dominate raw totals over
    /// a session, so headline stats (Totals) must exclude them while gauges that
    /// proxy Anthropic's actual rate limit (Block) must keep them.
    func testHeadlineTotalsExcludeCacheReadsButBlockGaugeIncludesThem() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 100, output: 50, cacheCreate: 10, cacheRead: 1_000),
        ]
        XCTAssertEqual(UsageAnalytics.totals(events).totalTokens, 160)
        XCTAssertEqual(UsageAnalytics.blocks(events, calendar: utcCalendar)[0].totalTokens, 1_160)
    }

    func testByModelSortsLargestFirst() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", model: "claude-haiku-4-5", input: 10, output: 5),
            event(at: "2026-07-01T10:05:00Z", model: "claude-opus-4-8", input: 1000, output: 500),
        ]
        let slices = UsageAnalytics.byModel(events)
        XCTAssertEqual(slices.map(\.model), ["claude-opus-4-8", "claude-haiku-4-5"])
        XCTAssertEqual(slices[0].totalTokens, 1500)
    }

    func testDailySeriesBucketsByCalendarDay() {
        let events = [
            event(at: "2026-07-01T09:00:00Z", input: 100, output: 0),
            event(at: "2026-07-01T23:00:00Z", input: 100, output: 0),
            event(at: "2026-07-02T01:00:00Z", input: 300, output: 0),
        ]
        let series = UsageAnalytics.dailySeries(events, calendar: utcCalendar)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].totalTokens, 200)
        XCTAssertEqual(series[1].totalTokens, 300)
    }

    // MARK: Cost

    func testCostArithmeticForKnownEvent() {
        // Sonnet: $3 in / $15 out per MTok; cache write 1.25x in, read 0.1x in.
        let single = event(
            at: "2026-07-01T10:00:00Z",
            model: "claude-sonnet-5",
            input: 1_000_000, output: 1_000_000,
            cacheCreate: 1_000_000, cacheRead: 1_000_000
        )
        // 3 + 15 + 3.75 + 0.3 = 22.05
        XCTAssertEqual(Pricing.estimatedCostUSD(for: single), 22.05, accuracy: 0.0001)
        // Savings: 1M cache reads at 0.9 * $3 = 2.7
        XCTAssertEqual(Pricing.cacheSavingsUSD(for: single), 2.7, accuracy: 0.0001)
    }

    func testPricingPrefixMatchAndUnknownModel() {
        XCTAssertNotNil(Pricing.rate(forModel: "claude-opus-4-8"))
        XCTAssertNotNil(Pricing.rate(forModel: "claude-fable-5"))
        XCTAssertNil(Pricing.rate(forModel: "gpt-oss-120b"))
    }

    // MARK: Projects & active time

    func testActiveTimeCapsIdleGaps() {
        // Gaps: 60s (counted), 2h (capped to 300s) => 360s active.
        let events = [
            event(at: "2026-07-01T10:00:00Z"),
            event(at: "2026-07-01T10:01:00Z"),
            event(at: "2026-07-01T12:01:00Z"),
        ]
        let slices = UsageAnalytics.byProject(events, gapCap: 300)
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].activeSeconds, 360, accuracy: 0.5)
        XCTAssertEqual(slices[0].name, "alpha")
    }

    func testByProjectSeparatesProjects() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 500, output: 0, project: "/dev/alpha"),
            event(at: "2026-07-01T10:01:00Z", input: 100, output: 0, project: "/dev/beta", session: "s2"),
        ]
        let slices = UsageAnalytics.byProject(events)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].name, "alpha") // more tokens first
    }

    // MARK: 5-hour blocks

    func testEventsWithinFiveHoursShareABlock() {
        let events = [
            event(at: "2026-07-01T10:20:00Z", input: 100, output: 0),
            event(at: "2026-07-01T14:50:00Z", input: 200, output: 0),
        ]
        let blocks = UsageAnalytics.blocks(events, calendar: utcCalendar)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].start, date("2026-07-01T10:00:00Z")) // floored to hour
        XCTAssertEqual(blocks[0].end, date("2026-07-01T15:00:00Z"))
        XCTAssertEqual(blocks[0].totalTokens, 300)
    }

    func testEventAfterBlockEndOpensNewBlock() {
        let events = [
            event(at: "2026-07-01T10:20:00Z"),
            event(at: "2026-07-01T16:10:00Z"), // > 15:00 block end
        ]
        let blocks = UsageAnalytics.blocks(events, calendar: utcCalendar)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1].start, date("2026-07-01T16:00:00Z"))
    }

    func testCurrentBlockOnlyWhenNowInsideWindow() {
        let events = [event(at: "2026-07-01T10:20:00Z")]
        let inside = UsageAnalytics.currentBlock(events, scope: .allEnabled, now: date("2026-07-01T12:00:00Z"), calendar: utcCalendar)
        XCTAssertNotNil(inside)
        let outside = UsageAnalytics.currentBlock(events, scope: .allEnabled, now: date("2026-07-01T20:00:00Z"), calendar: utcCalendar)
        XCTAssertNil(outside)
    }

    // MARK: Agent scope — locks which gauge uses which scope/token-definition combo.
    // Claude Block Reset must stay claude-only + raw; Session Usage/This Week must be
    // all-agents (one raw, one new). See handover.md's "Two token totals AND two event
    // scopes" gotcha before changing any of this.

    func testCurrentBlockClaudeOnlyScopeExcludesOtherAgents() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 100, output: 0, session: "s1", agent: .claude),
            event(at: "2026-07-01T10:05:00Z", input: 1_000, output: 0, session: "codex:a", agent: .codex),
        ]
        let block = UsageAnalytics.currentBlock(
            events, scope: .claudeOnly, now: date("2026-07-01T11:00:00Z"), calendar: utcCalendar
        )
        XCTAssertEqual(block?.totalTokens, 100)
    }

    func testCurrentBlockAllEnabledScopeIncludesEveryAgent() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 100, output: 0, session: "s1", agent: .claude),
            event(at: "2026-07-01T10:05:00Z", input: 1_000, output: 0, session: "codex:a", agent: .codex),
        ]
        let block = UsageAnalytics.currentBlock(
            events, scope: .allEnabled, now: date("2026-07-01T11:00:00Z"), calendar: utcCalendar
        )
        XCTAssertEqual(block?.totalTokens, 1_100)
    }

    func testWeeklyTokensAllEnabledScopeSumsRawAndNewAcrossAgents() {
        let events = [
            // Wed: raw 1050 (100+50+900 cache-read), new 150.
            event(at: "2026-07-01T10:00:00Z", input: 100, output: 50, cacheRead: 900, session: "s1", agent: .claude),
            // Thu: raw and new both 200 (no cache-read).
            event(at: "2026-07-02T10:00:00Z", input: 200, output: 0, session: "codex:a", agent: .codex),
        ]
        let weekly = UsageAnalytics.weeklyTokens(
            events, scope: .allEnabled, now: date("2026-07-03T10:00:00Z"), calendar: utcCalendar
        )
        XCTAssertEqual(weekly.totalTokens, 1_250)
        XCTAssertEqual(weekly.newTokens, 350)
    }

    func testWeeklyTokensClaudeOnlyScopeExcludesOtherAgents() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 100, output: 50, session: "s1", agent: .claude),
            event(at: "2026-07-01T10:05:00Z", input: 1_000, output: 0, session: "codex:a", agent: .codex),
        ]
        let weekly = UsageAnalytics.weeklyTokens(
            events, scope: .claudeOnly, now: date("2026-07-01T11:00:00Z"), calendar: utcCalendar
        )
        XCTAssertEqual(weekly.totalTokens, 150)
        XCTAssertEqual(weekly.newTokens, 150)
    }

    func testWeeklyTokensExcludesEventsBeforeMondayWeekStart() {
        let events = [
            event(at: "2026-06-28T10:00:00Z", input: 500, output: 0), // Sunday, prior week
            event(at: "2026-06-29T10:00:00Z", input: 100, output: 0), // Monday, this week
        ]
        let weekly = UsageAnalytics.weeklyTokens(
            events, scope: .allEnabled, now: date("2026-07-01T10:00:00Z"), calendar: utcCalendar
        )
        XCTAssertEqual(weekly.totalTokens, 100)
    }

    // MARK: Fun facts

    func testStreakBreaksOnGapDay() {
        let events = [
            event(at: "2026-06-28T10:00:00Z"), // gap after this day
            event(at: "2026-06-30T10:00:00Z"),
            event(at: "2026-07-01T10:00:00Z"),
        ]
        XCTAssertEqual(UsageAnalytics.currentStreakDays(events, calendar: utcCalendar), 2)
    }

    func testCacheEfficiency() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 100, output: 999, cacheCreate: 100, cacheRead: 800)
        ]
        XCTAssertEqual(UsageAnalytics.cacheEfficiency(events), 0.8, accuracy: 0.0001)
        XCTAssertEqual(UsageAnalytics.cacheEfficiency([]), 0)
    }

    func testBusiestDay() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 100, output: 0),
            event(at: "2026-07-02T10:00:00Z", input: 900, output: 0),
        ]
        let busiest = UsageAnalytics.busiestDay(events, calendar: utcCalendar)
        XCTAssertEqual(busiest?.totalTokens, 900)
    }

    // MARK: Agents

    func testByAgentGroupsAndSortsLargestFirst() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", input: 10, output: 5, session: "s1", agent: .claude),
            event(at: "2026-07-01T10:05:00Z", input: 1000, output: 500, session: "codex:a", agent: .codex),
            event(at: "2026-07-01T10:10:00Z", input: 100, output: 50, session: "codex:b", agent: .codex),
        ]
        let slices = UsageAnalytics.byAgent(events)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].agent, .codex)
        XCTAssertEqual(slices[0].totalTokens, 1650)
        XCTAssertEqual(slices[0].outputTokens, 550)
        XCTAssertEqual(slices[0].sessions, 2)
        XCTAssertEqual(slices[1].agent, .claude)
        XCTAssertEqual(slices[1].sessions, 1)
    }

    func testAgentSurvivesSessionRootNormalization() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", project: "/dev/alpha", session: "codex:a", agent: .codex),
            event(at: "2026-07-01T10:05:00Z", project: "/dev/alpha/sub", session: "codex:a", agent: .codex),
        ]
        let normalized = SessionLogParser.normalizeToSessionRoot(events)
        XCTAssertEqual(normalized.map(\.projectPath), ["/dev/alpha", "/dev/alpha"])
        XCTAssertEqual(normalized.map(\.agent), [.codex, .codex])
    }

    // MARK: Local usage

    func testLocalUsageAggregatesOllamaModels() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", model: "qwen2.5vl:7b",
                  input: 1_000_000, output: 200_000, session: "l1"),
            event(at: "2026-07-01T10:05:00Z", model: "llama3.3:70b",
                  input: 100, output: 50, session: "l2"),
            event(at: "2026-07-01T11:00:00Z", model: "claude-sonnet-5",
                  input: 1_199_850, output: 0, session: "c1"),
        ]
        let local = try! XCTUnwrap(UsageAnalytics.localUsage(events))
        XCTAssertEqual(local.localTokens, 1_200_150)
        XCTAssertEqual(local.localSessions, 2)
        XCTAssertEqual(local.localEvents, 2)
        XCTAssertEqual(local.localShare, 0.5, accuracy: 0.001)
        XCTAssertEqual(local.models, ["qwen2.5vl:7b", "llama3.3:70b"])
        // 1M in @ $1 + 0.2M out @ $5 = $2, plus the tiny llama event.
        XCTAssertEqual(local.cloudEquivalentUSD, 2.0 + 0.00035, accuracy: 0.0001)
    }

    func testLocalUsageNilWhenAllCloud() {
        XCTAssertNil(UsageAnalytics.localUsage([event(at: "2026-07-01T10:00:00Z")]))
        XCTAssertNil(UsageAnalytics.localUsage([]))
    }

    // MARK: Session summaries (project drill-down)

    func testSessionSummariesFiltersSortsAndComputes() {
        let events = [
            // Session s1 in alpha: 2 minutes apart, well under the gap cap.
            event(at: "2026-07-01T10:00:00Z", model: "claude-sonnet-5", input: 100, output: 10, session: "s1"),
            event(at: "2026-07-01T10:02:00Z", model: "claude-opus-4-8", input: 900, output: 90, session: "s1"),
            // Newer session s2 in alpha, single event.
            event(at: "2026-07-02T09:00:00Z", input: 50, output: 5, session: "s2", agent: .gemini),
            // Different project must be excluded.
            event(at: "2026-07-01T12:00:00Z", project: "/dev/beta", session: "s3"),
        ]
        let summaries = UsageAnalytics.sessionSummaries(forProject: "/dev/alpha", in: events)

        XCTAssertEqual(summaries.map(\.sessionId), ["s2", "s1"]) // newest first
        let s1 = try! XCTUnwrap(summaries.last)
        XCTAssertEqual(s1.agent, .claude)
        XCTAssertEqual(s1.start, date("2026-07-01T10:00:00Z"))
        XCTAssertEqual(s1.end, date("2026-07-01T10:02:00Z"))
        XCTAssertEqual(s1.activeSeconds, 120)
        XCTAssertEqual(s1.totalTokens, 1100)
        XCTAssertEqual(s1.eventCount, 2)
        XCTAssertEqual(s1.models, ["claude-opus-4-8", "claude-sonnet-5"]) // by token share
        XCTAssertEqual(summaries.first?.agent, .gemini)
    }

    func testSessionSummariesCapIdleGaps() {
        let events = [
            event(at: "2026-07-01T10:00:00Z", session: "s1"),
            event(at: "2026-07-01T12:00:00Z", session: "s1"), // 2h idle gap
        ]
        let summaries = UsageAnalytics.sessionSummaries(forProject: "/dev/alpha", in: events)
        XCTAssertEqual(summaries.first?.activeSeconds, 300) // capped at the default
    }
}
