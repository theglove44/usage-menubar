import Foundation

// Shared local-session model. Discovery sources produce this value; the
// menu-bar layer maps it into its smaller UI snapshot model.
enum SessionActivityProvider: String, Codable, Equatable, Sendable {
    case codex
    case claude
}

enum SessionActivityState: String, Codable, Equatable, Sendable {
    case activeWorking
    case openIdle
    case stale
    case unknown
}

enum SessionActivityConfidence: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
    case unknown

    var score: Double {
        switch self {
        case .high:
            return 1
        case .medium:
            return 0.7
        case .low:
            return 0.4
        case .unknown:
            return 0
        }
    }
}

struct SessionActivity: Identifiable, Codable, Equatable, Sendable {
    let provider: SessionActivityProvider
    let sessionID: String
    let logPath: String?
    let workspace: String?
    let pid: Int32?
    let tty: String?
    let lastSeen: Date?
    let state: SessionActivityState
    let confidence: SessionActivityConfidence
    let subagentLogPaths: [String]

    init(
        provider: SessionActivityProvider,
        sessionID: String,
        logPath: String? = nil,
        workspace: String? = nil,
        pid: Int32? = nil,
        tty: String? = nil,
        lastSeen: Date? = nil,
        state: SessionActivityState,
        confidence: SessionActivityConfidence,
        subagentLogPaths: [String] = []
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.logPath = logPath
        self.workspace = workspace
        self.pid = pid
        self.tty = tty
        self.lastSeen = lastSeen
        self.state = state
        self.confidence = confidence
        self.subagentLogPaths = subagentLogPaths
    }

    var id: String {
        "\(provider.rawValue):\(sessionID)"
    }

    var confidenceScore: Double {
        confidence.score
    }

    var subagentCount: Int {
        subagentLogPaths.count
    }

    var badges: [String] {
        subagentLogPaths.isEmpty ? [] : ["subagents"]
    }
}
