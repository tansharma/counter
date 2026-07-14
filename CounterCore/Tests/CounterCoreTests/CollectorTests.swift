import XCTest
@testable import CounterCore

final class CollectorTests: XCTestCase {

    private func tempHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDir(_ path: String, under home: URL) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path), withIntermediateDirectories: true
        )
    }

    // MARK: AgentSource.config — the new configuration lookup

    func testConfigHasAnEntryForEveryAgentCase() {
        for agent in AgentSource.allCases {
            XCTAssertNotNil(AgentSource.config[agent], "\(agent) is missing a Config entry")
        }
    }

    func testChartColorIndicesAreUniquePerAgent() {
        let indices = AgentSource.allCases.map(\.chartColorIndex)
        XCTAssertEqual(Set(indices).count, indices.count, "two agents share a chart color index")
    }

    func testDefaultRootsMatchesConfigRootPaths() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let roots = UsageCollector.defaultRoots(home: home)
        for agent in AgentSource.allCases {
            let expected = (AgentSource.config[agent]?.rootPaths ?? [])
                .map { home.appendingPathComponent($0) }
            XCTAssertEqual(roots[agent], expected, "\(agent) roots don't match its config.rootPaths")
        }
    }

    // MARK: Detection — derived from config.detectionPaths, not a hand switch

    func testDetectedAgentsOnlyReportsAgentsWithAnExistingDetectionPath() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try makeDir(".claude/projects", under: home)
        try makeDir(".local/share/opencode/storage/session", under: home)
        // .codex and .gemini's detection paths deliberately left absent.

        let detected = UsageCollector.detectedAgents(home: home)
        XCTAssertEqual(detected, [.claude, .opencode])
    }

    func testDetectedAgentsIsEmptyWhenNoAgentDirectoriesExist() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertTrue(UsageCollector.detectedAgents(home: home).isEmpty)
    }

    // MARK: parseAll — config.parse dispatches to the right per-agent parser

    func testParseAllDispatchesOnlyToEnabledAgents() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try makeDir(".claude/projects/proj", under: home)
        let line = #"{"type":"assistant","timestamp":"2026-07-03T11:32:20.100Z","cwd":"/Users/t/dev/ledger","sessionId":"sess-1","message":{"id":"msg_01","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        try line.write(
            to: home.appendingPathComponent(".claude/projects/proj/sess-1.jsonl"),
            atomically: true, encoding: .utf8
        )

        let enabled = UsageCollector.parseAll(enabled: [.claude], home: home)
        XCTAssertEqual(enabled.count, 1)
        XCTAssertEqual(enabled.first?.model, "claude-sonnet-5")

        let disabled = UsageCollector.parseAll(enabled: [.codex], home: home)
        XCTAssertTrue(disabled.isEmpty)
    }
}
