import Combine
import Foundation

// Scans on demand off the UI thread. Parsed file results are cached in memory by
// size and modification time; no transcripts or token history are persisted.
actor ModelUsageScanner {
    private struct CachedFile {
        let size: Int
        let modified: Date
        let report: ModelUsageReport
    }
    private var cache: [URL: CachedFile] = [:]
    private let roots: [MenuBarProvider: [URL]]

    init(roots: [MenuBarProvider: [URL]]? = nil) {
        let configuration = SessionRunwayConfiguration.live
        self.roots = roots ?? [
            .codex: [configuration.codexSessionsRoot,
                     configuration.codexSessionsRoot.deletingLastPathComponent().appendingPathComponent("archived_sessions")],
            .claude: configuration.claudeConfigRoots.map { $0.appendingPathComponent("projects") },
            .grok: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/sessions")]
        ]
    }

    func scan(provider: MenuBarProvider, now: Date = Date()) -> ModelUsageReport {
        let cutoff = now.addingTimeInterval(-31 * 86_400)
        var report = ModelUsageReport(capturedAt: now)
        var visited = Set<URL>()
        for root in roots[provider] ?? [] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            report.sourceAvailable = true
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in report.incompleteFiles += 1; return true }) else {
                report.incompleteFiles += 1
                continue
            }
            for case let url as URL in enumerator {
                if Task.isCancelled { return report }
                guard ["jsonl", "ndjson"].contains(url.pathExtension.lowercased()),
                      provider != .codex || url.lastPathComponent.hasPrefix("rollout-") else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate else {
                    report.incompleteFiles += 1
                    continue
                }
                guard modified >= cutoff else { continue }
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard visited.insert(canonical).inserted else { continue }
                let size = values.fileSize ?? 0
                let fileReport: ModelUsageReport
                if let cached = cache[canonical], cached.size == size, cached.modified == modified {
                    fileReport = cached.report
                } else {
                    fileReport = Self.read(url, provider: provider, since: cutoff, now: now)
                    guard !Task.isCancelled else { return report }
                    cache[canonical] = CachedFile(size: size, modified: modified, report: fileReport)
                }
                report.events.append(contentsOf: fileReport.events)
                report.filesRead += fileReport.filesRead
                report.incompleteFiles += fileReport.incompleteFiles
            }
        }
        cache = cache.filter { $0.value.modified >= cutoff }
        return report
    }

    static func read(_ url: URL, provider: MenuBarProvider, since cutoff: Date, now: Date) -> ModelUsageReport {
        var report = ModelUsageReport(capturedAt: now)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            report.incompleteFiles = 1
            return report
        }
        defer { try? handle.close() }
        var parser = ModelUsageParser(provider: provider, sessionID: url.deletingPathExtension().lastPathComponent)
        var buffer = Data()
        var droppingLongLine = false
        var incomplete = false
        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                incomplete = true
                return
            }
            parser.consume(object, since: cutoff, now: now)
        }
        do {
            // The byte limit is per line, not per file: large histories are fully
            // streamed. An oversized record is skipped and coverage is marked partial.
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                if Task.isCancelled { incomplete = true; break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    if !droppingLongLine {
                        if buffer.distance(from: buffer.startIndex, to: newline) <= 8 * 1024 * 1024 {
                            consume(Data(buffer[..<newline]))
                        } else { incomplete = true }
                    }
                    buffer.removeSubrange(...newline)
                    droppingLongLine = false
                }
                if buffer.count > 8 * 1024 * 1024 {
                    buffer.removeAll(keepingCapacity: false)
                    droppingLongLine = true
                    incomplete = true
                }
            }
            // A writer may be midway through its last JSON record. A complete
            // final record without a newline is valid and still counts.
            if !droppingLongLine { consume(buffer) }
            report.filesRead = 1
        } catch { incomplete = true }
        report.events = parser.events
        report.incompleteFiles = incomplete ? 1 : 0
        return report
    }
}

@MainActor
final class ModelUsageStore: ObservableObject {
    @Published private(set) var report: ModelUsageReport?
    @Published private(set) var loading = false
    private let scanner: ModelUsageScanner

    init(scanner: ModelUsageScanner = ModelUsageScanner()) { self.scanner = scanner }

    func refresh(provider: MenuBarProvider) async {
        guard !loading else { return }
        loading = true
        let next = await scanner.scan(provider: provider)
        if !Task.isCancelled { report = next }
        loading = false
    }
}
