import Foundation

// Asks the operating system which of those session files a live process still has
// open. That is what separates a session running right now from one whose log file
// merely exists. Shells out to lsof under a timeout.
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
