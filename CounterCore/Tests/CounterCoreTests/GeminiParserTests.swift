import XCTest
@testable import CounterCore

final class GeminiParserTests: XCTestCase {

    private func message(
        id: String = "m1",
        type: String = "gemini",
        model: String = "gemini-2.5-pro",
        timestamp: String = "2026-07-03T10:00:05.000Z",
        input: Int, output: Int, cached: Int = 0, thoughts: Int = 0
    ) -> String {
        """
        {"id":"\(id)","type":"\(type)","timestamp":"\(timestamp)","model":"\(model)","tokens":{"input":\(input),"output":\(output),"cached":\(cached),"thoughts":\(thoughts)}}
        """
    }

    func testParsesSingleObjectShape() {
        let file = """
        {"sessionId":"sess-g1","startTime":"2026-07-03T10:00:00.000Z","messages":[\
        \(message(input: 100, output: 20, cached: 50, thoughts: 5))]}
        """

        let events = GeminiSessionParser.parse(fileContents: file, projectPath: "/dev/ledger")
        XCTAssertEqual(events.count, 1)
        let event = try! XCTUnwrap(events.first)
        XCTAssertEqual(event.agent, .gemini)
        XCTAssertEqual(event.sessionId, "gemini:sess-g1")
        XCTAssertEqual(event.projectPath, "/dev/ledger")
        XCTAssertEqual(event.model, "gemini-2.5-pro")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.cacheReadTokens, 50)
        // Thoughts bill at the output rate, so they fold into output.
        XCTAssertEqual(event.outputTokens, 25)
        XCTAssertEqual(event.cacheCreationTokens, 0)
    }

    func testCumulativeInputAndCachedBecomeDeltas() {
        let file = """
        {"sessionId":"sess-g1","messages":[\
        \(message(id: "m1", input: 100, output: 10, cached: 40)),\
        \(message(id: "m2", input: 250, output: 20, cached: 90)),\
        \(message(id: "m3", input: 240, output: 5, cached: 30))]}
        """

        let events = GeminiSessionParser.parse(fileContents: file, projectPath: "/p")
        XCTAssertEqual(events.map(\.inputTokens), [100, 150, 240]) // negative delta resets
        XCTAssertEqual(events.map(\.cacheReadTokens), [40, 50, 30])
        XCTAssertEqual(events.map(\.outputTokens), [10, 20, 5]) // output is per-message
    }

    func testJSONLShapeReplacesRecordsWithSameId() {
        let file = [
            #"{"sessionId":"sess-g2","startTime":"2026-07-03T10:00:00.000Z"}"#,
            message(id: "m1", input: 100, output: 10),
            // Later record with the same id replaces the earlier one in place.
            message(id: "m1", input: 100, output: 42),
            message(id: "m2", timestamp: "2026-07-03T10:01:00.000Z", input: 300, output: 7),
        ].joined(separator: "\n")

        let events = GeminiSessionParser.parse(fileContents: file, projectPath: "/p")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.outputTokens), [42, 7])
        XCTAssertEqual(events.map(\.inputTokens), [100, 200])
        XCTAssertEqual(events.first?.sessionId, "gemini:sess-g2")
    }

    func testSkipsPartialTrailingLinesAndMessagesWithoutTokens() {
        let file = [
            #"{"sessionId":"sess-g3"}"#,
            #"{"id":"m0","type":"user","content":"hi"}"#,
            message(id: "m1", input: 10, output: 1),
            #"{"id":"m2","type":"gemini","tok"#, // live-file partial write
        ].joined(separator: "\n")

        let events = GeminiSessionParser.parse(fileContents: file, projectPath: "/p")
        XCTAssertEqual(events.count, 1)
    }

    func testMissingSessionIdYieldsNoEvents() {
        XCTAssertTrue(
            GeminiSessionParser.parse(
                fileContents: #"{"messages":[]}"#, projectPath: "/p"
            ).isEmpty
        )
    }

    func testPathHashMatchesSHA256() {
        // SHA-256("abc") — standard test vector.
        XCTAssertEqual(
            GeminiSessionParser.pathHash("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testProjectMapResolvesHashAndNameEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"projects":{"/Users/t/dev/ledger":"ledger"}}"#
            .write(to: root.appendingPathComponent("projects.json"),
                   atomically: true, encoding: .utf8)
        try #"{"trustedFolders":["/Users/t/dev/other"]}"#
            .write(to: root.appendingPathComponent("trustedFolders.json"),
                   atomically: true, encoding: .utf8)

        let map = GeminiSessionParser.projectMap(geminiRoot: root)
        XCTAssertEqual(
            map[GeminiSessionParser.pathHash("/Users/t/dev/ledger")], "/Users/t/dev/ledger")
        XCTAssertEqual(map["ledger"], "/Users/t/dev/ledger")
        XCTAssertEqual(
            map[GeminiSessionParser.pathHash("/Users/t/dev/other")], "/Users/t/dev/other")
    }

    func testUnresolvedHashDirFallsBackToVisiblyDistinctPlaceholder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // A tmp/<hash> dir with no matching entry in projects.json or
        // trustedFolders.json (neither file is even written here) — the hash
        // stays unmapped, so resolveProjectPath must fall back.
        let hash = GeminiSessionParser.pathHash("/some/path/nobody/mapped")
        let chatsDir = root.appendingPathComponent("tmp/\(hash)/chats")
        try FileManager.default.createDirectory(
            at: chatsDir, withIntermediateDirectories: true)

        let file = """
        {"sessionId":"sess-unresolved","startTime":"2026-07-03T10:00:00.000Z","messages":[\
        \(message(input: 10, output: 5))]}
        """
        try file.write(
            to: chatsDir.appendingPathComponent("session-1.json"),
            atomically: true, encoding: .utf8)

        let events = GeminiSessionParser.parseAll(geminiRoot: root)
        XCTAssertEqual(events.count, 1)
        let path = try XCTUnwrap(events.first?.projectPath)

        // Not path-shaped (no real project ever looks like this), and the short
        // hash is recoverable via the public helper.
        XCTAssertFalse(path.hasPrefix("/"))
        XCTAssertEqual(GeminiSessionParser.unresolvedHash(from: path), String(hash.prefix(8)))

        // The gap reads as a resolution gap, not a real project named "gemini".
        XCTAssertEqual(
            events.first?.projectName, "Unresolved Gemini project (\(hash.prefix(8)))")
    }

    func testProjectMapAcceptsFlatTrustedFoldersShape() throws {
        // The shape Gemini CLI actually writes today: {absolutePath: "TRUST_FOLDER"}.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"/Users/t/dev/flat":"TRUST_FOLDER","/Users/t/dev/parent":"TRUST_PARENT"}"#
            .write(to: root.appendingPathComponent("trustedFolders.json"),
                   atomically: true, encoding: .utf8)

        let map = GeminiSessionParser.projectMap(geminiRoot: root)
        XCTAssertEqual(
            map[GeminiSessionParser.pathHash("/Users/t/dev/flat")], "/Users/t/dev/flat")
        XCTAssertEqual(
            map[GeminiSessionParser.pathHash("/Users/t/dev/parent")], "/Users/t/dev/parent")
    }
}
