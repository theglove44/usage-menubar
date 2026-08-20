import Foundation

struct SessionRunwayBurnMeasurement: Sendable {
    let burn: SessionRunwayBurn
    let deltaTokens: Int64
}

struct SessionRunwayBurnAccumulator: Sendable {
    private var previousCumulativeTotal: Int64?
    private var seenRecordIDs: Set<String> = []
    private var recordOrder: [String] = []
    private var lastObservationAt: Date?

    mutating func update(
        usage: SessionRunwayUsageData,
        now: Date,
        rules: SessionRunwayRules
    ) -> SessionRunwayBurnMeasurement {
        guard usage.supported else {
            return SessionRunwayBurnMeasurement(burn: .unsupported, deltaTokens: 0)
        }

        if let cumulative = usage.cumulativeTokenTotal {
            guard let previous = previousCumulativeTotal else {
                previousCumulativeTotal = cumulative
                lastObservationAt = now
                return SessionRunwayBurnMeasurement(burn: .measuring, deltaTokens: 0)
            }

            guard cumulative >= previous else {
                previousCumulativeTotal = cumulative
                lastObservationAt = now
                return SessionRunwayBurnMeasurement(burn: .measuring, deltaTokens: 0)
            }

            let delta = cumulative - previous
            previousCumulativeTotal = cumulative
            let interval = max(0, now.timeIntervalSince(lastObservationAt ?? now))
            lastObservationAt = now
            guard delta > 0, interval > 0 else {
                return SessionRunwayBurnMeasurement(
                    burn: .noRecentBurn(observationWindow: interval),
                    deltaTokens: 0
                )
            }
            return SessionRunwayBurnMeasurement(
                burn: .observed(deltaTokens: delta, interval: interval),
                deltaTokens: delta
            )
        }

        let unseenRecords = usage.incrementalRecords.filter { !seenRecordIDs.contains($0.id) }
        for record in unseenRecords {
            seenRecordIDs.insert(record.id)
            recordOrder.append(record.id)
        }
        if recordOrder.count > rules.usageRecordCacheLimit {
            let overflow = recordOrder.count - rules.usageRecordCacheLimit
            let removed = recordOrder.prefix(overflow)
            for id in removed { seenRecordIDs.remove(id) }
            recordOrder.removeFirst(overflow)
        }

        guard lastObservationAt != nil else {
            lastObservationAt = now
            return SessionRunwayBurnMeasurement(burn: .measuring, deltaTokens: 0)
        }

        let delta = unseenRecords.reduce(Int64(0)) { $0 + max(0, $1.tokens) }
        let interval = max(0, now.timeIntervalSince(lastObservationAt ?? now))
        lastObservationAt = now
        guard delta > 0, interval > 0 else {
            return SessionRunwayBurnMeasurement(
                burn: .noRecentBurn(observationWindow: interval),
                deltaTokens: 0
            )
        }
        return SessionRunwayBurnMeasurement(
            burn: .observed(deltaTokens: delta, interval: interval),
            deltaTokens: delta
        )
    }
}

enum SessionRunwayBurnMath {
    static func tokensPerHour(deltaTokens: Int64, interval: TimeInterval) -> Double? {
        guard deltaTokens >= 0, interval > 0 else { return nil }
        return Double(deltaTokens) * 3600 / interval
    }

    static func providerShare(deltaTokens: Int64, providerDelta: Int64) -> Double? {
        guard deltaTokens >= 0, providerDelta > 0 else { return nil }
        return min(1, max(0, Double(deltaTokens) / Double(providerDelta)))
    }
}

private struct SessionRunwayPresentedCandidate {
    let candidate: SessionRunwayParsedCandidate
    let state: SessionRunwayState
    let confidence: SessionRunwayConfidence
    let evidence: [SessionRunwayEvidence]
    let measurement: SessionRunwayBurnMeasurement
}

private struct SessionRunwayGroup {
    let key: String
    let members: [SessionRunwayPresentedCandidate]

    var primary: SessionRunwayPresentedCandidate {
        members.sorted {
            if $0.candidate.isSubagent != $1.candidate.isSubagent {
                return !$0.candidate.isSubagent
            }
            if $0.candidate.title.count != $1.candidate.title.count {
                return $0.candidate.title.count < $1.candidate.title.count
            }
            return $0.candidate.sourcePath < $1.candidate.sourcePath
        }.first!
    }
}

actor SessionRunwayScanner {
    private let configuration: SessionRunwayConfiguration
    private let fileSystem: SessionRunwayFileSystem
    private let processProbe: SessionRunwayProcessProbe
    private let titleStore: SessionRunwayCodexTitleStore
    private let rules: SessionRunwayRules
    private let clock: @Sendable () -> Date

    private var previousStats: [String: SessionRunwayFileStat] = [:]
    private var parsedCandidates: [String: SessionRunwayParsedCandidate] = [:]
    private var burnAccumulators: [String: SessionRunwayBurnAccumulator] = [:]
    private var codexTitleLookup: SessionRunwayCodexTitleLookup = .none
    private var codexStateDatabaseStat: SessionRunwayFileStat?
    private var hasCheckedCodexStateDatabase = false

    init(
        configuration: SessionRunwayConfiguration = .live,
        fileSystem: SessionRunwayFileSystem = .live,
        processProbe: SessionRunwayProcessProbe = .live,
        titleStore: SessionRunwayCodexTitleStore = .live,
        rules: SessionRunwayRules = .live,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.processProbe = processProbe
        self.titleStore = titleStore
        self.rules = rules
        self.clock = clock
    }

    func scan() -> SessionRunwaySnapshot {
        let now = clock()
        let titleLookupChanged = refreshCodexTitles()

        var filesByProvider: [SessionRunwayProvider: [URL]] = [:]
        var duplicateFileCount = 0
        var discoveredFileCount = 0
        var discoveryWasCapped = false
        for provider in SessionRunwayProvider.allCases {
            let discovered = fileSystem.discover(provider, configuration, rules, now)
            var seen = Set<String>()
            let unique = discovered.filter { url in
                let key = url.standardizedFileURL.path
                let inserted = seen.insert(key).inserted
                if !inserted { duplicateFileCount += 1 }
                return inserted
            }
            discoveredFileCount += unique.count
            discoveryWasCapped = discoveryWasCapped || unique.count >= rules.maxFilesPerProvider
            filesByProvider[provider] = unique
        }

        let allURLs = filesByProvider.values.flatMap { $0 }
        let processSnapshot = processProbe.snapshot(allURLs, rules.processProbeTimeout)
        let openPaths = Set(processSnapshot.openTranscriptPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        var currentStats: [String: SessionRunwayFileStat] = [:]
        var candidates: [SessionRunwayPresentedCandidate] = []
        var hiddenHistoricalCount = 0
        var parseFailureCount = 0
        var futureTimestampCount = 0
        var health: [SessionRunwayProvider: SessionRunwaySourceHealth] = [:]

        for provider in SessionRunwayProvider.allCases {
            let urls = filesByProvider[provider] ?? []
            guard !urls.isEmpty else {
                health[provider] = .missing
                continue
            }

            var providerParseFailures = 0
            for url in urls {
                let path = url.standardizedFileURL.path
                guard let stat = fileSystem.stat(url) else {
                    providerParseFailures += 1
                    continue
                }
                currentStats[path] = stat
                let previousStat = previousStats[path]
                let pathProcessConfirmed = openPaths.contains(path)
                let modifiedAge = validAge(for: stat.modifiedAt, now: now)
                let outsideVisibleWindow = modifiedAge.map { $0 > rules.visibleLookback } ?? false

                let needsParse = parsedCandidates[path] == nil
                    || previousStat != stat
                    || (provider == .codex && titleLookupChanged)
                var candidate = parsedCandidates[path]
                if needsParse {
                    let prefix = fileSystem.readPrefix(url, rules.parseByteBudget)
                    let tail = fileSystem.readTail(url, rules.parseByteBudget)
                    candidate = SessionRunwayParser.parse(
                        provider: provider,
                        url: url,
                        prefix: prefix,
                        tail: tail,
                        fileModifiedAt: stat.modifiedAt,
                        now: now,
                        rules: rules,
                        codexTitles: codexTitleLookup
                    )
                    if let candidate {
                        parsedCandidates[path] = candidate
                    } else {
                        providerParseFailures += 1
                    }
                }

                // Registry evidence is session-specific, so parse the bounded
                // prefix/tail before deciding whether an old file is live.
                let registryConfirmed = candidate.map {
                    processSnapshot.liveSessionIDs.contains($0.sessionID)
                } ?? false
                if outsideVisibleWindow && !pathProcessConfirmed && !registryConfirmed {
                    hiddenHistoricalCount += 1
                    parsedCandidates.removeValue(forKey: path)
                    continue
                }

                guard let candidate else { continue }
                if candidate.futureTimestampRejected { futureTimestampCount += 1 }
                let usageKey = "\(provider.rawValue):\(path)"
                var accumulator = burnAccumulators[usageKey] ?? SessionRunwayBurnAccumulator()
                let measurement = accumulator.update(usage: candidate.usage, now: now, rules: rules)
                burnAccumulators[usageKey] = accumulator
                let presentation = classify(
                    candidate: candidate,
                    currentStat: stat,
                    previousStat: previousStat,
                    processSnapshot: processSnapshot,
                    openPaths: openPaths,
                    measurement: measurement,
                    now: now
                )
                candidates.append(presentation)
            }
            health[provider] = providerParseFailures > 0 ? .degraded : .ready
            parseFailureCount += providerParseFailures
        }

        let grouped = group(candidates)
        let providerDeltas = grouped.reduce(into: [SessionRunwayProvider: Int64]()) { partial, group in
            partial[group.primary.candidate.provider, default: 0] += group.members.reduce(Int64(0)) { $0 + $1.measurement.deltaTokens }
        }
        let rows = grouped.map { group in
            makeRow(group: group, providerDelta: providerDeltas[group.primary.candidate.provider] ?? 0)
        }.sorted(by: rowSort)

        let visibleRows = Array(rows.prefix(rules.maxVisibleRows))
        let hiddenRecentCount = max(0, rows.count - visibleRows.count)
        let groupedSubagentCount = grouped.reduce(0) { total, group in
            total + group.members.filter { $0.candidate.isSubagent }.count
        }

        previousStats = currentStats
        let currentPaths = Set(currentStats.keys)
        parsedCandidates = parsedCandidates.filter { currentPaths.contains($0.key) }
        burnAccumulators = burnAccumulators.filter { key, _ in
            guard let separator = key.firstIndex(of: ":") else { return false }
            return currentPaths.contains(String(key[key.index(after: separator)...]))
        }

        let diagnostics = SessionRunwayDiagnostics(
            discoveredFileCount: discoveredFileCount,
            visibleCandidateCount: candidates.count,
            hiddenHistoricalCount: hiddenHistoricalCount,
            hiddenHistoricalCountIsLowerBound: discoveryWasCapped,
            hiddenRecentCount: hiddenRecentCount,
            duplicateFileCount: duplicateFileCount,
            groupedSubagentCount: groupedSubagentCount,
            parseFailureCount: parseFailureCount,
            futureTimestampCount: futureTimestampCount,
            processProbeAvailable: processSnapshot.available
        )
        return SessionRunwaySnapshot(
            rows: visibleRows,
            hiddenHistoricalCount: hiddenHistoricalCount,
            health: health,
            diagnostics: diagnostics,
            scannedAt: now
        )
    }

    private func refreshCodexTitles() -> Bool {
        guard let database = configuration.codexStateDatabase else {
            let changed = hasCheckedCodexStateDatabase
            hasCheckedCodexStateDatabase = true
            codexTitleLookup = .none
            return changed
        }
        let stat = fileSystem.stat(database)
        let changed = !hasCheckedCodexStateDatabase || stat != codexStateDatabaseStat
        guard changed else { return false }
        hasCheckedCodexStateDatabase = true
        codexStateDatabaseStat = stat
        codexTitleLookup = stat == nil ? .none : titleStore.load(database, rules.processProbeTimeout)
        return true
    }

    private func classify(
        candidate: SessionRunwayParsedCandidate,
        currentStat: SessionRunwayFileStat,
        previousStat: SessionRunwayFileStat?,
        processSnapshot: SessionRunwayProcessSnapshot,
        openPaths: Set<String>,
        measurement: SessionRunwayBurnMeasurement,
        now: Date
    ) -> SessionRunwayPresentedCandidate {
        let path = candidate.sourcePath
        let fileChanged = previousStat != nil && previousStat != currentStat
        let transcriptOpen = openPaths.contains(path)
        let registryConfirmed = processSnapshot.liveSessionIDs.contains(candidate.sessionID)
        let providerProcessPresent = processSnapshot.liveProviders.contains(candidate.provider)
        let validFileDate = validDate(currentStat.modifiedAt, now: now)
        let validEventDate = candidate.lastActivityAt.flatMap { validDate($0, now: now) }
        let latest = [validFileDate, validEventDate].compactMap { $0 }.max()
        let age = latest.map { max(0, now.timeIntervalSince($0)) }

        var evidence: [SessionRunwayEvidence] = []
        if fileChanged { evidence.append(.fileChanged) }
        if transcriptOpen || registryConfirmed { evidence.append(.transcriptOpenByProcess) }
        if providerProcessPresent { evidence.append(.providerProcessPresent) }
        if candidate.lastActivityAt != nil && validEventDate != nil {
            evidence.append(.recentEvent)
        }
        if candidate.futureTimestampRejected { evidence.append(.futureTimestampRejected) }
        if candidate.parseDegraded { evidence.append(.parseDegraded) }

        let state: SessionRunwayState
        let confidence: SessionRunwayConfidence
        // A changed transcript is local activity evidence, not proof that its
        // process is still working. Only session-specific process evidence can
        // produce activeWorking; recent file/event evidence remains openIdle.
        if transcriptOpen || registryConfirmed {
            state = .activeWorking
            confidence = .high
        } else if latest == nil {
            state = .unknown
            confidence = .low
        } else if age ?? .infinity <= rules.idleAfter {
            state = .openIdle
            confidence = providerProcessPresent ? .medium : .low
            evidence.append(.quietFile)
        } else {
            state = .stale
            confidence = .medium
            evidence.append(.agedFile)
        }

        return SessionRunwayPresentedCandidate(
            candidate: candidate,
            state: state,
            confidence: confidence,
            evidence: evidence,
            measurement: measurement
        )
    }

    private func group(_ candidates: [SessionRunwayPresentedCandidate]) -> [SessionRunwayGroup] {
        let grouped = Dictionary(grouping: candidates) {
            "\($0.candidate.provider.rawValue):\($0.candidate.groupID)"
        }
        return grouped.map { SessionRunwayGroup(key: $0.key, members: $0.value) }
    }

    private func makeRow(group: SessionRunwayGroup, providerDelta: Int64) -> SessionRunwayRow {
        let primary = group.primary
        let state = group.members.sorted { stateRank($0.state) < stateRank($1.state) }.first?.state ?? .unknown
        let confidence = group.members.sorted { confidenceRank($0.confidence) < confidenceRank($1.confidence) }.first?.confidence ?? .low
        let evidence = Array(Set(group.members.flatMap(\.evidence))).sorted { $0.rawValue < $1.rawValue }
        let lastActivityAt = group.members.compactMap { $0.candidate.lastActivityAt }.max()
        let fileModifiedAt = group.members.map { $0.candidate.fileModifiedAt }.max()
        let delta = group.members.reduce(Int64(0)) { $0 + $1.measurement.deltaTokens }
        let rates = group.members.compactMap { $0.measurement.burn.observedTokensPerHour }
        let observationWindow = group.members.compactMap { $0.measurement.burn.observationWindow }.max()
        let burnState: SessionRunwayBurnState
        if group.members.contains(where: { $0.measurement.burn.state == .observed }) {
            burnState = .observed
        } else if group.members.contains(where: { $0.measurement.burn.state == .measuring }) {
            burnState = .measuring
        } else if group.members.allSatisfy({ $0.measurement.burn.state == .unsupported }) {
            burnState = .unsupported
        } else {
            burnState = .noRecentBurn
        }
        let burnConfidence = group.members
            .map { $0.measurement.burn.confidence }
            .sorted { confidenceRank($0) < confidenceRank($1) }
            .first ?? .low
        let burn = SessionRunwayBurn(
            state: burnState,
            confidence: burnConfidence,
            observedTokensPerHour: rates.isEmpty ? nil : rates.reduce(0, +),
            shareOfObservedProviderBurn: SessionRunwayBurnMath.providerShare(deltaTokens: delta, providerDelta: providerDelta),
            observedTokenDelta: delta > 0 ? delta : nil,
            observationWindow: observationWindow
        )
        return SessionRunwayRow(
            id: group.key,
            provider: primary.candidate.provider,
            sessionID: primary.candidate.sessionID,
            title: primary.candidate.title,
            projectName: primary.candidate.projectName,
            branch: primary.candidate.branch,
            state: state,
            confidence: confidence,
            evidence: evidence,
            lastActivityAt: lastActivityAt ?? fileModifiedAt,
            fileModifiedAt: fileModifiedAt,
            burn: burn,
            childSessionCount: group.members.filter { $0.candidate.isSubagent }.count
        )
    }

    private func rowSort(_ lhs: SessionRunwayRow, _ rhs: SessionRunwayRow) -> Bool {
        if stateRank(lhs.state) != stateRank(rhs.state) {
            return stateRank(lhs.state) < stateRank(rhs.state)
        }
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
        return lhs.id < rhs.id
    }

    private func stateRank(_ state: SessionRunwayState) -> Int {
        switch state {
        case .activeWorking: return 0
        case .openIdle: return 1
        case .stale: return 2
        case .unknown: return 3
        }
    }

    private func confidenceRank(_ confidence: SessionRunwayConfidence) -> Int {
        switch confidence {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    private func validAge(for date: Date, now: Date) -> TimeInterval? {
        validDate(date, now: now).map { max(0, now.timeIntervalSince($0)) }
    }

    private func validDate(_ date: Date, now: Date) -> Date? {
        guard date.timeIntervalSince(now) <= rules.clockSkewTolerance else { return nil }
        return date
    }
}

enum SessionRunwayLiveFileSystem {
    static func discover(
        provider: SessionRunwayProvider,
        configuration: SessionRunwayConfiguration,
        rules: SessionRunwayRules,
        now: Date
    ) -> [URL] {
        let fm = FileManager.default
        let roots: [URL]
        switch provider {
        case .codex:
            let codexRoot = configuration.codexSessionsRoot
            roots = [codexRoot, codexRoot.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)]
        case .claudeCode:
            roots = configuration.claudeConfigRoots.map { root in
                let projects = root.appendingPathComponent("projects", isDirectory: true)
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: projects.path, isDirectory: &isDirectory) && isDirectory.boolValue ? projects : root
            }
        }

        var files: [URL] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard isCandidate(url, provider: provider) else { continue }
                let key = url.standardizedFileURL.path
                guard seen.insert(key).inserted else { continue }
                files.append(url)
            }
        }
        let sorted = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        return Array(sorted.prefix(rules.maxFilesPerProvider))
    }

    static func stat(_ url: URL) -> SessionRunwayFileStat? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true,
              let modifiedAt = values.contentModificationDate
        else { return nil }
        return SessionRunwayFileStat(modifiedAt: modifiedAt, size: Int64(values.fileSize ?? 0))
    }

    static func readPrefix(_ url: URL, _ byteCount: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: byteCount)
    }

    static func readTail(_ url: URL, _ byteCount: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(byteCount) ? end - UInt64(byteCount) : 0
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: byteCount)
        } catch {
            return nil
        }
    }

    private static func isCandidate(_ url: URL, provider: SessionRunwayProvider) -> Bool {
        guard url.pathExtension.lowercased() == "jsonl" || url.pathExtension.lowercased() == "ndjson" else { return false }
        guard !url.lastPathComponent.hasSuffix(".meta.json") else { return false }
        if provider == .codex {
            return url.lastPathComponent.hasPrefix("rollout-")
        }
        return url.lastPathComponent != "journal.jsonl"
    }
}

enum SessionRunwayLiveProcessProbe {
    static func snapshot(_ urls: [URL], _ timeout: TimeInterval) -> SessionRunwayProcessSnapshot {
        guard !urls.isEmpty else { return .empty }
        let candidates = Set(urls.map { $0.standardizedFileURL.path })
        let process = Process()
        let output = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-c", "codex", "-c", "claude", "-F", "pcn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return .unavailable
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .unavailable
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return .empty }
        var currentProvider: SessionRunwayProvider?
        var openPaths = Set<String>()
        var providers = Set<SessionRunwayProvider>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "c":
                currentProvider = provider(for: value)
                if let currentProvider { providers.insert(currentProvider) }
            case "n":
                let path = URL(fileURLWithPath: value).standardizedFileURL.path
                if candidates.contains(path), currentProvider != nil {
                    openPaths.insert(path)
                }
            default:
                continue
            }
        }
        return SessionRunwayProcessSnapshot(
            openTranscriptPaths: openPaths,
            liveProviders: providers,
            liveSessionIDs: [],
            available: true
        )
    }

    private static func provider(for command: String) -> SessionRunwayProvider? {
        let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        if name == "codex" { return .codex }
        if name == "claude" || name == "claude-code" { return .claudeCode }
        return nil
    }
}

enum SessionRunwayLiveCodexTitleStore {
    static func load(database: URL, timeout: TimeInterval) -> SessionRunwayCodexTitleLookup {
        let query = "SELECT rollout_path, id, title, first_user_message, cwd, updated_at_ms, archived FROM threads;"
        guard let data = runSQLite(database: database, query: query, timeout: timeout),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .none }

        var byPath: [String: String] = [:]
        var byID: [String: String] = [:]
        for row in rows {
            let stateTitle = (row["title"] as? String).flatMap(SessionRunwayParser.meaningfulPrompt)
                ?? (row["first_user_message"] as? String).flatMap(SessionRunwayParser.meaningfulPrompt)
            guard let stateTitle else { continue }
            if let path = row["rollout_path"] as? String {
                byPath[URL(fileURLWithPath: path).standardizedFileURL.path] = stateTitle
            }
            if let id = row["id"] as? String {
                byID[id] = stateTitle
            }
        }
        let paths = byPath
        let ids = byID
        return SessionRunwayCodexTitleLookup { path, id in paths[path] ?? ids[id] }
    }

    private static func runSQLite(database: URL, query: String, timeout: TimeInterval) -> Data? {
        let process = Process()
        let output = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database.path, query]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}
