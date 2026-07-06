import Foundation

/// Estimated USD cost per model, using published per-MTok rates.
/// Cache writes bill at 1.25x the input rate; cache reads at 0.1x.
public enum Pricing {

    public struct Rate: Sendable {
        public let inputPerMTok: Double
        public let outputPerMTok: Double
    }

    /// Longest-prefix match table — order matters only for readability; matching picks
    /// the longest prefix that fits the model id.
    public static let rates: [String: Rate] = [
        "claude-fable-5": Rate(inputPerMTok: 10.0, outputPerMTok: 50.0),
        "claude-mythos-5": Rate(inputPerMTok: 10.0, outputPerMTok: 50.0),
        "claude-opus": Rate(inputPerMTok: 5.0, outputPerMTok: 25.0),
        "claude-sonnet": Rate(inputPerMTok: 3.0, outputPerMTok: 15.0),
        "claude-haiku": Rate(inputPerMTok: 1.0, outputPerMTok: 5.0),
    ]

    public static func rate(forModel model: String) -> Rate? {
        var best: (prefix: String, rate: Rate)?
        for (prefix, rate) in rates where model.hasPrefix(prefix) {
            if best == nil || prefix.count > best!.prefix.count {
                best = (prefix, rate)
            }
        }
        return best?.rate
    }

    /// Estimated cost in USD for one event. Unknown models cost zero (shown as such).
    public static func estimatedCostUSD(for event: UsageEvent) -> Double {
        guard let rate = rate(forModel: event.model) else { return 0 }
        let million = 1_000_000.0
        let input = Double(event.inputTokens) / million * rate.inputPerMTok
        let output = Double(event.outputTokens) / million * rate.outputPerMTok
        let cacheWrite = Double(event.cacheCreationTokens) / million * rate.inputPerMTok * 1.25
        let cacheRead = Double(event.cacheReadTokens) / million * rate.inputPerMTok * 0.1
        return input + output + cacheWrite + cacheRead
    }

    /// What the cache-read tokens would have cost at the full input rate, minus what
    /// they actually cost — the money caching saved.
    public static func cacheSavingsUSD(for event: UsageEvent) -> Double {
        guard let rate = rate(forModel: event.model) else { return 0 }
        return Double(event.cacheReadTokens) / 1_000_000.0 * rate.inputPerMTok * 0.9
    }
}
