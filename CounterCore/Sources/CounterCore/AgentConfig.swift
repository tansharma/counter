import Foundation

extension AgentSource {

    /// Everything that varies per agent EXCEPT its actual parsing logic: where its
    /// session data lives, how to tell it's installed on this machine, how to
    /// dispatch to its (unrelated, on-disk-shape-specific) parser, and which chart
    /// color it gets. Adding a new agent means adding one case to `AgentSource` plus
    /// one entry here — `UsageCollector` and `agentColor` derive everything else.
    public struct Config: Sendable {
        /// Where this agent's session data lives, relative to the home directory.
        public let rootPaths: [String]
        /// Relative-to-home paths whose existence marks this agent "detected" for the
        /// Settings "not detected" caption. Usually the same as `rootPaths`, but some
        /// agents need a narrower check (e.g. OpenCode's DB-only installs lack
        /// `storage/session`; Gemini's root exists before any session is ever logged).
        public let detectionPaths: [String]
        /// Stable index into `Theme.series` for chart coloring, declared explicitly
        /// (not derived from `AgentSource.allCases.firstIndex`) so inserting a new
        /// case doesn't reshuffle existing agents' colors.
        public let chartColorIndex: Int
        /// Parses this agent's session files given its resolved root URLs (empty
        /// roots yield no events). The parser itself (`SessionLogParser`,
        /// `CodexSessionParser`, etc.) stays a separate, pure, fixture-tested type —
        /// this closure is just the dispatch.
        public let parse: @Sendable ([URL]) -> [UsageEvent]

        public init(
            rootPaths: [String],
            detectionPaths: [String],
            chartColorIndex: Int,
            parse: @escaping @Sendable ([URL]) -> [UsageEvent]
        ) {
            self.rootPaths = rootPaths
            self.detectionPaths = detectionPaths
            self.chartColorIndex = chartColorIndex
            self.parse = parse
        }
    }

    /// The one place a new agent's plumbing gets wired in.
    public static let config: [AgentSource: Config] = [
        .claude: Config(
            rootPaths: [".claude/projects"],
            detectionPaths: [".claude/projects"],
            chartColorIndex: 0,
            parse: { roots in roots.flatMap { SessionLogParser.parseAll(projectsRoot: $0) } }
        ),
        .codex: Config(
            rootPaths: [".codex/sessions", ".codex/archived_sessions"],
            detectionPaths: [".codex/sessions", ".codex/archived_sessions"],
            chartColorIndex: 1,
            parse: { roots in CodexSessionParser.parseAll(roots: roots) }
        ),
        .gemini: Config(
            rootPaths: [".gemini"],
            detectionPaths: [".gemini/tmp"],
            chartColorIndex: 2,
            parse: { roots in roots.flatMap { GeminiSessionParser.parseAll(geminiRoot: $0) } }
        ),
        .opencode: Config(
            rootPaths: [".local/share/opencode"],
            detectionPaths: [".local/share/opencode/storage/session"],
            chartColorIndex: 3,
            parse: { roots in roots.flatMap { OpenCodeParser.parseAll(opencodeRoot: $0) } }
        ),
    ]

    /// Stable per-agent chart color index — see `Config.chartColorIndex`. Falls back
    /// to 0 if a case is ever added to `AgentSource` without a matching `config` entry.
    public var chartColorIndex: Int {
        AgentSource.config[self]?.chartColorIndex ?? 0
    }
}
