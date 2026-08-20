import Foundation

// Reads conversation titles out of Codex's own sqlite database, so a row in the
// menu can be labelled with what the session is actually about rather than a file
// path. Read-only, and the app works without it if the database is absent.
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
