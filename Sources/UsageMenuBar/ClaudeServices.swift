import AppKit
import Foundation
import Security

struct ClaudeUsageHTTPResponse {
    let statusCode: Int
    let data: Data
}

enum ClaudeCLIRefreshResult: Equatable {
    case refreshed
    case loginRequired
    case missing
    case timedOut
    case failed
}

struct QuotaDependencies {
    var readCredentials: () -> Data?
    var refreshCLI: () async -> ClaudeCLIRefreshResult
    var fetchUsage: (_ accessToken: String) async throws -> ClaudeUsageHTTPResponse
    var now: () -> Date
    var launchLogin: () throws -> Void

    static let live = QuotaDependencies(
        readCredentials: ClaudeCredentialReader.read,
        refreshCLI: { await ClaudeCLI.refreshAuthentication() },
        fetchUsage: ClaudeUsageClient.fetch,
        now: Date.init,
        launchLogin: ClaudeCLI.launchLogin
    )
}

enum ClaudeCredentialReader {
    private static let legacyPath = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath

    static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return data
        }
        return FileManager.default.contents(atPath: legacyPath)
    }
}

enum ClaudeUsageClient {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(accessToken: String) async throws -> ClaudeUsageHTTPResponse {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("usage-menubar/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ClaudeUsageHTTPResponse(statusCode: statusCode, data: data)
    }
}

enum ClaudeCLI {
    private struct AuthStatus: Decodable {
        let loggedIn: Bool
    }

    static func locate() -> String? {
        let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) + "/claude" } ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = environmentPaths + [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func refreshAuthentication() async -> ClaudeCLIRefreshResult {
        guard let executable = locate() else { return .missing }
        let result = await ProcessRunner.run(
            executable: executable,
            arguments: ["auth", "status", "--json"],
            timeout: 12
        )
        if result.timedOut { return .timedOut }
        guard result.exitCode == 0,
              let status = try? JSONDecoder().decode(AuthStatus.self, from: result.output)
        else {
            return result.exitCode == 1 ? .loginRequired : .failed
        }
        return status.loggedIn ? .refreshed : .loginRequired
    }

    static func launchLogin() throws {
        guard let executable = locate() else { throw ClaudeCLIError.missing }
        let wrapper = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-menubar-claude-login.command")
        let quotedPath = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/zsh\n\(quotedPath) auth login --claudeai\nprintf '\\nLogin finished. You can close this window.\\n'\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        NSWorkspace.shared.open(wrapper)
    }
}

enum ClaudeCLIError: Error {
    case missing
}

private struct ProcessResult {
    let exitCode: Int32
    let output: Data
    let timedOut: Bool
}

private final class ProcessCompletionState: @unchecked Sendable {
    let lock = NSLock()
    var completed = false
    var timedOut = false
}

private enum ProcessRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let state = ProcessCompletionState()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe

            @Sendable func finish() {
                state.lock.lock()
                guard !state.completed else { state.lock.unlock(); return }
                state.completed = true
                let timedOut = state.timedOut
                state.lock.unlock()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    output: data,
                    timedOut: timedOut
                ))
            }

            process.terminationHandler = { _ in finish() }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ProcessResult(exitCode: -1, output: Data(), timedOut: false))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.lock.lock()
                guard !state.completed else { state.lock.unlock(); return }
                state.timedOut = true
                state.lock.unlock()
                process.terminate()
            }
        }
    }
}
