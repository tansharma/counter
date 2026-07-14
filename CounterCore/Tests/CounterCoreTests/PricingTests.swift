import XCTest
@testable import CounterCore

final class PricingTests: XCTestCase {

    private func event(
        model: String,
        input: Int = 0, output: Int = 0, cacheCreate: Int = 0, cacheRead: Int = 0
    ) -> UsageEvent {
        UsageEvent(
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            projectPath: "/p",
            sessionId: "s"
        )
    }

    func testLongestPrefixWins() {
        XCTAssertEqual(Pricing.rate(forModel: "gpt-5-mini-2026-01")?.inputPerMTok, 0.25)
        XCTAssertEqual(Pricing.rate(forModel: "gpt-5-2026-01")?.inputPerMTok, 1.25)
        XCTAssertEqual(
            Pricing.rate(forModel: "gemini-2.5-flash-lite")?.outputPerMTok, 0.40)
        XCTAssertEqual(Pricing.rate(forModel: "gemini-2.5-flash")?.outputPerMTok, 2.50)
    }

    func testClaudeCostArithmeticUnchanged() {
        // 1M of everything on sonnet: 3 input + 15 output + 3*1.25 write + 3*0.1 read.
        let cost = Pricing.estimatedCostUSD(for: event(
            model: "claude-sonnet-5",
            input: 1_000_000, output: 1_000_000,
            cacheCreate: 1_000_000, cacheRead: 1_000_000
        ))
        XCTAssertEqual(cost, 3 + 15 + 3.75 + 0.3, accuracy: 0.0001)
    }

    func testGeminiCacheReadBillsAtQuarterInputRate() {
        let cost = Pricing.estimatedCostUSD(for: event(
            model: "gemini-2.5-pro", cacheRead: 1_000_000
        ))
        XCTAssertEqual(cost, 1.25 * 0.25, accuracy: 0.0001)
    }

    func testOpenAICachedInputBillsAtTenthInputRate() {
        let cost = Pricing.estimatedCostUSD(for: event(
            model: "gpt-5-codex", cacheRead: 1_000_000
        ))
        XCTAssertEqual(cost, 1.25 * 0.1, accuracy: 0.0001)
    }

    func testCacheSavingsUseTheModelsReadMultiplier() {
        // Gemini reads cost 0.25x, so savings are 0.75x the input rate.
        let savings = Pricing.cacheSavingsUSD(for: event(
            model: "gemini-2.5-pro", cacheRead: 1_000_000
        ))
        XCTAssertEqual(savings, 1.25 * 0.75, accuracy: 0.0001)
        // Claude reads cost 0.1x, preserving the original 0.9x behavior.
        let claudeSavings = Pricing.cacheSavingsUSD(for: event(
            model: "claude-sonnet-5", cacheRead: 1_000_000
        ))
        XCTAssertEqual(claudeSavings, 3.0 * 0.9, accuracy: 0.0001)
    }

    func testLocalModelDetection() {
        XCTAssertTrue(Pricing.isLocalModel("qwen2.5vl:7b"))
        XCTAssertTrue(Pricing.isLocalModel("qwen2.5-coder"))
        XCTAssertTrue(Pricing.isLocalModel("llama3.3:70b"))
        XCTAssertTrue(Pricing.isLocalModel("DeepSeek-R1:8b"))
        XCTAssertTrue(Pricing.isLocalModel("ollama/mymodel"))
        XCTAssertTrue(Pricing.isLocalModel("custom-model:latest")) // ollama tag heuristic
        XCTAssertFalse(Pricing.isLocalModel("claude-sonnet-5"))
        XCTAssertFalse(Pricing.isLocalModel("gpt-5-codex"))
        XCTAssertFalse(Pricing.isLocalModel("gemini-2.5-pro"))
        // A hypothetical unrecognized cloud/provider-routed id that happens to
        // contain ":" shouldn't be misclassified as local — its suffix doesn't
        // look like an Ollama size/variant tag (too long, hyphenated, no letters
        // once you isolate a plausible tag boundary).
        XCTAssertFalse(Pricing.isLocalModel("acme-frontier-cloud:enterprise-2026-01"))
        XCTAssertFalse(Pricing.isLocalModel("acme-frontier-cloud:2026")) // numeric-only version suffix
    }

    func testLocalModelCostsZeroButHasCloudEquivalent() {
        let local = event(model: "qwen2.5vl:7b", input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(Pricing.estimatedCostUSD(for: local), 0)
        // Reference rate: 1.0 in + 5.0 out per MTok.
        XCTAssertEqual(Pricing.cloudEquivalentUSD(for: local), 6.0, accuracy: 0.0001)
        // Cloud models have no "cloud equivalent" — they already cost real money.
        XCTAssertEqual(
            Pricing.cloudEquivalentUSD(for: event(model: "claude-sonnet-5", input: 1_000_000)), 0)
    }

    func testUnknownModelCostsZero() {
        XCTAssertEqual(
            Pricing.estimatedCostUSD(for: event(model: "mystery-model", input: 1_000_000)), 0)
        XCTAssertNil(Pricing.rate(forModel: "mystery-model"))
    }
}
