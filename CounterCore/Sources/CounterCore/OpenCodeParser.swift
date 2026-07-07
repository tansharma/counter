import Foundation

/// Tolerant parser for OpenCode's storage-file backend
/// (`~/.local/share/opencode/storage/`).
///
/// A session is split across files: `storage/session/<projectDir>/<id>.json` holds
/// identity (`id`, `directory`, `time.created` in ms), `storage/message/<sessionID>/`
/// holds one JSON per message with `tokens: {input, output, cache: {read, write}}`,
/// and older messages without a `tokens` object carry usage on `"type": "step-finish"`
/// parts under `storage/part/<messageID>/`. Newer OpenCode builds use a SQLite
/// database instead, which this parser deliberately does not read — those installs
/// show as "not detected".
public enum OpenCodeParser {

    public static func parseSession(
        sessionJSON: String,
        messageJSONs: [String],
        stepFinishPartsByMessageId: [String: [String]] = [:]
    ) -> [UsageEvent] {
        guard let session = jsonObject(sessionJSON),
              let sessionId = session["id"] as? String, !sessionId.isEmpty
        else { return [] }
        let directory = session["directory"] as? String ?? ""
        let sessionCreated = millisDate((session["time"] as? [String: Any])?["created"])

        var events: [UsageEvent] = []
        for messageJSON in messageJSONs {
            guard let message = jsonObject(messageJSON),
                  message["role"] as? String == "assistant"
            else { continue }

            var tokens = message["tokens"] as? [String: Any]
            if tokens == nil, let messageId = message["id"] as? String {
                // Old-format messages carry usage on their step-finish parts instead.
                for partJSON in stepFinishPartsByMessageId[messageId] ?? [] {
                    guard let part = jsonObject(partJSON),
                          part["type"] as? String == "step-finish",
                          let partTokens = part["tokens"] as? [String: Any]
                    else { continue }
                    tokens = partTokens
                    break
                }
            }
            guard let tokens else { continue }
            let cache = tokens["cache"] as? [String: Any] ?? [:]

            let timestamp = millisDate((message["time"] as? [String: Any])?["created"])
                ?? sessionCreated
            guard let timestamp else { continue }

            events.append(UsageEvent(
                timestamp: timestamp,
                model: modelId(of: message),
                inputTokens: tokens["input"] as? Int ?? 0,
                outputTokens: tokens["output"] as? Int ?? 0,
                cacheCreationTokens: cache["write"] as? Int ?? 0,
                cacheReadTokens: cache["read"] as? Int ?? 0,
                projectPath: directory,
                sessionId: "opencode:" + sessionId,
                agent: .opencode
            ))
        }
        return events
    }

    /// Parses every session under `<opencodeRoot>/storage/session/*/*.json`.
    public static func parseAll(opencodeRoot: URL) -> [UsageEvent] {
        let fileManager = FileManager.default
        let storage = opencodeRoot.appendingPathComponent("storage")
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: storage.appendingPathComponent("session"), includingPropertiesForKeys: nil
        ) else { return [] }

        var events: [UsageEvent] = []
        for dir in projectDirs {
            guard let sessionFiles = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for file in sessionFiles where file.pathExtension == "json" {
                guard let sessionJSON = try? String(contentsOf: file, encoding: .utf8),
                      let sessionId = jsonObject(sessionJSON)?["id"] as? String
                else { continue }
                let messages = jsonContents(
                    of: storage.appendingPathComponent("message/" + sessionId))
                // Part directories are only read for messages that lack tokens.
                var parts: [String: [String]] = [:]
                for (messageId, json) in messages {
                    guard let message = jsonObject(json),
                          message["role"] as? String == "assistant",
                          message["tokens"] == nil
                    else { continue }
                    parts[messageId] = jsonContents(
                        of: storage.appendingPathComponent("part/" + messageId)
                    ).map(\.1)
                }
                events.append(contentsOf: parseSession(
                    sessionJSON: sessionJSON,
                    messageJSONs: messages.map(\.1),
                    stepFinishPartsByMessageId: parts
                ))
            }
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// Reads every `.json` in a directory as (basename, contents), sorted by name.
    private static func jsonContents(of dir: URL) -> [(String, String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                (try? String(contentsOf: file, encoding: .utf8)).map {
                    (file.deletingPathExtension().lastPathComponent, $0)
                }
            }
    }

    private static func modelId(of message: [String: Any]) -> String {
        if let model = message["modelID"] as? String, !model.isEmpty { return model }
        if let nested = message["model"] as? [String: Any],
           let model = nested["modelID"] as? String, !model.isEmpty { return model }
        return "unknown"
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    private static func millisDate(_ value: Any?) -> Date? {
        let millis: Double? = switch value {
        case let number as Double: number
        case let number as Int: Double(number)
        default: nil
        }
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
