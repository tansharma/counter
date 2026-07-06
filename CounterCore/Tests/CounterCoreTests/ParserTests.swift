import XCTest
@testable import CounterCore

final class ParserTests: XCTestCase {

    private func assistantLine(
        id: String = "msg_01",
        model: String = "claude-sonnet-5",
        timestamp: String = "2026-07-03T11:32:20.100Z",
        input: Int = 100,
        output: Int = 50,
        cacheCreate: Int = 10,
        cacheRead: Int = 500,
        cwd: String = "/Users/t/dev/ledger",
        session: String = "sess-1"
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","cwd":"\(cwd)","sessionId":"\(session)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    func testParsesAllFieldsFromAssistantLine() {
        let events = SessionLogParser.parse(jsonl: assistantLine())
        XCTAssertEqual(events.count, 1)
        let event = try! XCTUnwrap(events.first)
        XCTAssertEqual(event.model, "claude-sonnet-5")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.cacheCreationTokens, 10)
        XCTAssertEqual(event.cacheReadTokens, 500)
        XCTAssertEqual(event.projectPath, "/Users/t/dev/ledger")
        XCTAssertEqual(event.projectName, "ledger")
        XCTAssertEqual(event.sessionId, "sess-1")
        XCTAssertEqual(event.totalTokens, 660)
    }

    func testSkipsMalformedUnknownAndSyntheticLines() {
        let jsonl = [
            "not json at all {{{",
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            assistantLine(model: "<synthetic>"),
            assistantLine(id: "msg_ok"),
        ].joined(separator: "\n")

        let events = SessionLogParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.model, "claude-sonnet-5")
    }

    func testDedupesStreamingChunksKeepingLargestOutput() {
        let jsonl = [
            assistantLine(id: "msg_a", output: 10),
            assistantLine(id: "msg_a", output: 394),
            assistantLine(id: "msg_a", output: 200),
            assistantLine(id: "msg_b", timestamp: "2026-07-03T12:00:00.000Z", output: 7),
        ].joined(separator: "\n")

        let events = SessionLogParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.outputTokens, 394) // msg_a, earlier timestamp
        XCTAssertEqual(events.last?.outputTokens, 7)
    }

    func testNormalizesMidSessionDirectoryChangesToSessionRoot() {
        let jsonl = [
            assistantLine(id: "msg_1", timestamp: "2026-07-03T10:00:00.000Z", cwd: "/Users/t/dev/ledger"),
            assistantLine(id: "msg_2", timestamp: "2026-07-03T10:05:00.000Z", cwd: "/Users/t/dev/ledger/LedgerCore"),
            assistantLine(id: "msg_3", timestamp: "2026-07-03T10:10:00.000Z", cwd: "/Users/t/dev/other", session: "sess-2"),
        ].joined(separator: "\n")

        let events = SessionLogParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.count, 3)
        // Same session: subfolder pinned back to the session root.
        XCTAssertEqual(events[0].projectPath, "/Users/t/dev/ledger")
        XCTAssertEqual(events[1].projectPath, "/Users/t/dev/ledger")
        // Different session keeps its own root.
        XCTAssertEqual(events[2].projectPath, "/Users/t/dev/other")
    }

    func testRenamedProjectAttributesToDominantRoot() {
        // Folder renamed old→new mid-history: unrelated paths, majority (new) wins.
        let jsonl = [
            assistantLine(id: "msg_1", timestamp: "2026-07-03T10:00:00.000Z", cwd: "/dev/old-name"),
            assistantLine(id: "msg_2", timestamp: "2026-07-03T10:05:00.000Z", cwd: "/dev/new-name"),
            assistantLine(id: "msg_3", timestamp: "2026-07-03T10:10:00.000Z", cwd: "/dev/new-name"),
        ].joined(separator: "\n")

        let events = SessionLogParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.map(\.projectPath), Array(repeating: "/dev/new-name", count: 3))
    }

    func testParsesPlainAndFractionalTimestamps() {
        let jsonl = [
            assistantLine(id: "msg_frac", timestamp: "2026-07-03T11:32:20.123Z"),
            assistantLine(id: "msg_plain", timestamp: "2026-07-03T11:32:21Z"),
        ].joined(separator: "\n")
        XCTAssertEqual(SessionLogParser.parse(jsonl: jsonl).count, 2)
    }

    func testEventsSortedByTimestamp() {
        let jsonl = [
            assistantLine(id: "msg_late", timestamp: "2026-07-03T15:00:00.000Z"),
            assistantLine(id: "msg_early", timestamp: "2026-07-03T09:00:00.000Z"),
        ].joined(separator: "\n")
        let events = SessionLogParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.map(\.sessionId).count, 2)
        XCTAssertLessThan(events[0].timestamp, events[1].timestamp)
    }
}
