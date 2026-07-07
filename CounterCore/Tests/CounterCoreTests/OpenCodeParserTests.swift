import XCTest
@testable import CounterCore

final class OpenCodeParserTests: XCTestCase {

    private let sessionJSON = """
    {"id":"ses_1","directory":"/Users/t/dev/ledger","title":"Fix parser",\
    "time":{"created":1780000000000,"updated":1780000600000}}
    """

    private func assistantMessage(
        id: String = "msg_1",
        model: String = "claude-sonnet-5",
        created: Int64 = 1_780_000_100_000,
        tokens: String? = #"{"input":100,"output":50,"cache":{"read":400,"write":25}}"#
    ) -> String {
        let tok = tokens.map { #","tokens":\#($0)"# } ?? ""
        return """
        {"id":"\(id)","sessionID":"ses_1","role":"assistant","modelID":"\(model)",\
        "providerID":"anthropic","time":{"created":\(created)}\(tok)}
        """
    }

    func testParsesAssistantMessageTokens() {
        let events = OpenCodeParser.parseSession(
            sessionJSON: sessionJSON,
            messageJSONs: [assistantMessage()]
        )
        XCTAssertEqual(events.count, 1)
        let event = try! XCTUnwrap(events.first)
        XCTAssertEqual(event.agent, .opencode)
        XCTAssertEqual(event.sessionId, "opencode:ses_1")
        XCTAssertEqual(event.projectPath, "/Users/t/dev/ledger")
        XCTAssertEqual(event.model, "claude-sonnet-5")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.cacheReadTokens, 400)
        XCTAssertEqual(event.cacheCreationTokens, 25)
        XCTAssertEqual(
            event.timestamp, Date(timeIntervalSince1970: 1_780_000_100))
    }

    func testFallsBackToStepFinishPartWhenMessageLacksTokens() {
        let events = OpenCodeParser.parseSession(
            sessionJSON: sessionJSON,
            messageJSONs: [assistantMessage(tokens: nil)],
            stepFinishPartsByMessageId: [
                "msg_1": [
                    #"{"id":"prt_0","type":"text","text":"hi"}"#,
                    #"{"id":"prt_1","type":"step-finish","tokens":{"input":7,"output":3,"cache":{"read":1,"write":0}}}"#,
                ]
            ]
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.inputTokens, 7)
        XCTAssertEqual(events.first?.outputTokens, 3)
        XCTAssertEqual(events.first?.cacheReadTokens, 1)
    }

    func testIgnoresUserMessagesAndTokenlessAssistants() {
        let events = OpenCodeParser.parseSession(
            sessionJSON: sessionJSON,
            messageJSONs: [
                #"{"id":"msg_u","sessionID":"ses_1","role":"user","time":{"created":1780000050000}}"#,
                assistantMessage(id: "msg_no_tokens", tokens: nil),
                assistantMessage(id: "msg_ok"),
            ]
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.inputTokens, 100)
    }

    func testReadsModelFromNestedModelObject() {
        let message = """
        {"id":"msg_1","sessionID":"ses_1","role":"assistant",\
        "model":{"modelID":"gpt-5","providerID":"openai"},\
        "time":{"created":1780000100000},"tokens":{"input":1,"output":1,"cache":{}}}
        """
        let events = OpenCodeParser.parseSession(
            sessionJSON: sessionJSON, messageJSONs: [message])
        XCTAssertEqual(events.first?.model, "gpt-5")
    }

    func testMalformedSessionYieldsNoEvents() {
        XCTAssertTrue(
            OpenCodeParser.parseSession(
                sessionJSON: "not json", messageJSONs: [assistantMessage()]
            ).isEmpty
        )
        XCTAssertTrue(
            OpenCodeParser.parseSession(
                sessionJSON: #"{"directory":"/p"}"#, messageJSONs: [assistantMessage()]
            ).isEmpty
        )
    }
}
