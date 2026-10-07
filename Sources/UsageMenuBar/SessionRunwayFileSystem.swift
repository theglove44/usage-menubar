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

        // Read metadata once per file. Looking it up inside the sort comparator
        // multiplies Foundation/filesystem work by the number of comparisons.
        var files: [(url: URL, modifiedAt: Date)] = []
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
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                files.append((url, values.contentModificationDate ?? .distantPast))
            }
        }
        let sorted = files.sorted { $0.modifiedAt > $1.modifiedAt }
        return sorted.prefix(rules.maxFilesPerProvider).map(\.url)
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
