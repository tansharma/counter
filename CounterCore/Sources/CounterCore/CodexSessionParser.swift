import Foundation

/// Tolerant parser for Codex CLI rollout logs (`~/.codex/sessions/**/*.jsonl` and
/// `~/.codex/archived_sessions/**/*.jsonl`).
///
/// Each line is `{"timestamp": ..., "type": ..., "payload": {...}}`. A `session_meta`
/// line carries the session id and working directory; `turn_context` lines carry the
/// model; `event_msg` lines with `payload.type == "token_count"` carry usage under
/// `payload.info.last_token_usage`. Codex reports `input_tokens` with the cached
/// portion included, so the cached share is subtracted out and billed as cache reads.
/// Streaming re-emits identical usage payloads, which are skipped. Malformed lines
/// never abort a file.
public enum CodexSessionParser {

    public static func parse(jsonl: String, fallbackSessionId: String? = nil) -> [UsageEvent] {
        var events: [UsageEvent] = []
        var sessionId = fallbackSessionId ?? ""
        var projectPath = ""
        var currentModel = ""
        var lastUsageTriple: (input: Int, cached: Int, output: Int)?
        var forkGate = ForkGate()
        var sawSessionMeta = false

        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  let type = root["type"] as? String
            else { continue }
            let payload = root["payload"] as? [String: Any] ?? [:]

            switch type {
            case "session_meta":
                // A forked rollout replays the parent's session_meta too — the
                // fork's own meta came first and wins.
                guard !sawSessionMeta else { continue }
                sawSessionMeta = true
                if let id = payload["id"] as? String, !id.isEmpty {
                    sessionId = id
                }
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                    projectPath = cwd
                }
                forkGate.armFromMeta(payload, envelopeTimestamp: root["timestamp"] as? String)

            case "turn_context":
                guard !forkGate.suppresses(lineType: type, payload: payload) else { continue }
                if let model = payload["model"] as? String, !model.isEmpty {
                    currentModel = model
                }

            case "event_msg":
                guard !forkGate.suppresses(lineType: type, payload: payload),
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["last_token_usage"] as? [String: Any],
                      let timestampString = root["timestamp"] as? String,
                      let timestamp = LogTimestamp.parse(timestampString)
                else { continue }

                let totalInput = usage["input_tokens"] as? Int ?? 0
                let cached = usage["cached_input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let triple = (input: totalInput, cached: cached, output: output)
                if let last = lastUsageTriple, last == triple { continue }
                lastUsageTriple = triple

                events.append(UsageEvent(
                    timestamp: timestamp,
                    model: currentModel.isEmpty ? "unknown" : currentModel,
                    inputTokens: max(totalInput - cached, 0),
                    outputTokens: output,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cached,
                    projectPath: projectPath,
                    sessionId: "codex:" + sessionId,
                    agent: .codex
                ))

            default:
                if forkGate.suppresses(lineType: type, payload: payload) { continue }
            }
        }
        return events
    }

    /// Parses every `.jsonl` recursively under the given roots (missing roots are fine).
    public static func parseAll(roots: [URL]) -> [UsageEvent] {
        let fileManager = FileManager.default
        var events: [UsageEvent] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                // session_index.jsonl next to the session dirs only holds titles.
                guard file.lastPathComponent != "session_index.jsonl",
                      let content = try? String(contentsOf: file, encoding: .utf8)
                else { continue }
                let fallback = file.deletingPathExtension().lastPathComponent
                events.append(contentsOf: parse(jsonl: content, fallbackSessionId: fallback))
            }
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// Millisecond timestamp embedded in a UUIDv7, or nil for anything else.
    static func uuidV7Millis(_ id: String) -> Int64? {
        let hex = id.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32,
              hex[hex.index(hex.startIndex, offsetBy: 12)] == "7",
              let ms = Int64(hex.prefix(12), radix: 16)
        else { return nil }
        return ms
    }

    /// Suppresses the parent history a forked rollout replays at the top of the file,
    /// which would otherwise double count usage across the parent and the fork.
    ///
    /// `codex fork` copies the parent's lines into the new file with re-stamped
    /// envelope timestamps, so envelope times cannot locate the boundary. Turn ids
    /// are UUIDv7 values minted when the turn originally ran: every replayed turn
    /// predates the fork instant, and the first genuine turn is minted at or after
    /// it. The gate stays closed until the first `turn_context` whose `turn_id`
    /// timestamp is >= the fork's creation time. An unparseable anchor fails open
    /// rather than risk dropping live data.
    struct ForkGate {
        private(set) var active = false
        private var createdMs: Int64 = 0

        mutating func armFromMeta(_ payload: [String: Any], envelopeTimestamp: String?) {
            guard let forkedFrom = payload["forked_from_id"] as? String,
                  !forkedFrom.isEmpty
            else { return }
            var ms = (payload["id"] as? String).flatMap(uuidV7Millis)
            if ms == nil, let ts = payload["timestamp"] as? String,
               let date = LogTimestamp.parse(ts) {
                ms = Int64(date.timeIntervalSince1970 * 1000)
            }
            if ms == nil, let ts = envelopeTimestamp, let date = LogTimestamp.parse(ts) {
                ms = Int64(date.timeIntervalSince1970 * 1000)
            }
            guard let anchor = ms else { return } // no boundary anchor — fail open
            active = true
            createdMs = anchor
        }

        mutating func suppresses(lineType: String, payload: [String: Any]) -> Bool {
            guard active else { return false }
            guard lineType == "turn_context" else { return true }
            guard let turnId = payload["turn_id"] as? String, !turnId.isEmpty else {
                return true // pre-turn_id parent history
            }
            if let ms = uuidV7Millis(turnId), ms < createdMs {
                return true
            }
            active = false
            return false
        }
    }
}
