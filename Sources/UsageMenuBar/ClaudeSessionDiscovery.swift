import Dispatch
import Foundation
import Darwin

enum ClaudeProcessActivityHint: String, Equatable, Sendable {
    case working
    case idle
    case unknown
}

struct ClaudeProcessEvidence: Equatable, Sendable {
    let pid: Int32
    let sessionID: String?
    let commandLine: String
    let workingDirectory: String?
    let tty: String?
    let lastActivity: Date?
    let activity: ClaudeProcessActivityHint

    init(
        pid: Int32,
        sessionID: String? = nil,
        commandLine: String = "",
        workingDirectory: String? = nil,
        tty: String? = nil,
        lastActivity: Date? = nil,
        activity: ClaudeProcessActivityHint = .unknown
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.tty = tty
        self.lastActivity = lastActivity
        self.activity = activity
    }
}

struct ClaudeSessionDiscoveryConfiguration: Equatable, Sendable {
    // A transcript with no matching live process is not called open. Once it
    // passes this age, it is safe to label it stale; before then it stays
    // unknown because the local files do not prove whether the session ended.
    let staleAfter: TimeInterval
    
    // A matching process plus a recently touched transcript is the strongest
    // local signal available without Claude's private runtime state.
    let activeLogWindow: TimeInterval
    let sessionLookback: TimeInterval
    let maxSessions: Int

    init(
        staleAfter: TimeInterval = 5 * 60,
        activeLogWindow: TimeInterval = 2 * 60,
        sessionLookback: TimeInterval = 3 * 24 * 60 * 60,
        maxSessions: Int = 200
    ) {
        self.staleAfter = max(0, staleAfter)
        self.activeLogWindow = max(0, activeLogWindow)
        self.sessionLookback = max(0, sessionLookback)
        self.maxSessions = max(1, maxSessions)
    }

    static let `default` = ClaudeSessionDiscoveryConfiguration()
}

enum ClaudeConfigDirectories {
    static func roots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var rawPaths: [String] = []

        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            rawPaths.append(configured)
        }

        if let configured = environment["CLAUDE_CONFIG_DIRS"], !configured.isEmpty {
            rawPaths.append(contentsOf: configured.split(separator: ":").map(String.init))
        }

        if rawPaths.isEmpty {
            rawPaths = [homeDirectory.appendingPathComponent(".claude", isDirectory: true).path]
        }

        var seen = Set<String>()
        return rawPaths.compactMap { rawPath in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded: String
            if trimmed == "~" {
                expanded = homeDirectory.path
            } else if trimmed.hasPrefix("~/") {
                expanded = homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2))).path
            } else {
                expanded = trimmed
            }
            let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            return url
        }
    }
}

enum ClaudeProjectPath {
    // Claude's project directory encoding replaces each slash with a dash and
    // therefore cannot reversibly represent a dash inside a path component.
    // Transcript cwd metadata is preferred; this decoder is a best-effort
    // fallback for old or partially written transcripts.
    static func decode(_ encodedDirectoryName: String) -> String? {
        let value = encodedDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
        guard value.hasPrefix("-") else { return nil }
        let body = String(value.dropFirst())
        guard !body.isEmpty else { return "/" }
        return "/" + body.replacingOccurrences(of: "-", with: "/")
    }
}

enum ClaudeSessionLogPath {
    static func sessionID(from path: String) -> String? {
        sessionID(from: URL(fileURLWithPath: path))
    }

    static func sessionID(from url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        if let subagentIndex = components.lastIndex(of: "subagents"), subagentIndex > 0 {
            return validSessionID(components[subagentIndex - 1])
        }

        let basename = url.deletingPathExtension().lastPathComponent
        return validSessionID(basename)
    }

    static func validSessionID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 200,
              !trimmed.contains("/"),
              !trimmed.contains("\\")
        else { return nil }
        return trimmed
    }
}

typealias ClaudeProcessEvidenceProvider = () -> [ClaudeProcessEvidence]
typealias ClaudeProcessHelperRunner = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> Data?

enum ClaudeProcessEvidenceSource {
    private static let psTimeout: TimeInterval = 0.5
    private static let lsofTimeout: TimeInterval = 0.25
    private static let probeTimeout: TimeInterval = 1.0
    private static let terminationGrace: TimeInterval = 0.1

    // Live-only seam. Tests inject ClaudeProcessEvidenceProvider and never run
    // these ps/lsof calls. The command-runner overload makes timeout/failure
    // behavior testable without spawning system helpers.
    static func live() -> [ClaudeProcessEvidence] {
        live(commandRunner: { executable, arguments, timeout in
            runHelper(executable: executable, arguments: arguments, timeout: timeout)
        })
    }

    static func live(commandRunner: ClaudeProcessHelperRunner) -> [ClaudeProcessEvidence] {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(probeTimeout * 1_000_000_000)
        let psTimeout = min(self.psTimeout, remainingTime(until: deadline))
        guard psTimeout > 0,
              let outputData = commandRunner(
                  "/bin/ps",
                  ["-axo", "pid=,tty=,state=,command="],
                  psTimeout
              ),
              let output = String(data: outputData, encoding: .utf8)
        else { return [] }

        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 3,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  looksLikeClaude(commandLine: String(fields[3]))
            else { return nil }

            let tty = fields[1] == "??" ? nil : String(fields[1])
            let commandLine = String(fields[3])
            let remainingTime = self.remainingTime(until: deadline)
            let workingDirectory: String?
            if remainingTime > 0 {
                workingDirectory = currentWorkingDirectory(
                    for: pid,
                    timeout: min(lsofTimeout, remainingTime),
                    commandRunner: commandRunner
                )
            } else {
                workingDirectory = nil
            }
            return ClaudeProcessEvidence(
                pid: pid,
                sessionID: sessionID(in: commandLine),
                commandLine: commandLine,
                workingDirectory: workingDirectory,
                tty: tty,
                activity: .unknown
            )
        }
    }

    private static func remainingTime(until deadline: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return 0 }
        return TimeInterval(deadline - now) / 1_000_000_000
    }

    private static func runHelper(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Data? {
        guard timeout > 0 else { return nil }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        guard termination.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning {
                process.terminate()
            }
            if termination.wait(timeout: .now() + terminationGrace) == .timedOut,
               process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    private static func looksLikeClaude(commandLine: String) -> Bool {
        commandLine.split(whereSeparator: \.isWhitespace).contains { token in
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let basename = URL(fileURLWithPath: String(cleaned)).lastPathComponent.lowercased()
            return basename == "claude" || basename == "claude-code" || basename == "claude.js"
        }
    }

    private static func sessionID(in commandLine: String) -> String? {
        let tokens = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, rawToken) in tokens.enumerated() {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if ["--resume", "-r", "--session-id"].contains(token), index + 1 < tokens.count {
                return ClaudeSessionLogPath.validSessionID(tokens[index + 1])
            }
            for prefix in ["--resume=", "--session-id="] where token.hasPrefix(prefix) {
                return ClaudeSessionLogPath.validSessionID(String(token.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func currentWorkingDirectory(
        for pid: Int32,
        timeout: TimeInterval,
        commandRunner: ClaudeProcessHelperRunner
    ) -> String? {
        guard let data = commandRunner(
            "/usr/sbin/lsof",
            ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
            timeout
        ),
        let output = String(data: data, encoding: .utf8)
        else { return nil }

        return output
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.first == "n" })
            .map { String($0.dropFirst()) }
    }
}

final class ClaudeSessionDiscovery: @unchecked Sendable {
    let configuration: ClaudeSessionDiscoveryConfiguration

    private let configRoots: [URL]
    private let now: () -> Date
    private let processEvidence: ClaudeProcessEvidenceProvider
    private let fileManager: FileManager

    init(
        configRoots: [URL]? = nil,
        configuration: ClaudeSessionDiscoveryConfiguration = .default,
        now: @escaping () -> Date = Date.init,
        processEvidence: @escaping ClaudeProcessEvidenceProvider = ClaudeProcessEvidenceSource.live,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.configRoots = configRoots ?? ClaudeConfigDirectories.roots()
        self.now = now
        self.processEvidence = processEvidence
        self.fileManager = fileManager
    }

    func discover() -> [SessionActivity] {
        let records = discoverTranscriptRecords()
        guard !records.isEmpty else { return [] }

        let processes = processEvidence()
        let currentDate = now()
        let workspaceCounts = Dictionary(
            records.compactMap { record in
                record.workspace.map { (normalizedPath($0), 1) }
            },
            uniquingKeysWith: +
        )

        return records
            .sorted { lhs, rhs in
                switch (lhs.lastSeen, rhs.lastSeen) {
                case let (left?, right?):
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.sessionID < rhs.sessionID
                }
            }
            .map { record in
                let match = processMatch(
                    for: record,
                    processes: processes,
                    workspaceCounts: workspaceCounts
                )
                return activity(for: record, processMatch: match, now: currentDate)
            }
            .filter { activity in
                guard let lastSeen = activity.lastSeen else { return true }
                let age = currentDate.timeIntervalSince(lastSeen)
                if age <= configuration.sessionLookback { return true }
                return activity.state == .activeWorking || activity.state == .openIdle
            }
    }

    private func discoverTranscriptRecords() -> [TranscriptRecord] {
        var mainRecords: [String: TranscriptRecord] = [:]
        var subagentPaths: [String: [String]] = [:]

        for configRoot in configRoots {
            let projectsRoot = configRoot.appendingPathComponent("projects", isDirectory: true)
            for logURL in transcriptFiles(in: projectsRoot) {
                let scan = ClaudeTranscriptReader.scan(url: logURL)
                let pathSessionID = ClaudeSessionLogPath.sessionID(from: logURL)
                guard let sessionID = scan.sessionID ?? pathSessionID else { continue }

                let isSubagent = logURL.pathComponents.contains("subagents") || scan.isSidechain
                if isSubagent {
                    subagentPaths[sessionID, default: []].append(logURL.path)
                    continue
                }

                let projectDirectory = projectDirectoryName(for: logURL, projectsRoot: projectsRoot)
                let workspace = scan.workspace ?? projectDirectory.flatMap(ClaudeProjectPath.decode)
                let modifiedAt = modificationDate(for: logURL)
                let lastSeen = [scan.latestTimestamp, modifiedAt].compactMap { $0 }.max()
                let confidence: SessionActivityConfidence = scan.hasUsefulMetadata ? .low : .unknown
                let record = TranscriptRecord(
                    sessionID: sessionID,
                    logPath: logURL.path,
                    workspace: workspace,
                    lastSeen: lastSeen,
                    confidence: confidence,
                    subagentLogPaths: []
                )

                if let existing = mainRecords[sessionID], isNewer(record, than: existing) == false {
                    continue
                }
                mainRecords[sessionID] = record
            }
        }

        return mainRecords.values.map { record in
            var result = record
            result.subagentLogPaths = Array(Set(subagentPaths[record.sessionID, default: []])).sorted()
            return result
        }
    }

    private func transcriptFiles(in projectsRoot: URL) -> [URL] {
        guard fileManager.fileExists(atPath: projectsRoot.path),
              let enumerator = fileManager.enumerator(
                  at: projectsRoot,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        let urls: [URL] = enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            return url
        }
        return urls.sorted {
            let left = modificationDate(for: $0) ?? .distantPast
            let right = modificationDate(for: $1) ?? .distantPast
            if left != right { return left > right }
            return $0.path < $1.path
        }.prefix(configuration.maxSessions).map { $0 }
    }

    private func projectDirectoryName(for logURL: URL, projectsRoot: URL) -> String? {
        let rootComponents = projectsRoot.standardizedFileURL.pathComponents
        let pathComponents = logURL.standardizedFileURL.pathComponents
        guard pathComponents.starts(with: rootComponents),
              pathComponents.count > rootComponents.count
        else { return nil }
        return pathComponents[rootComponents.count]
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func isNewer(_ candidate: TranscriptRecord, than existing: TranscriptRecord) -> Bool {
        switch (candidate.lastSeen, existing.lastSeen) {
        case let (candidateDate?, existingDate?):
            return candidateDate > existingDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return candidate.logPath > existing.logPath
        }
    }

    private func processMatch(
        for record: TranscriptRecord,
        processes: [ClaudeProcessEvidence],
        workspaceCounts: [String: Int]
    ) -> ProcessMatch? {
        let strongMatches = processes.filter { process in
            process.sessionID == record.sessionID ||
                commandLineMentions(record.sessionID, in: process.commandLine) ||
                process.commandLine.contains(record.logPath)
        }
        if let exactSessionMatch = strongMatches.first(where: { $0.sessionID == record.sessionID }) {
            return ProcessMatch(process: exactSessionMatch, confidence: .high)
        }
        if let strongMatch = strongMatches.first {
            return ProcessMatch(process: strongMatch, confidence: .high)
        }

        guard let workspace = record.workspace else { return nil }
        let normalizedWorkspace = normalizedPath(workspace)
        let workspaceMatches = processes.filter {
            guard let processWorkspace = $0.workingDirectory else { return false }
            return normalizedPath(processWorkspace) == normalizedWorkspace
        }
        guard workspaceCounts[normalizedWorkspace] == 1,
              workspaceMatches.count == 1,
              let workspaceMatch = workspaceMatches.first
        else { return nil }
        return ProcessMatch(process: workspaceMatch, confidence: .medium)
    }

    private func commandLineMentions(_ sessionID: String, in commandLine: String) -> Bool {
        commandLine
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            .contains { token in
                token == sessionID ||
                    token == "--resume=\(sessionID)" ||
                    token == "--session-id=\(sessionID)"
            }
    }

    private func activity(
        for record: TranscriptRecord,
        processMatch: ProcessMatch?,
        now: Date
    ) -> SessionActivity {
        let lastSeen = [record.lastSeen, processMatch?.process.lastActivity].compactMap { $0 }.max()
        let state: SessionActivityState
        if let processMatch {
            switch processMatch.process.activity {
            case .working:
                state = .activeWorking
            case .idle:
                state = .openIdle
            case .unknown:
                guard let lastSeen else {
                    state = .openIdle
                    break
                }
                let age = now.timeIntervalSince(lastSeen)
                state = age <= configuration.activeLogWindow ? .activeWorking : .openIdle
            }
        } else if let lastSeen {
            let age = now.timeIntervalSince(lastSeen)
            state = age >= configuration.staleAfter ? .stale : .unknown
        } else {
            state = .unknown
        }

        return SessionActivity(
            provider: .claude,
            sessionID: record.sessionID,
            logPath: record.logPath,
            workspace: record.workspace,
            pid: processMatch?.process.pid,
            tty: processMatch?.process.tty,
            lastSeen: lastSeen,
            state: state,
            confidence: processMatch?.confidence ?? record.confidence,
            subagentLogPaths: record.subagentLogPaths
        )
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private struct TranscriptRecord {
    let sessionID: String
    let logPath: String
    let workspace: String?
    let lastSeen: Date?
    let confidence: SessionActivityConfidence
    var subagentLogPaths: [String]
}

private struct ProcessMatch {
    let process: ClaudeProcessEvidence
    let confidence: SessionActivityConfidence
}

private struct TranscriptScan {
    var sessionID: String?
    var workspace: String?
    var latestTimestamp: Date?
    var isSidechain = false
    var hasUsefulMetadata = false
}

private enum ClaudeTranscriptReader {
    static func scan(url: URL) -> TranscriptScan {
        guard let data = boundedData(at: url) else {
            return TranscriptScan()
        }

        var result = TranscriptScan()
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = rawLine.last == 0x0D ? rawLine.dropLast() : rawLine[...]
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let json = object as? [String: Any]
            else { continue }

            if let sessionID = ClaudeSessionLogPath.validSessionID(
                (json["sessionId"] as? String) ?? (json["session_id"] as? String)
            ) {
                result.sessionID = result.sessionID ?? sessionID
                result.hasUsefulMetadata = true
            }
            if let cwd = nonEmptyString((json["cwd"] as? String) ?? (json["workingDirectory"] as? String)) {
                result.workspace = cwd
                result.hasUsefulMetadata = true
            }
            if let timestamp = timestamp(from: json["timestamp"] ?? json["createdAt"] ?? json["created_at"]) {
                result.latestTimestamp = max(result.latestTimestamp ?? timestamp, timestamp)
                result.hasUsefulMetadata = true
            }
            if (json["isSidechain"] as? Bool) == true || nonEmptyString(json["agentId"] as? String) != nil {
                result.isSidechain = true
                result.hasUsefulMetadata = true
            }
        }
        return result
    }

    private static func boundedData(at url: URL, maxBytes: Int = 128 * 1024) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNumber = attributes[.size] as? NSNumber
        else {
            return nil
        }

        let size = sizeNumber.intValue
        guard size > maxBytes else {
            return try? Data(contentsOf: url, options: [.mappedIfSafe])
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

        let half = maxBytes / 2
        let prefix = handle.readData(ofLength: half)
        try? handle.seek(toOffset: UInt64(size - half))
        let suffix = handle.readData(ofLength: half)
        return prefix + Data("\n".utf8) + suffix
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func timestamp(from value: Any?) -> Date? {
        if let value = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            return fractional.date(from: value) ?? standard.date(from: value)
        }
        if let value = value as? NSNumber {
            let seconds = value.doubleValue > 10_000_000_000 ? value.doubleValue / 1000 : value.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
