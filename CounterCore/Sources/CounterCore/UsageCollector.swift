import Foundation

/// Dispatches parsing across every enabled agent source and merges the results.
/// Detection is a cheap directory-exists check so Settings can label sources that
/// have no data on this machine.
public enum UsageCollector {

    /// Where each agent keeps its session data, relative to the home directory.
    public static func defaultRoots(home: URL) -> [AgentSource: [URL]] {
        [
            .claude: [home.appendingPathComponent(".claude/projects")],
            .codex: [
                home.appendingPathComponent(".codex/sessions"),
                home.appendingPathComponent(".codex/archived_sessions"),
            ],
            .gemini: [home.appendingPathComponent(".gemini")],
            .opencode: [home.appendingPathComponent(".local/share/opencode")],
        ]
    }

    /// Agents whose session directory exists on this machine.
    public static func detectedAgents(home: URL) -> Set<AgentSource> {
        let fileManager = FileManager.default
        func exists(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: home.appendingPathComponent(path).path, isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }

        var detected: Set<AgentSource> = []
        if exists(".claude/projects") { detected.insert(.claude) }
        if exists(".codex/sessions") || exists(".codex/archived_sessions") {
            detected.insert(.codex)
        }
        if exists(".gemini/tmp") { detected.insert(.gemini) }
        if exists(".local/share/opencode/storage/session") { detected.insert(.opencode) }
        return detected
    }

    /// Parses every enabled agent's session files and returns one merged,
    /// timestamp-sorted event stream.
    public static func parseAll(enabled: Set<AgentSource>, home: URL) -> [UsageEvent] {
        let roots = defaultRoots(home: home)
        var events: [UsageEvent] = []
        for agent in AgentSource.allCases where enabled.contains(agent) {
            switch agent {
            case .claude:
                for root in roots[.claude] ?? [] {
                    events.append(contentsOf: SessionLogParser.parseAll(projectsRoot: root))
                }
            case .codex:
                events.append(contentsOf: CodexSessionParser.parseAll(roots: roots[.codex] ?? []))
            case .gemini:
                for root in roots[.gemini] ?? [] {
                    events.append(contentsOf: GeminiSessionParser.parseAll(geminiRoot: root))
                }
            case .opencode:
                for root in roots[.opencode] ?? [] {
                    events.append(contentsOf: OpenCodeParser.parseAll(opencodeRoot: root))
                }
            }
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }
}
