import Foundation

struct SessionRunwayUsageRecord: Hashable, Sendable {
    let id: String
    let tokens: Int64
    let observedAt: Date?
}

struct SessionRunwayUsageData: Sendable {
    let cumulativeTokenTotal: Int64?
    let incrementalRecords: [SessionRunwayUsageRecord]
    let supported: Bool
}

struct SessionRunwayParsedCandidate: Sendable {
    let provider: SessionRunwayProvider
    let sourcePath: String
    let sessionID: String
    let groupID: String
    let isSubagent: Bool
    let title: String
    let projectName: String?
    let projectPath: String?
    let branch: String?
    let lastActivityAt: Date?
    let fileModifiedAt: Date
    let futureTimestampRejected: Bool
    let parseDegraded: Bool
    let usage: SessionRunwayUsageData
}

struct SessionRunwayCodexTitleLookup: Sendable {
    let titleFor: @Sendable (_ sourcePath: String, _ sessionID: String) -> String?

    static let none = SessionRunwayCodexTitleLookup { _, _ in nil }
}

enum SessionRunwayParser {
    static func parse(
        provider: SessionRunwayProvider,
        url: URL,
        prefix: Data?,
        tail: Data?,
        fileModifiedAt: Date,
        now: Date,
        rules: SessionRunwayRules,
        codexTitles: SessionRunwayCodexTitleLookup = .none
    ) -> SessionRunwayParsedCandidate? {
        let objects = objectsFrom(prefix: prefix, tail: tail)

        let sourcePath = url.standardizedFileURL.path
        let fallbackID = fallbackSessionID(for: url)
        let sessionID = firstString(in: objects, paths: sessionIDPaths(for: provider)) ?? fallbackID
        let projectPath = firstString(in: objects, paths: projectPaths(for: provider))
        let projectName = projectPath.flatMap(projectName(from:))
        let branch = firstString(in: objects, paths: branchPaths(for: provider))
        let explicitTitle = firstExplicitTitle(in: objects, provider: provider)
        let firstPrompt = firstMeaningfulUserPrompt(in: objects, provider: provider)
        let stateTitle = provider == .codex ? codexTitles.titleFor(sourcePath, sessionID) : nil
        let title = compactTitle(
            stateTitle ?? explicitTitle ?? firstPrompt ?? projectName ?? shortID(sessionID),
            fallback: shortID(sessionID)
        )

        var latestDate: Date?
        var futureTimestampRejected = false
        var parseDegraded = false
        for object in objects {
            let parsed = parseTimestamp(object["timestamp"], now: now, tolerance: rules.clockSkewTolerance)
            if parsed.rejectedFuture { futureTimestampRejected = true }
            if let date = parsed.date, latestDate.map({ date > $0 }) != false {
                latestDate = date
            }
        }

        let usage = usageData(from: objects, provider: provider, now: now, rules: rules)
        let parentID = firstString(in: objects, paths: parentPaths(for: provider))
        let pathParentID = subagentParentID(for: url)
        let groupID = parentID ?? pathParentID ?? sessionID
        let isSubagent = parentID != nil || pathParentID != nil || url.pathComponents.contains("subagents")

        if projectPath == nil && projectName == nil {
            parseDegraded = true
        }
        if branch == nil && provider == .codex {
            // Branch is optional. Keep this out of diagnostics; schema drift is
            // not a parse failure when identity/title are still usable.
        }

        return SessionRunwayParsedCandidate(
            provider: provider,
            sourcePath: sourcePath,
            sessionID: sessionID,
            groupID: groupID,
            isSubagent: isSubagent,
            title: title,
            projectName: projectName,
            projectPath: projectPath,
            branch: branch,
            lastActivityAt: latestDate,
            fileModifiedAt: fileModifiedAt,
            futureTimestampRejected: futureTimestampRejected,
            parseDegraded: parseDegraded,
            usage: usage
        )
    }

    static func compactTitle(_ value: String, fallback: String, maxLength: Int = 48) -> String {
        let sanitized = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = sanitized.isEmpty ? fallback : sanitized
        guard result.count > maxLength else { return result }
        let prefix = result.prefix(max(1, maxLength - 1))
        return String(prefix).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func meaningfulPrompt(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = compactTitle(value, fallback: "")
        guard !compact.isEmpty else { return nil }
        let generic = Set(["ok", "okay", "yes", "no", "continue", "go ahead", "thanks", "thank you"])
        guard !generic.contains(compact.lowercased()) else { return nil }
        return compact
    }

    private static func objectsFrom(prefix: Data?, tail: Data?) -> [[String: Any]] {
        var objects: [[String: Any]] = []
        var seenRecordKeys = Set<String>()
        for data in [prefix, tail].compactMap({ $0 }) {
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }
                let recordKey = recordID(in: object) ?? "line-\(index)-\(line.hashValue)"
                guard seenRecordKeys.insert(recordKey).inserted else { continue }
                objects.append(object)
            }
        }
        return objects
    }

    private static func recordID(in object: [String: Any]) -> String? {
        firstString(in: [object], paths: [
            ["uuid"], ["id"], ["message_id"], ["payload", "id"], ["payload", "turn_id"],
            ["sessionId"], ["session_id"]
        ])
    }

    private static func sessionIDPaths(for provider: SessionRunwayProvider) -> [[String]] {
        switch provider {
        case .codex:
            return [["payload", "id"], ["payload", "session_id"], ["session_id"], ["id"]]
        case .claudeCode:
            return [["sessionId"], ["session_id"], ["sessionId", "id"]]
        }
    }

    private static func projectPaths(for provider: SessionRunwayProvider) -> [[String]] {
        switch provider {
        case .codex:
            return [["payload", "cwd"], ["cwd"], ["payload", "workspace", "cwd"]]
        case .claudeCode:
            return [["cwd"], ["projectPath"], ["project_path"]]
        }
    }

    private static func branchPaths(for provider: SessionRunwayProvider) -> [[String]] {
        switch provider {
        case .codex:
            return [["payload", "git", "branch"], ["git", "branch"], ["gitBranch"], ["payload", "gitBranch"]]
        case .claudeCode:
            return [["gitBranch"], ["git_branch"], ["branch"]]
        }
    }

    private static func parentPaths(for provider: SessionRunwayProvider) -> [[String]] {
        switch provider {
        case .codex:
            return [["payload", "parent_session_id"], ["payload", "parentSessionId"], ["parent_session_id"], ["parentSessionId"]]
        case .claudeCode:
            return [["parentSessionId"], ["parent_session_id"], ["parentSessionID"]]
        }
    }

    private static func firstExplicitTitle(in objects: [[String: Any]], provider: SessionRunwayProvider) -> String? {
        for object in objects {
            let type = (string(at: ["type"], in: object) ?? "").lowercased()
            let payloadType = (string(at: ["payload", "type"], in: object) ?? "").lowercased()
            let titleRecord = type.contains("title") || payloadType.contains("title") || type == "session_meta"
            let paths: [[String]]
            if titleRecord {
                paths = [
                    ["title"], ["customTitle"], ["custom_title"], ["aiTitle"], ["ai_title"],
                    ["sessionTitle"], ["session_title"], ["payload", "title"], ["payload", "customTitle"],
                    ["payload", "custom_title"], ["payload", "aiTitle"], ["payload", "ai_title"]
                ]
            } else {
                paths = provider == .claudeCode && (type == "custom-title" || type == "ai-title")
                    ? [["title"], ["customTitle"], ["aiTitle"]]
                    : []
            }
            if let title = firstString(in: [object], paths: paths), meaningfulPrompt(title) != nil {
                return title
            }
        }
        return nil
    }

    private static func firstMeaningfulUserPrompt(in objects: [[String: Any]], provider: SessionRunwayProvider) -> String? {
        for object in objects {
            guard isUserRecord(object, provider: provider) else { continue }
            if let text = userText(in: object), let prompt = meaningfulPrompt(text) {
                return prompt
            }
        }
        return nil
    }

    private static func isUserRecord(_ object: [String: Any], provider: SessionRunwayProvider) -> Bool {
        let type = (string(at: ["type"], in: object) ?? "").lowercased()
        let payloadType = (string(at: ["payload", "type"], in: object) ?? "").lowercased()
        if provider == .codex {
            return payloadType == "user_message"
                || string(at: ["payload", "role"], in: object)?.lowercased() == "user"
                || string(at: ["role"], in: object)?.lowercased() == "user"
        }
        return type == "user" || type == "last-prompt"
            || string(at: ["message", "role"], in: object)?.lowercased() == "user"
    }

    private static func userText(in object: [String: Any]) -> String? {
        for path in [["payload", "message"], ["payload", "text"], ["message", "content"], ["lastPrompt"]] {
            if let value = value(at: path, in: object), let text = textValue(value) {
                return text
            }
        }
        if let content = value(at: ["payload", "content"], in: object) {
            return textValue(content)
        }
        return nil
    }

    private static func usageData(
        from objects: [[String: Any]],
        provider: SessionRunwayProvider,
        now: Date,
        rules: SessionRunwayRules
    ) -> SessionRunwayUsageData {
        switch provider {
        case .codex:
            var latestTotal: Int64?
            for object in objects {
                guard string(at: ["payload", "type"], in: object) == "token_count",
                      let total = integer(at: ["payload", "info", "total_token_usage", "total_tokens"], in: object)
                else { continue }
                latestTotal = max(latestTotal ?? total, total)
            }
            return SessionRunwayUsageData(
                cumulativeTokenTotal: latestTotal,
                incrementalRecords: [],
                supported: latestTotal != nil
            )
        case .claudeCode:
            var records: [SessionRunwayUsageRecord] = []
            for (index, object) in objects.enumerated() {
                guard let usage = value(at: ["message", "usage"], in: object) as? [String: Any],
                      let tokens = claudeTokenTotal(usage), tokens > 0
                else { continue }
                let id = firstString(in: [object], paths: [["uuid"], ["message", "id"], ["requestId"]])
                    ?? "usage-\(index)-\(object["timestamp"] as? String ?? "unknown")"
                let timestamp = parseTimestamp(object["timestamp"], now: now, tolerance: rules.clockSkewTolerance).date
                records.append(SessionRunwayUsageRecord(id: id, tokens: tokens, observedAt: timestamp))
            }
            return SessionRunwayUsageData(
                cumulativeTokenTotal: nil,
                incrementalRecords: records,
                supported: !records.isEmpty
            )
        }
    }

    private static func claudeTokenTotal(_ usage: [String: Any]) -> Int64? {
        let keys = [
            "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"
        ]
        let total = keys.compactMap { usage[$0] as? NSNumber }.reduce(Int64(0)) { partial, number in
            partial + max(0, number.int64Value)
        }
        return total > 0 ? total : nil
    }

    private static func subagentParentID(for url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard let subagentsIndex = components.lastIndex(of: "subagents"), subagentsIndex > 0 else { return nil }
        return components[subagentsIndex - 1]
    }

    private static func fallbackSessionID(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("rollout-") { return String(name.dropFirst("rollout-".count)) }
        return name
    }

    private static func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private static func projectName(from path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : compactTitle(name, fallback: name, maxLength: 32)
    }

    private static func parseTimestamp(_ raw: Any?, now: Date, tolerance: TimeInterval) -> (date: Date?, rejectedFuture: Bool) {
        let date: Date?
        if let string = raw as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        } else if let number = raw as? NSNumber {
            let seconds = number.doubleValue > 100_000_000_000
                ? number.doubleValue / 1000
                : number.doubleValue
            date = Date(timeIntervalSince1970: seconds)
        } else {
            date = nil
        }
        guard let date else { return (nil, false) }
        if date.timeIntervalSince(now) > tolerance {
            return (nil, true)
        }
        return (date, false)
    }

    private static func firstString(in objects: [[String: Any]], paths: [[String]]) -> String? {
        for object in objects {
            if let value = firstString(in: object, paths: paths) { return value }
        }
        return nil
    }

    private static func firstString(in object: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            if let string = string(at: path, in: object), !string.isEmpty { return string }
        }
        return nil
    }

    private static func string(at path: [String], in object: [String: Any]) -> String? {
        value(at: path, in: object) as? String
    }

    private static func integer(at path: [String], in object: [String: Any]) -> Int64? {
        guard let number = value(at: path, in: object) as? NSNumber else { return nil }
        return max(0, number.int64Value)
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        var current: Any = object
        for component in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[component] else { return nil }
            current = next
        }
        return current
    }

    private static func textValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            let parts = array.compactMap { item -> String? in
                if let string = item as? String { return string }
                if let dictionary = item as? [String: Any] {
                    return (dictionary["text"] as? String) ?? (dictionary["content"] as? String)
                }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if let dictionary = value as? [String: Any] {
            return (dictionary["text"] as? String) ?? (dictionary["content"] as? String)
        }
        return nil
    }
}
