import Foundation

/// Which local tool produced a usage event. Counter reads each agent's own
/// on-disk session logs; the raw value doubles as a stable settings key suffix.
public enum AgentSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case gemini
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        }
    }
}

/// One billable assistant turn extracted from an agent session log.
public struct UsageEvent: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    /// Working directory of the session (used to group by project).
    public let projectPath: String
    public let sessionId: String
    public let agent: AgentSource

    public init(
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        projectPath: String,
        sessionId: String,
        agent: AgentSource = .claude
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.projectPath = projectPath
        self.sessionId = sessionId
        self.agent = agent
    }

    /// Every token the API processed for this turn, cache reads included at full
    /// weight. This is what Anthropic's rate limits track (cache reads still cost
    /// compute, just discounted) — use it for the 5-hour block / weekly gauges,
    /// never for a "tokens used" headline.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Tokens actually new this turn: everything except cache reads. A long
    /// conversation re-reads its whole history from cache on every turn, so
    /// `totalTokens` inflates by 10-100x over a session — `newTokens` is what
    /// "tokens used" means to a human, and what most external usage trackers report.
    public var newTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens
    }

    /// Last path component of the project directory, for display. Surfaces
    /// Gemini's unresolved-hash fallback (see `GeminiSessionParser`) as an
    /// explicit placeholder rather than a bare hash that reads like a real
    /// folder name.
    public var projectName: String {
        if let hash = GeminiSessionParser.unresolvedHash(from: projectPath) {
            return "Unresolved Gemini project (\(hash))"
        }
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }
}

/// Account details read from ~/.claude.json (all optional — file shape may change).
public struct AccountInfo: Equatable, Sendable {
    public var displayName: String?
    public var email: String?
    public var rateLimitTier: String?

    public init(displayName: String? = nil, email: String? = nil, rateLimitTier: String? = nil) {
        self.displayName = displayName
        self.email = email
        self.rateLimitTier = rateLimitTier
    }
}
