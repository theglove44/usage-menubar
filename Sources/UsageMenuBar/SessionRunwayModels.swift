import Foundation

enum SessionRunwayProvider: String, CaseIterable, Hashable, Sendable {
    case codex
    case claudeCode

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        }
    }
}

enum SessionRunwayState: String, Hashable, Sendable {
    case activeWorking
    case openIdle
    case stale
    case unknown
}

enum SessionRunwayConfidence: String, Hashable, Sendable {
    case high
    case medium
    case low
}

enum SessionRunwayBurnState: String, Hashable, Sendable {
    case measuring
    case observed
    case noRecentBurn
    case unsupported
}

enum SessionRunwayEvidence: String, Hashable, Sendable {
    case fileChanged
    case transcriptOpenByProcess
    case recentEvent
    case providerProcessPresent
    case quietFile
    case agedFile
    case futureTimestampRejected
    case parseDegraded
}

enum SessionRunwaySourceHealth: String, Hashable, Sendable {
    case ready
    case missing
    case degraded
    case unavailable
}

struct SessionRunwayBurn: Equatable, Sendable {
    let state: SessionRunwayBurnState
    let confidence: SessionRunwayConfidence
    let observedTokensPerHour: Double?
    let shareOfObservedProviderBurn: Double?
    let observedTokenDelta: Int64?
    let observationWindow: TimeInterval?

    static let unsupported = SessionRunwayBurn(
        state: .unsupported,
        confidence: .low,
        observedTokensPerHour: nil,
        shareOfObservedProviderBurn: nil,
        observedTokenDelta: nil,
        observationWindow: nil
    )

    static let measuring = SessionRunwayBurn(
        state: .measuring,
        confidence: .medium,
        observedTokensPerHour: nil,
        shareOfObservedProviderBurn: nil,
        observedTokenDelta: nil,
        observationWindow: nil
    )

    // The two measured outcomes, alongside the constants above. The scanner reaches
    // each of them from two different paths (cumulative totals and incremental
    // records), so the shape lives here rather than being spelled out four times.
    static func noRecentBurn(observationWindow: TimeInterval) -> SessionRunwayBurn {
        SessionRunwayBurn(
            state: .noRecentBurn,
            confidence: .high,
            observedTokensPerHour: nil,
            shareOfObservedProviderBurn: nil,
            observedTokenDelta: 0,
            observationWindow: observationWindow
        )
    }

    static func observed(deltaTokens: Int64, interval: TimeInterval) -> SessionRunwayBurn {
        SessionRunwayBurn(
            state: .observed,
            confidence: .high,
            observedTokensPerHour: SessionRunwayBurnMath.tokensPerHour(
                deltaTokens: deltaTokens, interval: interval
            ),
            shareOfObservedProviderBurn: nil,
            observedTokenDelta: deltaTokens,
            observationWindow: interval
        )
    }
}

struct SessionRunwayRow: Identifiable, Equatable, Sendable {
    let id: String
    let provider: SessionRunwayProvider
    let sessionID: String
    let title: String
    let projectName: String?
    let branch: String?
    let state: SessionRunwayState
    let confidence: SessionRunwayConfidence
    let evidence: [SessionRunwayEvidence]
    let lastActivityAt: Date?
    let fileModifiedAt: Date?
    let burn: SessionRunwayBurn
    let childSessionCount: Int
}

struct SessionRunwayDiagnostics: Equatable, Sendable {
    let discoveredFileCount: Int
    let visibleCandidateCount: Int
    let hiddenHistoricalCount: Int
    let hiddenHistoricalCountIsLowerBound: Bool
    let hiddenRecentCount: Int
    let duplicateFileCount: Int
    let groupedSubagentCount: Int
    let parseFailureCount: Int
    let futureTimestampCount: Int
    let processProbeAvailable: Bool
}

struct SessionRunwaySnapshot: Equatable, Sendable {
    let rows: [SessionRunwayRow]
    let hiddenHistoricalCount: Int
    let health: [SessionRunwayProvider: SessionRunwaySourceHealth]
    let diagnostics: SessionRunwayDiagnostics
    let scannedAt: Date
}

struct SessionRunwayRules: Equatable, Sendable {
    // Runway is a live/recent view, not a transcript history list. Process-
    // confirmed sessions may bypass this age window.
    var visibleLookback: TimeInterval = 60 * 60
    var idleAfter: TimeInterval = 15 * 60
    var activeAfter: TimeInterval = 90
    var clockSkewTolerance: TimeInterval = 120
    var maxFilesPerProvider = 300
    var maxVisibleRows = 4
    var parseByteBudget = 64 * 1024
    var processProbeTimeout: TimeInterval = 1
    var noBurnWindow: TimeInterval = 15 * 60
    var usageRecordCacheLimit = 512

    static let live = SessionRunwayRules()
}

struct SessionRunwayConfiguration: Equatable, Sendable {
    let codexSessionsRoot: URL
    let codexStateDatabase: URL?
    let claudeConfigRoots: [URL]

    static var live: SessionRunwayConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = expandPath(environment["CODEX_HOME"] ?? "~/.codex")

        var claudeRoots: [URL] = []
        if let roots = environment["CLAUDE_CONFIG_DIRS"], !roots.isEmpty {
            claudeRoots.append(contentsOf: roots.split(separator: ":").map { expandPath(String($0)) })
        }
        if let root = environment["CLAUDE_CONFIG_DIR"], !root.isEmpty {
            claudeRoots.append(expandPath(root))
        }
        claudeRoots.append(home.appendingPathComponent(".claude", isDirectory: true))

        var seen = Set<String>()
        let uniqueClaudeRoots = claudeRoots.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return SessionRunwayConfiguration(
            codexSessionsRoot: codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexStateDatabase: codexHome.appendingPathComponent("state_5.sqlite"),
            claudeConfigRoots: uniqueClaudeRoots
        )
    }

    private static func expandPath(_ value: String) -> URL {
        URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
    }
}

struct SessionRunwayFileStat: Equatable, Sendable {
    let modifiedAt: Date
    let size: Int64
}

struct SessionRunwayProcessSnapshot: Equatable, Sendable {
    let openTranscriptPaths: Set<String>
    let liveProviders: Set<SessionRunwayProvider>
    let liveSessionIDs: Set<String>
    let available: Bool

    static let unavailable = SessionRunwayProcessSnapshot(
        openTranscriptPaths: [],
        liveProviders: [],
        liveSessionIDs: [],
        available: false
    )

    static let empty = SessionRunwayProcessSnapshot(
        openTranscriptPaths: [],
        liveProviders: [],
        liveSessionIDs: [],
        available: true
    )
}

struct SessionRunwayFileSystem {
    let discover: @Sendable (
        _ provider: SessionRunwayProvider,
        _ configuration: SessionRunwayConfiguration,
        _ rules: SessionRunwayRules,
        _ now: Date
    ) -> [URL]
    let stat: @Sendable (URL) -> SessionRunwayFileStat?
    let readPrefix: @Sendable (URL, Int) -> Data?
    let readTail: @Sendable (URL, Int) -> Data?

    static let live = SessionRunwayFileSystem(
        discover: { provider, configuration, rules, now in
            SessionRunwayLiveFileSystem.discover(
                provider: provider,
                configuration: configuration,
                rules: rules,
                now: now
            )
        },
        stat: { url in SessionRunwayLiveFileSystem.stat(url) },
        readPrefix: { url, byteCount in SessionRunwayLiveFileSystem.readPrefix(url, byteCount) },
        readTail: { url, byteCount in SessionRunwayLiveFileSystem.readTail(url, byteCount) }
    )
}

struct SessionRunwayCodexTitleStore {
    let load: @Sendable (URL, TimeInterval) -> SessionRunwayCodexTitleLookup

    static let none = SessionRunwayCodexTitleStore { _, _ in .none }
    static let live = SessionRunwayCodexTitleStore { database, timeout in
        SessionRunwayLiveCodexTitleStore.load(database: database, timeout: timeout)
    }
}

struct SessionRunwayProcessProbe {
    let snapshot: @Sendable ([URL], TimeInterval) -> SessionRunwayProcessSnapshot

    static let none = SessionRunwayProcessProbe { _, _ in .unavailable }
    static let live = SessionRunwayProcessProbe { urls, timeout in
        SessionRunwayLiveProcessProbe.snapshot(urls, timeout)
    }
}
