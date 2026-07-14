import CryptoKit
import Foundation

/// Tolerant parser for Gemini CLI session logs (`~/.gemini/tmp/<dir>/chats/session-*`).
///
/// Two shapes have shipped: (A) one JSON object with a `messages` array, and
/// (B) JSONL where a later record with the same `id` replaces the earlier one in
/// place. The `<dir>` component is either a project name or Gemini's SHA-256 hex
/// hash of the absolute project path, resolved via `~/.gemini/projects.json` and
/// `~/.gemini/trustedFolders.json`. Message `tokens.input`/`tokens.cached` are
/// cumulative across the session, so per-message deltas are taken; `thoughts`
/// tokens bill at the output rate and fold into output. Gemini appends to live
/// files, so partial trailing lines are skipped, never fatal.
public enum GeminiSessionParser {

    public static func parse(fileContents: String, projectPath: String) -> [UsageEvent] {
        let records = messageRecords(fileContents: fileContents)
        guard !records.sessionId.isEmpty else { return [] }

        var events: [UsageEvent] = []
        var prevInput = 0
        var prevCached = 0
        var lastModel = ""

        for message in records.messages {
            if let model = message["model"] as? String, !model.isEmpty {
                lastModel = model
            }
            guard let tokens = message["tokens"] as? [String: Any] else { continue }
            let input = tokens["input"] as? Int ?? 0
            let cached = tokens["cached"] as? Int ?? 0
            let output = tokens["output"] as? Int ?? 0
            let thoughts = tokens["thoughts"] as? Int ?? 0

            // input/cached are running totals; a smaller value means the counter reset.
            var inputDelta = input - prevInput
            var cachedDelta = cached - prevCached
            if inputDelta < 0 { inputDelta = input }
            if cachedDelta < 0 { cachedDelta = cached }
            prevInput = input
            prevCached = cached

            let timestamp = (message["timestamp"] as? String).flatMap(LogTimestamp.parse)
                ?? records.startTime
            guard let timestamp else { continue }

            events.append(UsageEvent(
                timestamp: timestamp,
                model: lastModel.isEmpty ? "unknown" : lastModel,
                inputTokens: inputDelta,
                outputTokens: output + thoughts,
                cacheCreationTokens: 0,
                cacheReadTokens: cachedDelta,
                projectPath: projectPath,
                sessionId: "gemini:" + records.sessionId,
                agent: .gemini
            ))
        }
        return events
    }

    /// Parses every session file under `<geminiRoot>/tmp/*/chats/`.
    public static func parseAll(geminiRoot: URL) -> [UsageEvent] {
        let fileManager = FileManager.default
        let tmpRoot = geminiRoot.appendingPathComponent("tmp")
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: nil
        ) else { return [] }
        let projects = projectMap(geminiRoot: geminiRoot)

        var events: [UsageEvent] = []
        for dir in projectDirs {
            let chats = dir.appendingPathComponent("chats")
            guard let files = try? fileManager.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: nil
            ) else { continue }
            let projectPath = resolveProjectPath(dirName: dir.lastPathComponent, in: projects)
            for file in files where isSessionFile(file) {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                events.append(contentsOf: parse(fileContents: content, projectPath: projectPath))
            }
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// Maps `~/.gemini/tmp` directory names (path hashes or project names) to the
    /// absolute project paths recorded in projects.json and trustedFolders.json.
    public static func projectMap(geminiRoot: URL) -> [String: String] {
        var result: [String: String] = [:]

        func add(paths: [String: String]) {
            for absPath in paths.keys.sorted() {
                let hash = pathHash(absPath)
                if result[hash] == nil { result[hash] = absPath }
                if let name = paths[absPath], !name.isEmpty, result[name] == nil {
                    result[name] = absPath
                }
            }
        }

        if let data = try? Data(contentsOf: geminiRoot.appendingPathComponent("projects.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = object["projects"] as? [String: String] {
            add(paths: projects)
        }
        if let data = try? Data(
            contentsOf: geminiRoot.appendingPathComponent("trustedFolders.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Two shapes exist in the wild: a wrapped array {"trustedFolders": [path]}
            // and a flat map {path: "TRUST_FOLDER"}.
            if let folders = object["trustedFolders"] as? [String] {
                add(paths: Dictionary(uniqueKeysWithValues: folders.map { ($0, "") }))
            } else {
                let paths = object.keys.filter { $0.hasPrefix("/") }
                add(paths: Dictionary(uniqueKeysWithValues: paths.map { ($0, "") }))
            }
        }
        return result
    }

    /// SHA-256 hex of the absolute path — Gemini CLI's project hash algorithm.
    static func pathHash(_ absolutePath: String) -> String {
        SHA256.hash(data: Data(absolutePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Prefix marking a project path as an unresolved-hash fallback rather than a
    /// real project directory — deliberately not path-shaped (no "/") so it can
    /// never be confused with a real project, and so `UsageEvent.projectName` /
    /// `ProjectSlice.isUnresolvedGeminiProject` can detect it later even after the
    /// event has been carried far from this parser.
    public static let unresolvedPathPrefix = "gemini-unresolved:"

    private static func resolveProjectPath(
        dirName: String, in projects: [String: String]
    ) -> String {
        if let path = projects[dirName] { return path }
        if isHexHash(dirName) {
            // Unmapped hash dirs still deserve a stable bucket rather than being
            // dropped, but must stay visibly distinct from a real project path —
            // if the mapping resolves later, at least the gap stays legible in
            // the meantime instead of silently posing as a real project.
            return unresolvedPathPrefix + dirName.prefix(8)
        }
        return dirName
    }

    /// The short hash tag from an unresolved-fallback path produced above, or nil
    /// if `path` isn't one.
    public static func unresolvedHash(from path: String) -> String? {
        guard path.hasPrefix(unresolvedPathPrefix) else { return nil }
        return String(path.dropFirst(unresolvedPathPrefix.count))
    }

    private static func isSessionFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("session-")
            && ["json", "jsonl"].contains(url.pathExtension)
    }

    private static func isHexHash(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
    }

    // MARK: Record extraction

    private struct Records {
        var sessionId = ""
        var startTime: Date?
        var messages: [[String: Any]] = []
    }

    private static func messageRecords(fileContents: String) -> Records {
        // Shape A: one JSON document holding the whole session.
        if let data = fileContents.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let root = object as? [String: Any],
           root["sessionId"] is String || root["messages"] is [Any] {
            var records = Records()
            records.sessionId = root["sessionId"] as? String ?? ""
            records.startTime = (root["startTime"] as? String).flatMap(LogTimestamp.parse)
            records.messages = (root["messages"] as? [[String: Any]] ?? [])
                .filter(isMessageRecord)
            return records
        }
        // Shape B: JSONL where later records with the same id replace earlier ones.
        var records = Records()
        var indexById: [String: Int] = [:]
        for line in fileContents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any]
            else { continue }
            if let id = record["sessionId"] as? String, !id.isEmpty {
                if records.sessionId.isEmpty { records.sessionId = id }
                if records.startTime == nil {
                    records.startTime = (record["startTime"] as? String)
                        .flatMap(LogTimestamp.parse)
                }
            }
            guard isMessageRecord(record) else { continue }
            if let id = record["id"] as? String, !id.isEmpty {
                if let index = indexById[id] {
                    records.messages[index] = record
                    continue
                }
                indexById[id] = records.messages.count
            }
            records.messages.append(record)
        }
        return records
    }

    private static func isMessageRecord(_ record: [String: Any]) -> Bool {
        let type = record["type"] as? String
        return type == "user" || type == "gemini"
    }
}
