import Foundation

/// Estimated USD cost per model, using published per-MTok rates.
/// Cache multipliers are relative to the input rate and vary by provider:
/// Anthropic bills cache writes at 1.25x and reads at 0.1x; OpenAI has no
/// separate write tier (cache_creation is always 0 in Codex logs) and bills
/// cached input at 0.1x; Google bills cached input at 0.25x. The whole table
/// is a static offline snapshot — rates drift, costs are estimates.
public enum Pricing {

    public struct Rate: Sendable {
        public let inputPerMTok: Double
        public let outputPerMTok: Double
        public let cacheReadMultiplier: Double
        public let cacheWriteMultiplier: Double

        public init(
            inputPerMTok: Double,
            outputPerMTok: Double,
            cacheReadMultiplier: Double = 0.1,
            cacheWriteMultiplier: Double = 1.25
        ) {
            self.inputPerMTok = inputPerMTok
            self.outputPerMTok = outputPerMTok
            self.cacheReadMultiplier = cacheReadMultiplier
            self.cacheWriteMultiplier = cacheWriteMultiplier
        }
    }

    /// Longest-prefix match table — order matters only for readability; matching picks
    /// the longest prefix that fits the model id.
    public static let rates: [String: Rate] = [
        // Anthropic (Claude Code)
        "claude-fable-5": Rate(inputPerMTok: 10.0, outputPerMTok: 50.0),
        "claude-mythos-5": Rate(inputPerMTok: 10.0, outputPerMTok: 50.0),
        "claude-opus": Rate(inputPerMTok: 5.0, outputPerMTok: 25.0),
        "claude-sonnet": Rate(inputPerMTok: 3.0, outputPerMTok: 15.0),
        "claude-haiku": Rate(inputPerMTok: 1.0, outputPerMTok: 5.0),
        // OpenAI (Codex)
        "gpt-5-codex": Rate(inputPerMTok: 1.25, outputPerMTok: 10.0),
        "gpt-5.1": Rate(inputPerMTok: 1.25, outputPerMTok: 10.0),
        "gpt-5-mini": Rate(inputPerMTok: 0.25, outputPerMTok: 2.0),
        "gpt-5-nano": Rate(inputPerMTok: 0.05, outputPerMTok: 0.40),
        "gpt-5": Rate(inputPerMTok: 1.25, outputPerMTok: 10.0),
        "o3": Rate(inputPerMTok: 2.0, outputPerMTok: 8.0),
        "o4-mini": Rate(inputPerMTok: 1.10, outputPerMTok: 4.40),
        "gpt-4.1-mini": Rate(inputPerMTok: 0.40, outputPerMTok: 1.60),
        "gpt-4.1-nano": Rate(inputPerMTok: 0.10, outputPerMTok: 0.40),
        "gpt-4.1": Rate(inputPerMTok: 2.0, outputPerMTok: 8.0),
        "gpt-4o-mini": Rate(inputPerMTok: 0.15, outputPerMTok: 0.60),
        "gpt-4o": Rate(inputPerMTok: 2.50, outputPerMTok: 10.0),
        "codex-mini": Rate(inputPerMTok: 1.50, outputPerMTok: 6.0),
        // Google (Gemini CLI)
        "gemini-2.5-pro": Rate(
            inputPerMTok: 1.25, outputPerMTok: 10.0, cacheReadMultiplier: 0.25),
        "gemini-2.5-flash-lite": Rate(
            inputPerMTok: 0.10, outputPerMTok: 0.40, cacheReadMultiplier: 0.25),
        "gemini-2.5-flash": Rate(
            inputPerMTok: 0.30, outputPerMTok: 2.50, cacheReadMultiplier: 0.25),
        "gemini-3-pro": Rate(
            inputPerMTok: 2.0, outputPerMTok: 12.0, cacheReadMultiplier: 0.25),
        "gemini-3-flash": Rate(
            inputPerMTok: 0.45, outputPerMTok: 3.0, cacheReadMultiplier: 0.25),
    ]

    // MARK: Local models

    /// Family prefixes of models that run locally (Ollama, LM Studio, llama.cpp).
    /// Matched case-insensitively against the model id, which may carry an
    /// Ollama-style size tag ("qwen2.5vl:7b") or a provider path ("ollama/qwen3").
    public static let localModelPrefixes: [String] = [
        "qwen", "llama", "codellama", "mistral", "mixtral", "deepseek", "gemma",
        "phi", "smollm", "starcoder", "codegemma", "devstral", "granite", "olmo",
        "ollama/", "lmstudio/", "local/",
    ]

    /// Matches an Ollama-style tag suffix: short, at least one letter (excludes
    /// purely numeric cloud version suffixes like ":0" or ":2026-01-15"), and built
    /// only from alphanumerics with "_"/"." separators (e.g. "7b", "70b", "latest",
    /// "q4_0", "v1.5") — never "-" or "/", which cloud/provider-routed ids do use.
    private static let ollamaTagPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9]+(?:[._][a-z0-9]+)*$"
    )

    /// True when `id` (already lowercased) ends in a colon followed by something
    /// that looks like an Ollama size/variant tag, as opposed to any arbitrary
    /// colon-bearing cloud model id.
    private static func hasOllamaStyleTag(_ id: String) -> Bool {
        guard let colon = id.lastIndex(of: ":") else { return false }
        let tag = String(id[id.index(after: colon)...])
        guard (1...12).contains(tag.count), tag.contains(where: \.isLetter) else { return false }
        let range = NSRange(tag.startIndex..., in: tag)
        return ollamaTagPattern.firstMatch(in: tag, range: range) != nil
    }

    /// True when the model id looks like a locally served model. Ollama tags
    /// (`name:size`) are also treated as local, but only when the tag actually
    /// looks like one — an unrecognized cloud id that happens to contain ":"
    /// falls through to "unknown model" instead of being misclassified as local.
    public static func isLocalModel(_ model: String) -> Bool {
        let id = model.lowercased()
        if localModelPrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        return hasOllamaStyleTag(id) && rate(forModel: model) == nil
    }

    /// Reference rate used to value local-model tokens: what the same tokens would
    /// have cost on a budget cloud coding model (haiku-class). An estimate by design.
    public static let localReferenceRate = Rate(inputPerMTok: 1.0, outputPerMTok: 5.0)

    /// Estimated USD the event would have cost on the reference cloud model —
    /// zero for cloud events (they already cost real money).
    public static func cloudEquivalentUSD(for event: UsageEvent) -> Double {
        guard isLocalModel(event.model) else { return 0 }
        let million = 1_000_000.0
        let rate = localReferenceRate
        let promptSide = Double(event.inputTokens + event.cacheCreationTokens
            + event.cacheReadTokens) / million * rate.inputPerMTok
        return promptSide + Double(event.outputTokens) / million * rate.outputPerMTok
    }

    public static func rate(forModel model: String) -> Rate? {
        var best: (prefix: String, rate: Rate)?
        for (prefix, rate) in rates where model.hasPrefix(prefix) {
            if best == nil || prefix.count > best!.prefix.count {
                best = (prefix, rate)
            }
        }
        return best?.rate
    }

    /// Estimated cost in USD for one event. Local and unknown models cost zero
    /// (the local guard keeps them free even if a matching cloud prefix is added).
    public static func estimatedCostUSD(for event: UsageEvent) -> Double {
        guard !isLocalModel(event.model), let rate = rate(forModel: event.model) else { return 0 }
        let million = 1_000_000.0
        let input = Double(event.inputTokens) / million * rate.inputPerMTok
        let output = Double(event.outputTokens) / million * rate.outputPerMTok
        let cacheWrite = Double(event.cacheCreationTokens) / million
            * rate.inputPerMTok * rate.cacheWriteMultiplier
        let cacheRead = Double(event.cacheReadTokens) / million
            * rate.inputPerMTok * rate.cacheReadMultiplier
        return input + output + cacheWrite + cacheRead
    }

    /// What the cache-read tokens would have cost at the full input rate, minus what
    /// they actually cost — the money caching saved.
    public static func cacheSavingsUSD(for event: UsageEvent) -> Double {
        guard let rate = rate(forModel: event.model) else { return 0 }
        return Double(event.cacheReadTokens) / 1_000_000.0
            * rate.inputPerMTok * (1 - rate.cacheReadMultiplier)
    }
}
