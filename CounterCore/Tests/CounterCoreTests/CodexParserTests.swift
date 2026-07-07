import XCTest
@testable import CounterCore

final class CodexParserTests: XCTestCase {

    private func sessionMeta(
        id: String = "0198a5c0-0000-7000-8000-000000000001",
        cwd: String = "/Users/t/dev/ledger",
        forkedFrom: String? = nil,
        timestamp: String = "2026-07-03T10:00:00.000Z"
    ) -> String {
        let fork = forkedFrom.map { #","forked_from_id":"\#($0)""# } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(id)","cwd":"\(cwd)"\(fork)}}
        """
    }

    private func turnContext(
        model: String = "gpt-5-codex",
        turnId: String? = nil,
        timestamp: String = "2026-07-03T10:00:01.000Z"
    ) -> String {
        let turn = turnId.map { #","turn_id":"\#($0)""# } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"\(model)"\(turn)}}
        """
    }

    private func tokenCount(
        input: Int, cached: Int, output: Int,
        timestamp: String = "2026-07-03T10:00:05.000Z"
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"total_tokens":\(input + output)}}}}
        """
    }

    /// UUIDv7 whose embedded timestamp is the given millisecond value.
    private func uuidV7(ms: Int64) -> String {
        let hex = String(format: "%012llx", ms)
        let p1 = String(hex.prefix(8))
        let p2 = String(hex.suffix(4))
        return "\(p1)-\(p2)-7000-8000-000000000000"
    }

    func testParsesSessionMetaTurnContextAndTokenCount() {
        let jsonl = [
            sessionMeta(),
            turnContext(model: "gpt-5-codex"),
            tokenCount(input: 1000, cached: 800, output: 50),
        ].joined(separator: "\n")

        let events = CodexSessionParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.count, 1)
        let event = try! XCTUnwrap(events.first)
        XCTAssertEqual(event.agent, .codex)
        XCTAssertEqual(event.model, "gpt-5-codex")
        XCTAssertEqual(event.projectPath, "/Users/t/dev/ledger")
        XCTAssertEqual(event.sessionId, "codex:0198a5c0-0000-7000-8000-000000000001")
        // Codex input includes the cached portion; the cached share is billed as reads.
        XCTAssertEqual(event.inputTokens, 200)
        XCTAssertEqual(event.cacheReadTokens, 800)
        XCTAssertEqual(event.cacheCreationTokens, 0)
        XCTAssertEqual(event.outputTokens, 50)
    }

    func testDedupesRepeatedStreamingUsage() {
        let jsonl = [
            sessionMeta(),
            turnContext(),
            tokenCount(input: 100, cached: 0, output: 10),
            tokenCount(input: 100, cached: 0, output: 10, timestamp: "2026-07-03T10:00:06.000Z"),
            tokenCount(input: 200, cached: 0, output: 20, timestamp: "2026-07-03T10:00:07.000Z"),
        ].joined(separator: "\n")

        let events = CodexSessionParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.outputTokens), [10, 20])
    }

    func testModelTracksLatestTurnContext() {
        let jsonl = [
            sessionMeta(),
            turnContext(model: "gpt-5-codex"),
            tokenCount(input: 10, cached: 0, output: 1),
            turnContext(model: "o4-mini", timestamp: "2026-07-03T10:01:00.000Z"),
            tokenCount(input: 20, cached: 0, output: 2, timestamp: "2026-07-03T10:01:05.000Z"),
        ].joined(separator: "\n")

        let events = CodexSessionParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.map(\.model), ["gpt-5-codex", "o4-mini"])
    }

    func testFallsBackToFileBasenameWhenSessionMetaMissing() {
        let jsonl = [
            turnContext(),
            tokenCount(input: 10, cached: 0, output: 1),
        ].joined(separator: "\n")

        let events = CodexSessionParser.parse(jsonl: jsonl, fallbackSessionId: "rollout-abc")
        XCTAssertEqual(events.first?.sessionId, "codex:rollout-abc")
    }

    func testSkipsMalformedLinesAndUnknownTypes() {
        let jsonl = [
            "{{{ not json",
            #"{"timestamp":"2026-07-03T10:00:00.000Z","type":"response_item","payload":{}}"#,
            sessionMeta(),
            turnContext(),
            tokenCount(input: 10, cached: 0, output: 1),
        ].joined(separator: "\n")

        XCTAssertEqual(CodexSessionParser.parse(jsonl: jsonl).count, 1)
    }

    func testForkGateSuppressesReplayedParentHistory() {
        let forkMs: Int64 = 1_780_000_000_000
        let jsonl = [
            // Fork's own meta: id is UUIDv7 minted at forkMs.
            sessionMeta(id: uuidV7(ms: forkMs), forkedFrom: "parent-session"),
            // Replayed parent history: turn minted before the fork, then its usage.
            turnContext(model: "gpt-5-codex", turnId: uuidV7(ms: forkMs - 60_000)),
            tokenCount(input: 500, cached: 0, output: 50),
            // Replayed parent session_meta must not overwrite the fork's identity.
            sessionMeta(id: "parent-session", cwd: "/elsewhere"),
            // First genuine turn: minted after the fork instant, opens the gate.
            turnContext(model: "gpt-5-codex", turnId: uuidV7(ms: forkMs + 5_000)),
            tokenCount(input: 100, cached: 0, output: 10, timestamp: "2026-07-03T10:05:00.000Z"),
        ].joined(separator: "\n")

        let events = CodexSessionParser.parse(jsonl: jsonl)
        XCTAssertEqual(events.count, 1)
        let event = try! XCTUnwrap(events.first)
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.sessionId, "codex:" + uuidV7(ms: forkMs))
        XCTAssertEqual(event.projectPath, "/Users/t/dev/ledger")
    }

    func testForkGateSuppressesTurnsWithoutTurnId() {
        let forkMs: Int64 = 1_780_000_000_000
        let jsonl = [
            sessionMeta(id: uuidV7(ms: forkMs), forkedFrom: "parent-session"),
            // Pre-turn_id parent history carries no turn_id at all.
            turnContext(model: "gpt-5-codex"),
            tokenCount(input: 500, cached: 0, output: 50),
        ].joined(separator: "\n")

        XCTAssertEqual(CodexSessionParser.parse(jsonl: jsonl).count, 0)
    }

    func testNonForkedSessionIsNotGated() {
        let jsonl = [
            sessionMeta(),
            turnContext(),
            tokenCount(input: 10, cached: 0, output: 1),
        ].joined(separator: "\n")

        XCTAssertEqual(CodexSessionParser.parse(jsonl: jsonl).count, 1)
    }

    func testUUIDv7Millis() {
        XCTAssertEqual(
            CodexSessionParser.uuidV7Millis(uuidV7(ms: 1_780_000_000_000)),
            1_780_000_000_000
        )
        // v4 UUID (version nibble is not 7).
        XCTAssertNil(CodexSessionParser.uuidV7Millis("0198a5c0-0000-4000-8000-000000000001"))
        XCTAssertNil(CodexSessionParser.uuidV7Millis("not-a-uuid"))
        XCTAssertNil(CodexSessionParser.uuidV7Millis(""))
    }
}
