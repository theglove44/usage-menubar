import Foundation

// Finds the session files on disk that the runway scanner reads: which provider
// directories exist, which log files are recent enough to matter, and which to
// skip. Pure file-system lookup - no parsing and no process inspection.
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
