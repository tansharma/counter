import Foundation

/// Dispatches parsing across every enabled agent source and merges the results.
/// Detection is a cheap directory-exists check so Settings can label sources that
/// have no data on this machine. All per-agent specifics (root paths, detection
/// check, which parser to call) live in `AgentSource.config` — this type just
/// iterates `AgentSource.allCases` and applies it.
public enum UsageCollector {

    /// Where each agent keeps its session data, relative to the home directory.
    public static func defaultRoots(home: URL) -> [AgentSource: [URL]] {
        Dictionary(uniqueKeysWithValues: AgentSource.allCases.map { agent in
            (agent, (AgentSource.config[agent]?.rootPaths ?? []).map(home.appendingPathComponent))
        })
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

        return Set(AgentSource.allCases.filter { agent in
            (AgentSource.config[agent]?.detectionPaths ?? []).contains(where: exists)
        })
    }

    /// Parses every enabled agent's session files and returns one merged,
    /// timestamp-sorted event stream.
    public static func parseAll(enabled: Set<AgentSource>, home: URL) -> [UsageEvent] {
        let roots = defaultRoots(home: home)
        var events: [UsageEvent] = []
        for agent in AgentSource.allCases where enabled.contains(agent) {
            guard let config = AgentSource.config[agent] else { continue }
            events.append(contentsOf: config.parse(roots[agent] ?? []))
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }
}
