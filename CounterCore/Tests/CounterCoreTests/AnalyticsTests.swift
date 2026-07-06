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
        session: String = "s1"
    ) -> UsageEvent {
        UsageEvent(
            timestamp: date(iso),
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            projectPath: project,
            sessionId: session
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
        XCTAssertEqual(totals.totalTokens, 425)
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
        let inside = UsageAnalytics.currentBlock(events, now: date("2026-07-01T12:00:00Z"), calendar: utcCalendar)
        XCTAssertNotNil(inside)
        let outside = UsageAnalytics.currentBlock(events, now: date("2026-07-01T20:00:00Z"), calendar: utcCalendar)
        XCTAssertNil(outside)
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
}
