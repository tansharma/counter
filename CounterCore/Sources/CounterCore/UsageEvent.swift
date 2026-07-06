import Foundation

/// One billable assistant turn extracted from a Claude Code session log.
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

    public init(
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        projectPath: String,
        sessionId: String
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.projectPath = projectPath
        self.sessionId = sessionId
    }

    /// Every token the API processed for this turn.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Last path component of the project directory, for display.
    public var projectName: String {
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
