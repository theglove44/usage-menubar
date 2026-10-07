import AppKit
import Foundation
import LocalAuthentication
import Security

// The parts that talk to the outside world on Claude's behalf: reading the OAuth
// credentials Claude Code stores in the macOS Keychain, calling the usage API,
// silently rechecking credentials, and opening a login window only when requested.
//
// QuotaDependencies is the reason this is testable. Every outside call is reached
// through it, so tests substitute fakes and never touch the Keychain or the network.

struct ClaudeUsageHTTPResponse {
    let statusCode: Int
    let data: Data
    let retryAfter: TimeInterval?

    init(statusCode: Int, data: Data, retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.retryAfter = retryAfter
    }
}

enum ClaudeCredentialCheckResult: Equatable {
    case available
    case loginRequired
}

struct QuotaDependencies {
    var readCredentials: () -> Data?
    var checkCredentials: () async -> ClaudeCredentialCheckResult
    var fetchUsage: (_ accessToken: String) async throws -> ClaudeUsageHTTPResponse
    var now: () -> Date
    var launchLogin: () throws -> Void

    static let live = QuotaDependencies(
        readCredentials: ClaudeCredentialReader.read,
        checkCredentials: { ClaudeCredentialReader.checkAuthentication() },
        fetchUsage: ClaudeUsageClient.fetch,
        now: Date.init,
        launchLogin: ClaudeCLI.launchLogin
    )
}

enum ClaudeCredentialReader {
    private static let legacyPath = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath

    // Legacy macOS Keychain ACL prompts are separate from LocalAuthentication.
    // Serialise reads while disabling that interaction for this process, then
    // restore the prior setting. This never changes the credential's access list.
    private static let readLock = NSLock()

    static func read() -> Data? {
        readLock.lock()
        defer { readLock.unlock() }
        var interactionWasAllowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&interactionWasAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            return FileManager.default.contents(atPath: legacyPath)
        }
        defer { SecKeychainSetUserInteractionAllowed(interactionWasAllowed.boolValue) }
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            // This read runs from a background refresh. If macOS cannot grant access
            // silently, keep using the local snapshot instead of interrupting the user
            // with a password dialog every time the refresh timer fires.
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return data
        }
        return FileManager.default.contents(atPath: legacyPath)
    }

    static func checkAuthentication() -> ClaudeCredentialCheckResult {
        // Claude owns renewal. Its CLI status check may show a Keychain prompt,
        // so background recovery only rereads credentials silently.
        guard let data = read(),
              let credentials = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
              credentials.claudeAiOauth.expiresAt.map({ $0 > Date().timeIntervalSince1970 * 1000 }) ?? true
        else { return .loginRequired }
        return .available
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
        let http = response as? HTTPURLResponse
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return ClaudeUsageHTTPResponse(
            statusCode: http?.statusCode ?? 0,
            data: data,
            retryAfter: retryAfter
        )
    }
}

enum ClaudeCLI {
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
