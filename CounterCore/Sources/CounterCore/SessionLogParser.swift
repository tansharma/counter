import Foundation

/// Tolerant parser for Claude Code session logs (`~/.claude/projects/*/*.jsonl`).
///
/// Only assistant lines carrying `message.usage` become events. A streamed assistant
/// message appears as several lines sharing one `message.id` with evolving usage, so
/// lines are deduped by id keeping the chunk with the most output tokens. Unknown line
/// types, malformed JSON, and `<synthetic>` model lines are skipped — one bad line must
/// never abort a file.
public enum SessionLogParser {

    public static func parse(jsonl: String) -> [UsageEvent] {
        var byMessageId: [String: UsageEvent] = [:]
        var anonymous: [UsageEvent] = []

        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  root["type"] as? String == "assistant",
                  let message = root["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String,
                  model != "<synthetic>",
                  let timestampString = root["timestamp"] as? String,
                  let timestamp = parseTimestamp(timestampString)
            else { continue }

            let event = UsageEvent(
                timestamp: timestamp,
                model: model,
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0,
                cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                projectPath: root["cwd"] as? String ?? "",
                sessionId: root["sessionId"] as? String ?? ""
            )

            if let messageId = message["id"] as? String {
                if let existing = byMessageId[messageId], existing.outputTokens >= event.outputTokens {
                    continue
                }
                byMessageId[messageId] = event
            } else {
                anonymous.append(event)
            }
        }

        let sorted = (Array(byMessageId.values) + anonymous).sorted { $0.timestamp < $1.timestamp }
        return normalizeToSessionRoot(sorted)
    }

    /// A session's `cwd` drifts when the agent cd's into subfolders mid-run, which would
    /// splinter one project into many. Pin every event in a session to the session's
    /// dominant root: subpaths collapse into their parent path, then the root whose
    /// group carries the most events wins. (Handles both mid-session `cd` noise and
    /// projects whose folder was renamed part-way through their history.)
    public static func normalizeToSessionRoot(_ events: [UsageEvent]) -> [UsageEvent] {
        var rootBySession: [String: String] = [:]

        for (session, group) in Dictionary(grouping: events, by: \.sessionId) {
            let paths = group.map(\.projectPath).filter { !$0.isEmpty }
            guard !paths.isEmpty else { continue }

            // Shortest-first so every path collapses into its outermost ancestor present.
            let roots = Array(Set(paths)).sorted { $0.count < $1.count }
            var countByRoot: [String: Int] = [:]
            for path in paths {
                let root = roots.first { path == $0 || path.hasPrefix($0 + "/") } ?? path
                countByRoot[root, default: 0] += 1
            }
            rootBySession[session] = countByRoot.max {
                ($0.value, $1.key) < ($1.value, $0.key) // most events; ties break lexically
            }?.key
        }

        return events.map { event in
            guard let root = rootBySession[event.sessionId], root != event.projectPath else {
                return event
            }
            return UsageEvent(
                timestamp: event.timestamp,
                model: event.model,
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cacheCreationTokens: event.cacheCreationTokens,
                cacheReadTokens: event.cacheReadTokens,
                projectPath: root,
                sessionId: event.sessionId,
                agent: event.agent
            )
        }
    }

    /// Parses every `.jsonl` under `~/.claude/projects` (or an override root).
    public static func parseAll(projectsRoot: URL) -> [UsageEvent] {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil
        ) else { return [] }

        var events: [UsageEvent] = []
        for dir in projectDirs {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                events.append(contentsOf: parse(jsonl: content))
            }
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// Reads account details out of ~/.claude.json.
    public static func parseAccountInfo(claudeJson: URL) -> AccountInfo {
        guard let data = try? Data(contentsOf: claudeJson),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return AccountInfo() }

        return AccountInfo(
            displayName: account["displayName"] as? String,
            email: account["emailAddress"] as? String,
            rateLimitTier: account["userRateLimitTier"] as? String
        )
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        LogTimestamp.parse(string)
    }
}
