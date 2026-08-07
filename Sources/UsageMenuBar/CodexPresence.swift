import Foundation
import Darwin

// UI-free local presence core. The menu-bar layer consumes SessionActivity
// after this scanner runs off the main actor. No network calls.

enum CodexHomeResolver {
    static func resolve(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else {
            return normalizeURL(homeDirectory.appendingPathComponent(".codex", isDirectory: true))
        }
        return normalizePath(configured, relativeTo: homeDirectory)
    }

    static func normalizePath(_ path: String, relativeTo base: URL? = nil) -> URL {
        let expanded: String
        if path == "~" {
            expanded = base?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            let home = base?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
            expanded = home + String(path.dropFirst())
        } else {
            expanded = path
        }

        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded, isDirectory: true)
        } else if let base {
            url = base.appendingPathComponent(expanded, isDirectory: true)
        } else {
            url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
        return normalizeURL(url)
    }

    static func normalizeURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return normalizePath(path).path
    }
}

struct CodexPresenceConfiguration {
    let codexHome: URL
    let staleAfter: TimeInterval
    let workingAfter: TimeInterval
    let registryFreshAfter: TimeInterval
    let sessionLookback: TimeInterval
    let maxSessions: Int

    init(
        codexHome: URL,
        staleAfter: TimeInterval = 15 * 60,
        workingAfter: TimeInterval = 90,
        registryFreshAfter: TimeInterval = 2 * 60,
        sessionLookback: TimeInterval = 3 * 24 * 60 * 60,
        maxSessions: Int = 200
    ) {
        self.codexHome = CodexHomeResolver.normalizeURL(codexHome)
        self.staleAfter = max(0, staleAfter)
        self.workingAfter = max(0, workingAfter)
        self.registryFreshAfter = max(0, registryFreshAfter)
        self.sessionLookback = max(0, sessionLookback)
        self.maxSessions = max(1, maxSessions)
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        Self(codexHome: CodexHomeResolver.resolve(environment: environment, homeDirectory: homeDirectory))
    }

    var sessionsDirectory: URL {
        codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    var activeRegistryURL: URL {
        codexHome
            .appendingPathComponent("process_manager", isDirectory: true)
            .appendingPathComponent("chat_processes.json")
    }
}

struct CodexPresenceFileSystem {
    let listFiles: (_ root: URL) -> [URL]
    let readData: (_ url: URL) -> Data?
    let modificationDate: (_ url: URL) -> Date?

    init(
        listFiles: @escaping (_ root: URL) -> [URL],
        readData: @escaping (_ url: URL) -> Data?,
        modificationDate: @escaping (_ url: URL) -> Date?
    ) {
        self.listFiles = listFiles
        self.readData = readData
        self.modificationDate = modificationDate
    }

    static let live = Self(
        listFiles: { root in
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            return enumerator.compactMap { item in
                guard let url = item as? URL,
                      url.pathExtension.lowercased() == "jsonl",
                      url.lastPathComponent.hasPrefix("rollout-")
                else {
                    return nil
                }
                return url
            }
        },
        readData: { url in
            if url.pathExtension.lowercased() == "jsonl" {
                return boundedData(at: url)
            }
            return FileManager.default.contents(atPath: url.path)
        },
        modificationDate: { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    )

    private static func boundedData(at url: URL, maxBytes: Int = 128 * 1024) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNumber = attributes[.size] as? NSNumber
        else {
            return nil
        }

        let size = sizeNumber.intValue
        guard size > maxBytes else {
            return FileManager.default.contents(atPath: url.path)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

        let half = maxBytes / 2
        let prefix = handle.readData(ofLength: half)
        try? handle.seek(toOffset: UInt64(size - half))
        let suffix = handle.readData(ofLength: half)
        return prefix + Data("\n".utf8) + suffix
    }
}

struct CodexProcessEvidence: Equatable {
    let pid: Int32
    let workingDirectory: String?
    let tty: String?
    let command: String

    init(
        pid: Int32,
        workingDirectory: String? = nil,
        tty: String? = nil,
        command: String = "codex"
    ) {
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.tty = tty
        self.command = command
    }
}

struct CodexProcessProbe {
    let listProcesses: () -> [CodexProcessEvidence]

    init(listProcesses: @escaping () -> [CodexProcessEvidence]) {
        self.listProcesses = listProcesses
    }

    static let live = Self(listProcesses: LiveCodexProcessProbe.list)
}

struct CodexPresenceScanner {
    private let configuration: CodexPresenceConfiguration
    private let fileSystem: CodexPresenceFileSystem
    private let processProbe: CodexProcessProbe
    private let now: () -> Date

    init(
        configuration: CodexPresenceConfiguration = .live(),
        fileSystem: CodexPresenceFileSystem = .live,
        processProbe: CodexProcessProbe = .live,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.processProbe = processProbe
        self.now = now
    }

    func discover() -> [SessionActivity] {
        let currentDate = now()
        let registry = loadRegistry()
        let processes = processProbe.listProcesses()
        var activities: [String: SessionActivity] = [:]

        let rolloutURLs = fileSystem
            .listFiles(configuration.sessionsDirectory)
            .sorted {
                let left = fileSystem.modificationDate($0) ?? .distantPast
                let right = fileSystem.modificationDate($1) ?? .distantPast
                if left != right { return left > right }
                return $0.path < $1.path
            }
            .prefix(configuration.maxSessions)

        for url in rolloutURLs {
            guard let rollout = loadRollout(at: url) else { continue }
            let registryEntry = matchingRegistry(for: rollout, in: registry)
            let process = matchingProcess(for: rollout, registry: registryEntry, in: processes)
            let activity = makeActivity(
                rollout: rollout,
                registry: registryEntry,
                process: process,
                now: currentDate
            )
            merge(activity, into: &activities)
        }

        let knownIDs = Set(activities.keys)
        for entry in registry {
            guard let id = entry.id,
                  !knownIDs.contains(canonicalID(id)),
                  let lastSeen = entry.lastSeen
            else {
                continue
            }

            let process = matchingProcess(for: nil, registry: entry, in: processes)
            guard age(of: lastSeen, at: currentDate) <= configuration.staleAfter || process != nil else {
                continue
            }
            let activity = makeActivity(
                rollout: nil,
                registry: entry,
                process: process,
                now: currentDate
            )
            merge(activity, into: &activities)
        }

        return activities.values
            .filter { shouldKeep($0, at: currentDate) }
            .sorted { $0.id < $1.id }
    }

    private struct RolloutRecord {
        let id: String
        let logPath: String
        let workspace: String?
        let lastSeen: Date?
        let metadataIsValid: Bool
    }

    private struct ActiveRegistryEntry {
        let id: String?
        let workspace: String?
        let pid: Int32?
        let tty: String?
        let lastSeen: Date?
    }

    private func loadRollout(at url: URL) -> RolloutRecord? {
        guard let data = fileSystem.readData(url) else { return nil }

        var metadataID: String?
        var metadataWorkspace: String?
        var foundSessionMetadata = false
        var newestEventDate: Date?

        for line in data.split(separator: 10, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dictionary = object as? [String: Any]
            else {
                continue
            }

            if let timestamp = dictionary["timestamp"] as? String,
               let eventDate = parseDate(timestamp) {
                newestEventDate = later(newestEventDate, eventDate)
            }

            guard dictionary["type"] as? String == "session_meta",
                  let payload = dictionary["payload"] as? [String: Any]
            else {
                continue
            }

            foundSessionMetadata = true
            if let id = payload["id"] as? String,
               !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadataID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let cwd = payload["cwd"] as? String {
                metadataWorkspace = CodexHomeResolver.normalizedPath(cwd)
            }
        }

        let id = metadataID ?? filenameID(for: url)
        guard let id else { return nil }

        let fileDate = fileSystem.modificationDate(url)
        return RolloutRecord(
            id: id,
            logPath: CodexHomeResolver.normalizeURL(url).path,
            workspace: metadataWorkspace,
            lastSeen: later(fileDate, newestEventDate),
            metadataIsValid: foundSessionMetadata && metadataID != nil && metadataWorkspace != nil
        )
    }

    private func loadRegistry() -> [ActiveRegistryEntry] {
        guard let data = fileSystem.readData(configuration.activeRegistryURL),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }

        let records: [[String: Any]]
        if let array = object as? [[String: Any]] {
            records = array
        } else if let dictionary = object as? [String: Any] {
            let wrapperKeys = ["processes", "sessions", "entries", "items", "chats"]
            records = wrapperKeys
                .compactMap { dictionary[$0] as? [[String: Any]] }
                .flatMap { $0 }
        } else {
            records = []
        }

        let registryDate = fileSystem.modificationDate(configuration.activeRegistryURL)
        return records.compactMap { record in
            let id = firstString(in: record, keys: ["conversationId", "conversation_id", "sessionId", "session_id"])
                ?? fallbackRegistryID(in: record)
            let workspace = firstString(in: record, keys: ["cwd", "workspace", "workingDirectory"])
                .flatMap(CodexHomeResolver.normalizedPath)
            let pid = firstInt32(in: record, keys: ["osPid", "pid", "processId"])
            let tty = firstString(in: record, keys: ["tty", "terminal"])
            let lastSeen = firstDate(in: record, keys: ["updatedAtMs", "updated_at_ms", "updatedAt", "updated_at"])
                ?? registryDate

            guard id != nil || workspace != nil || pid != nil else { return nil }
            return ActiveRegistryEntry(
                id: id,
                workspace: workspace,
                pid: pid,
                tty: tty,
                lastSeen: lastSeen
            )
        }
    }

    private func matchingRegistry(
        for rollout: RolloutRecord,
        in entries: [ActiveRegistryEntry]
    ) -> ActiveRegistryEntry? {
        if let exact = entries.first(where: {
            guard let entryID = $0.id else { return false }
            return canonicalID(entryID) == canonicalID(rollout.id)
        }) {
            return exact
        }

        guard let workspace = rollout.workspace else { return nil }
        let workspaceMatches = entries.filter { $0.workspace == workspace }
        return workspaceMatches.count == 1 ? workspaceMatches[0] : nil
    }

    private func matchingProcess(
        for rollout: RolloutRecord?,
        registry: ActiveRegistryEntry?,
        in processes: [CodexProcessEvidence]
    ) -> CodexProcessEvidence? {
        if let pid = registry?.pid,
           let byPID = processes.first(where: { $0.pid == pid }) {
            return byPID
        }

        let workspace = rollout?.workspace ?? registry?.workspace
        guard let workspace else { return nil }
        return processes.first { process in
            guard let processWorkspace = CodexHomeResolver.normalizedPath(process.workingDirectory) else {
                return false
            }
            return processWorkspace == workspace
        }
    }

    private func makeActivity(
        rollout: RolloutRecord?,
        registry: ActiveRegistryEntry?,
        process: CodexProcessEvidence?,
        now: Date
    ) -> SessionActivity {
        let id = rollout?.id ?? registry?.id ?? "unknown"
        let lastSeen = later(rollout?.lastSeen, registry?.lastSeen)
        let registryIsFresh = isWithin(registry?.lastSeen, ttl: configuration.registryFreshAfter, now: now)
        let rolloutIsRecent = isWithin(rollout?.lastSeen, ttl: configuration.workingAfter, now: now)
        let hasReliableMetadata = rollout?.metadataIsValid ?? false

        let state: SessionActivityState
        if process != nil || registryIsFresh {
            state = rolloutIsRecent ? .activeWorking : .openIdle
        } else if !hasReliableMetadata {
            state = .unknown
        } else if let lastSeen, age(of: lastSeen, at: now) >= configuration.staleAfter {
            state = .stale
        } else {
            // A recent rollout file alone cannot prove that Codex is still open.
            state = .unknown
        }

        let confidence: SessionActivityConfidence
        switch state {
        case .activeWorking:
            confidence = process == nil ? .medium : .high
        case .openIdle:
            confidence = process == nil ? .medium : .high
        case .stale:
            confidence = .high
        case .unknown:
            confidence = .low
        }

        return SessionActivity(
            provider: .codex,
            sessionID: id,
            logPath: rollout?.logPath,
            workspace: rollout?.workspace ?? registry?.workspace,
            pid: process?.pid ?? registry?.pid,
            tty: process?.tty ?? registry?.tty,
            lastSeen: lastSeen,
            state: state,
            confidence: confidence
        )
    }

    private func merge(_ activity: SessionActivity, into activities: inout [String: SessionActivity]) {
        let key = canonicalID(activity.id)
        guard let existing = activities[key] else {
            activities[key] = activity
            return
        }

        if stateRank(activity.state) > stateRank(existing.state) ||
            (stateRank(activity.state) == stateRank(existing.state) &&
                (activity.lastSeen ?? .distantPast) > (existing.lastSeen ?? .distantPast)) {
            activities[key] = activity
        }
    }

    private func stateRank(_ state: SessionActivityState) -> Int {
        switch state {
        case .activeWorking: return 4
        case .openIdle: return 3
        case .unknown: return 2
        case .stale: return 1
        }
    }

    private func canonicalID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func canonicalID(_ id: String?) -> String? {
        id.map(canonicalID)
    }

    private func age(of date: Date, at now: Date) -> TimeInterval {
        now.timeIntervalSince(date)
    }

    private func isWithin(_ date: Date?, ttl: TimeInterval, now: Date) -> Bool {
        guard let date else { return false }
        let elapsed = age(of: date, at: now)
        return elapsed >= 0 && elapsed <= ttl
    }

    private func shouldKeep(_ activity: SessionActivity, at now: Date) -> Bool {
        guard let lastSeen = activity.lastSeen else { return true }
        let age = age(of: lastSeen, at: now)
        if age <= configuration.sessionLookback { return true }
        return activity.state == .activeWorking || activity.state == .openIdle
    }

    private func filenameID(for url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = "rollout-"
        guard stem.hasPrefix(prefix) else { return nil }
        let candidate = String(stem.dropFirst(prefix.count).suffix(36))
        guard UUID(uuidString: candidate) != nil else { return nil }
        return candidate.lowercased()
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }

    private func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (date?, nil), let (nil, date?): return date
        case (nil, nil): return nil
        }
    }

    private func firstString(in record: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = record[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func fallbackRegistryID(in record: [String: Any]) -> String? {
        guard let id = record["id"] as? String,
              !id.contains(":"),
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstInt32(in record: [String: Any], keys: [String]) -> Int32? {
        for key in keys {
            if let number = record[key] as? NSNumber {
                return Int32(exactly: number.intValue)
            }
            if let string = record[key] as? String,
               let value = Int32(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }

    private func firstDate(in record: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let number = record[key] as? NSNumber {
                let raw = number.doubleValue
                let seconds = raw > 100_000_000_000 ? raw / 1_000 : raw
                return Date(timeIntervalSince1970: seconds)
            }
            if let string = record[key] as? String {
                if let milliseconds = Double(string) {
                    let seconds = milliseconds > 100_000_000_000 ? milliseconds / 1_000 : milliseconds
                    return Date(timeIntervalSince1970: seconds)
                }
                if let date = parseDate(string) {
                    return date
                }
            }
        }
        return nil
    }
}

private enum LiveCodexProcessProbe {
    private static let commandTimeout: TimeInterval = 0.75
    private static let terminationGrace: TimeInterval = 0.05
    private static let outputReadTimeout: TimeInterval = 0.25

    static func list() -> [CodexProcessEvidence] {
        guard let output = run(executable: "/bin/ps", arguments: ["-axo", "pid=,tty=,command="]) else {
            return []
        }

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count == 3,
                      let pid = Int32(fields[0]),
                      isCodexCommand(String(fields[2]))
                else {
                    return nil
                }

                let tty = fields[1] == "??" ? nil : String(fields[1])
                return CodexProcessEvidence(
                    pid: pid,
                    workingDirectory: currentDirectory(for: pid),
                    tty: tty,
                    command: String(fields[2])
                )
            }
    }

    private static func isCodexCommand(_ command: String) -> Bool {
        guard let executable = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return false
        }
        let path = executable.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name == "codex" || name.hasPrefix("codex-")
    }

    private static func currentDirectory(for pid: Int32) -> String? {
        guard let output = run(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        ) else {
            return nil
        }

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { $0.first == "n" }
            .map { String($0.dropFirst()) }
    }

    private static func run(executable: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        let outputReader = ProcessOutputReader(pipe: pipe)
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { _ in
            pipe.fileHandleForWriting.closeFile()
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            return nil
        }

        guard termination.wait(timeout: .now() + .milliseconds(Int(commandTimeout * 1_000))) == .success else {
            process.terminate()
            if termination.wait(timeout: .now() + .milliseconds(Int(terminationGrace * 1_000))) == .timedOut {
                let pid = process.processIdentifier
                if pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
                _ = termination.wait(timeout: .now() + .milliseconds(Int(terminationGrace * 1_000)))
            }
            return nil
        }

        guard let data = outputReader.read(timeout: outputReadTimeout) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private final class ProcessOutputReader: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    init(pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let captured = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            data = captured
            lock.unlock()
            done.signal()
        }
    }

    func read(timeout: TimeInterval) -> Data? {
        guard done.wait(timeout: .now() + .milliseconds(Int(timeout * 1_000))) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

extension CodexPresenceScanner: @unchecked Sendable {}
